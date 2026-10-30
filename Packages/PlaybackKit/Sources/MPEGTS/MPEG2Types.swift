//
//  MPEG2Types.swift
//  MPEGTS
//
//  What `MPEG2Framer` produces: access units with their parsed sequence and picture parameters.
//

import Foundation

/// A ratio of positive integers, used for frame rates and sample aspect ratios.
nonisolated public struct MPEG2Rational: Sendable, Hashable {
    public var numerator: Int
    public var denominator: Int

    public init(_ numerator: Int, _ denominator: Int) {
        self.numerator = numerator
        self.denominator = denominator
    }

    /// The same ratio in lowest terms.
    public var reduced: MPEG2Rational {
        var high = abs(numerator)
        var low = abs(denominator)
        while low != 0 {
            (high, low) = (low, high % low)
        }
        guard high > 1 else { return self }
        return MPEG2Rational(numerator / high, denominator / high)
    }

    public var doubleValue: Double {
        denominator == 0 ? 0 : Double(numerator) / Double(denominator)
    }
}

/// Sequence header plus sequence extension (ISO/IEC 13818-2 §6.2.2.1, §6.2.2.3).
nonisolated public struct MPEG2SequenceInfo: Sendable, Hashable {
    /// Luma width and height, including the sequence extension's size-extension bits.
    public var width: Int
    public var height: Int
    /// aspect_ratio_information: 1 square samples, 2 4:3, 3 16:9, 4 2.21:1 display aspect ratio.
    public var aspectRatioCode: UInt8
    /// Frames per second, including frame_rate_extension_n/d (for example 30000/1001).
    public var frameRate: MPEG2Rational
    public var progressiveSequence: Bool
    /// chroma_format: 1 4:2:0, 2 4:2:2, 3 4:4:4.
    public var chromaFormat: UInt8
    /// profile_and_level_indication, for example 0x44 for Main@High. 0 without a sequence extension (MPEG-1).
    public var profileAndLevel: UInt8
    /// Bits per second (bit_rate_value with its extension, × 400).
    public var bitRate: Int
    public var lowDelay: Bool
    /// False for an MPEG-1 sequence (no sequence extension).
    public var hasSequenceExtension: Bool

    public init(
        width: Int,
        height: Int,
        aspectRatioCode: UInt8,
        frameRate: MPEG2Rational,
        progressiveSequence: Bool,
        chromaFormat: UInt8,
        profileAndLevel: UInt8,
        bitRate: Int,
        lowDelay: Bool = false,
        hasSequenceExtension: Bool = true
    ) {
        self.width = width
        self.height = height
        self.aspectRatioCode = aspectRatioCode
        self.frameRate = frameRate
        self.progressiveSequence = progressiveSequence
        self.chromaFormat = chromaFormat
        self.profileAndLevel = profileAndLevel
        self.bitRate = bitRate
        self.lowDelay = lowDelay
        self.hasSequenceExtension = hasSequenceExtension
    }

    /// The pixel (sample) aspect ratio implied by the display aspect ratio and the coded size, in lowest terms,
    /// for example 40:33 for 704x480 at 16:9. 1:1 for square samples or unknown codes.
    public var sampleAspectRatio: MPEG2Rational {
        let display: (Int, Int)
        switch aspectRatioCode {
        case 2: display = (4, 3)
        case 3: display = (16, 9)
        case 4: display = (221, 100)
        default: return MPEG2Rational(1, 1)
        }
        guard width > 0, height > 0 else { return MPEG2Rational(1, 1) }
        return MPEG2Rational(display.0 * height, display.1 * width).reduced
    }
}

nonisolated public enum MPEG2PictureType: UInt8, Sendable, Hashable {
    case intra = 1
    case predicted = 2
    case bidirectional = 3
}

nonisolated public enum MPEG2PictureStructure: UInt8, Sendable, Hashable {
    case topField = 1
    case bottomField = 2
    case frame = 3
}

/// Picture header plus picture coding extension (ISO/IEC 13818-2 §6.2.3, §6.2.3.1), as parsed.
nonisolated struct MPEG2PictureInfo: Equatable {
    var pictureType: MPEG2PictureType
    var temporalReference: Int
    var pictureStructure: MPEG2PictureStructure = .frame
    // MPEG-1 defaults until a picture coding extension overrides them.
    var topFieldFirst = false
    var repeatFirstField = false
    var progressiveFrame = true
}

/// One coded picture (or one field pair) in decode order, ready to become one compressed sample.
nonisolated public struct MPEG2AccessUnit: Sendable, Equatable {
    /// The picture's bytes, preceded by any sequence header, sequence extension, GOP header and user data that came
    /// before it. Headers are never emitted on their own.
    public var data: Data
    /// 90 kHz, on the demuxer's unwrapped timeline. From the PES header when the picture starts in a PES that has
    /// one; otherwise interpolated (B pictures: PTS = DTS; I/P pictures: DTS plus the last observed reorder delay).
    public var pts: Int64
    /// 90 kHz. From the PES header (DTS, or PTS when no DTS is coded), otherwise the previous DTS plus its duration.
    public var dts: Int64
    /// Display duration in 90 kHz ticks, from the frame rate, picture structure and repeat_first_field.
    public var duration: Int64
    /// The sequence parameters in effect for this picture (from this unit's sequence header or an earlier one).
    public var sequence: MPEG2SequenceInfo
    public var pictureType: MPEG2PictureType
    /// Display order within the GOP.
    public var temporalReference: Int
    /// `.frame`, or the first field's structure for a field pair (two field pictures form one access unit).
    public var pictureStructure: MPEG2PictureStructure
    public var topFieldFirst: Bool
    public var repeatFirstField: Bool
    public var progressiveFrame: Bool
    /// The access unit begins with a sequence header.
    public var hasSequenceHeader: Bool
    /// ATSC A/53 Part 4 `cc_data` triplets (cc_valid/cc_type byte plus two data bytes, `cc_count` × 3 bytes) from
    /// GA94 user data, in coded order. Reorder by PTS before decoding captions.
    public var captionData: Data?
    /// The picture follows lost data or a discontinuity_indicator (from `PESPacket.isDiscontinuity`).
    public var isDiscontinuity: Bool

    public init(
        data: Data,
        pts: Int64,
        dts: Int64,
        duration: Int64,
        sequence: MPEG2SequenceInfo,
        pictureType: MPEG2PictureType,
        temporalReference: Int,
        pictureStructure: MPEG2PictureStructure = .frame,
        topFieldFirst: Bool = false,
        repeatFirstField: Bool = false,
        progressiveFrame: Bool = true,
        hasSequenceHeader: Bool = false,
        captionData: Data? = nil,
        isDiscontinuity: Bool = false
    ) {
        self.data = data
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.sequence = sequence
        self.pictureType = pictureType
        self.temporalReference = temporalReference
        self.pictureStructure = pictureStructure
        self.topFieldFirst = topFieldFirst
        self.repeatFirstField = repeatFirstField
        self.progressiveFrame = progressiveFrame
        self.hasSequenceHeader = hasSequenceHeader
        self.captionData = captionData
        self.isDiscontinuity = isDiscontinuity
    }

    /// A sync sample a decoder can start from: a sequence header and an I picture. Every other sample should be
    /// marked `kCMSampleAttachmentKey_NotSync`.
    public var isKeyframe: Bool { hasSequenceHeader && pictureType == .intra }
}

extension MPEG2AccessUnit {
    /// The unit holding a copy of `bytes`, for units from `MPEG2Framer.append(_:of:_:)`.
    func copying(_ bytes: UnsafeBufferPointer<UInt8>) -> MPEG2AccessUnit {
        var unit = self
        unit.data = Data(buffer: bytes)
        return unit
    }
}
