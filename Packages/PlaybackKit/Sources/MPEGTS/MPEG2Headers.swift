//
//  MPEG2Headers.swift
//  MPEGTS
//
//  Parsers for the MPEG-2 video headers the framer needs (ISO/IEC 13818-2 §6.2) and for ATSC A/53 Part 4 caption
//  user data. Each takes the bytes after a start code up to the next start code.
//

nonisolated enum MPEG2StartCode {
    static let picture: UInt8 = 0x00
    static let userData: UInt8 = 0xB2
    static let sequenceHeader: UInt8 = 0xB3
    static let extensionStart: UInt8 = 0xB5
    static let sequenceEnd: UInt8 = 0xB7
    static let groupOfPictures: UInt8 = 0xB8

    /// Finds the next `00 00 01 xx` at or after `start` whose code byte `xx` is inside the buffer.
    ///
    /// Broadcast video carries long zero-stuffing runs (about 13% of 9.1's bytes), so hunting for zero bytes is
    /// slow. Instead the scan looks for the rarer 0x01 byte, eight bytes at a time with an exact per-byte mask, and
    /// checks the two bytes before each one.
    static func find(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        guard start >= 0, let base = bytes.baseAddress else { return nil }
        let count = bytes.count
        let raw = UnsafeRawPointer(base)
        // `index` walks the position of the 0x01 byte; the code byte after it must be inside the buffer.
        var index = start + 2
        while index + 8 < count {
            let word = UInt64(littleEndian: raw.loadUnaligned(fromByteOffset: index, as: UInt64.self))
            var ones = zeroByteFlags(word ^ 0x0101_0101_0101_0101)
            while ones != 0 {
                let position = index + ones.trailingZeroBitCount / 8
                if base[position - 1] == 0, base[position - 2] == 0 {
                    return position - 2
                }
                ones &= ones - 1
            }
            index += 8
        }
        while index + 1 < count {
            if base[index] == 1, base[index - 1] == 0, base[index - 2] == 0 {
                return index - 2
            }
            index += 1
        }
        return nil
    }

    /// The high bit of each byte of the result is set exactly when that byte of `word` is zero.
    @inline(__always)
    private static func zeroByteFlags(_ word: UInt64) -> UInt64 {
        let lowBits: UInt64 = 0x7F7F_7F7F_7F7F_7F7F
        return ~(((word & lowBits) &+ lowBits) | word) & ~lowBits
    }
}

nonisolated struct MPEG2GOPHeader: Equatable {
    var closedGOP: Bool
    var brokenLink: Bool
}

nonisolated enum MPEG2Headers {
    /// frame_rate_code 1…8 (Table 6-4).
    static let frameRates: [MPEG2Rational] = [
        MPEG2Rational(0, 1),
        MPEG2Rational(24000, 1001), MPEG2Rational(24, 1), MPEG2Rational(25, 1), MPEG2Rational(30000, 1001),
        MPEG2Rational(30, 1), MPEG2Rational(50, 1), MPEG2Rational(60000, 1001), MPEG2Rational(60, 1)
    ]

    /// sequence_header(): the 12-bit sizes, aspect ratio, frame rate and bit rate. Defaults the extension fields as
    /// for MPEG-1 until a sequence extension follows.
    static func sequenceHeader(_ bytes: UnsafeBufferPointer<UInt8>) -> MPEG2SequenceInfo? {
        var reader = BitReader(bytes)
        let width = reader.int(12)
        let height = reader.int(12)
        let aspect = reader.int(4)
        let rateCode = reader.int(4)
        let bitRateValue = reader.int(18)
        guard !reader.isOverrun, width > 0, height > 0, aspect > 0, (1...8).contains(rateCode) else { return nil }
        return MPEG2SequenceInfo(
            width: width,
            height: height,
            aspectRatioCode: UInt8(aspect),
            frameRate: frameRates[rateCode],
            progressiveSequence: true,
            chromaFormat: 1,
            profileAndLevel: 0,
            bitRate: bitRateValue * 400,
            lowDelay: false,
            hasSequenceExtension: false
        )
    }

    /// The extension_start_code_identifier of an extension (1 sequence, 8 picture coding).
    static func extensionIdentifier(_ bytes: UnsafeBufferPointer<UInt8>) -> UInt8? {
        bytes.first.map { $0 >> 4 }
    }

    /// sequence_extension(): applies the size, bit-rate and frame-rate extensions to `info`.
    static func applySequenceExtension(_ bytes: UnsafeBufferPointer<UInt8>, to info: inout MPEG2SequenceInfo) -> Bool {
        var reader = BitReader(bytes)
        guard reader.int(4) == 1 else { return false }
        let profileAndLevel = UInt8(reader.int(8))
        let progressive = reader.flag()
        let chroma = UInt8(reader.int(2))
        let widthExtension = reader.int(2)
        let heightExtension = reader.int(2)
        let bitRateExtension = reader.int(12)
        reader.skip(1 + 8)  // marker_bit, vbv_buffer_size_extension
        let lowDelay = reader.flag()
        let rateNumerator = reader.int(2)
        let rateDenominator = reader.int(5)
        guard !reader.isOverrun else { return false }
        info.profileAndLevel = profileAndLevel
        info.progressiveSequence = progressive
        info.chromaFormat = chroma
        info.width |= widthExtension << 12
        info.height |= heightExtension << 12
        info.bitRate = ((bitRateExtension << 18) | (info.bitRate / 400)) * 400
        info.lowDelay = lowDelay
        info.frameRate = MPEG2Rational(info.frameRate.numerator * (rateNumerator + 1),
                                       info.frameRate.denominator * (rateDenominator + 1))
        info.hasSequenceExtension = true
        return true
    }

    /// picture_header(): temporal_reference and picture_coding_type (I, P or B; D pictures are rejected).
    static func pictureHeader(_ bytes: UnsafeBufferPointer<UInt8>) -> MPEG2PictureInfo? {
        var reader = BitReader(bytes)
        let temporalReference = reader.int(10)
        let codingType = UInt8(reader.int(3))
        guard !reader.isOverrun, let type = MPEG2PictureType(rawValue: codingType) else { return nil }
        // MPEG-1 defaults; a picture coding extension overrides them.
        return MPEG2PictureInfo(pictureType: type, temporalReference: temporalReference)
    }

    /// picture_coding_extension(): structure, field order, repeat_first_field and progressive_frame.
    static func applyPictureCodingExtension(
        _ bytes: UnsafeBufferPointer<UInt8>,
        to info: inout MPEG2PictureInfo
    ) -> Bool {
        var reader = BitReader(bytes)
        guard reader.int(4) == 8 else { return false }
        reader.skip(16 + 2)  // f_code[2][2], intra_dc_precision
        let structure = UInt8(reader.int(2))
        let topFieldFirst = reader.flag()
        reader.skip(5)  // frame_pred_frame_dct … alternate_scan
        let repeatFirstField = reader.flag()
        reader.skip(1)  // chroma_420_type
        let progressiveFrame = reader.flag()
        guard !reader.isOverrun, let pictureStructure = MPEG2PictureStructure(rawValue: structure) else { return false }
        info.pictureStructure = pictureStructure
        info.topFieldFirst = topFieldFirst
        info.repeatFirstField = repeatFirstField
        info.progressiveFrame = progressiveFrame
        return true
    }

    /// group_of_pictures_header(): closed_gop and broken_link after the 25-bit time code.
    static func groupOfPictures(_ bytes: UnsafeBufferPointer<UInt8>) -> MPEG2GOPHeader? {
        var reader = BitReader(bytes)
        reader.skip(25)
        let closed = reader.flag()
        let broken = reader.flag()
        guard !reader.isOverrun else { return nil }
        return MPEG2GOPHeader(closedGOP: closed, brokenLink: broken)
    }

    static let captionLimit = 4096

    /// ATSC A/53 Part 4 user data: `GA94`, user_data_type_code 0x03, then process_em_data_flag, process_cc_data_flag,
    /// additional_data_flag, cc_count(5), em_data and cc_count × 3 bytes of cc_data. Appends the triplets.
    static func appendCaptions(_ bytes: UnsafeBufferPointer<UInt8>, to captions: inout [UInt8]) {
        guard bytes.count >= 7, bytes[0] == 0x47, bytes[1] == 0x41, bytes[2] == 0x39, bytes[3] == 0x34,
              bytes[4] == 0x03 else { return }
        let flags = bytes[5]
        guard (flags & 0x40) != 0 else { return }  // process_cc_data_flag
        let ccCount = Int(flags & 0x1F)
        let start = 7
        let end = start + ccCount * 3
        guard ccCount > 0, end <= bytes.count, captions.count + ccCount * 3 <= captionLimit else { return }
        captions.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[start..<end]))
    }
}
