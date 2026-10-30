//
//  ESFixtures.swift
//  MPEGTSTests
//
//  Synthetic MPEG-2 video headers and pictures, and AC-3/E-AC-3 syncframes with valid CRCs.
//

import Foundation

struct SequenceSpec {
    var width = 1920
    var height = 1080
    var aspect = 3
    var rateCode = 4
    var bitRateValue = 48_500
    var progressive = false
    var profileAndLevel = 0x44
    var widthExtension = 0
    var heightExtension = 0
    var rateExtensionN = 0
    var rateExtensionD = 0

    static let hd1080i = SequenceSpec()
    static let hd720p = SequenceSpec(width: 1280, height: 720, rateCode: 7, progressive: true)
}

struct PictureSpec {
    var type: Int
    var temporalReference: Int
    var structure = 3
    var topFieldFirst = true
    var repeatFirstField = false
    var progressiveFrame = false
    var captions: [[UInt8]] = []
    var sliceCount = 4
}

enum MPEG2Fixtures {
    static func sequenceHeader(_ spec: SequenceSpec) -> [UInt8] {
        var writer = BitWriter()
        writer.write(spec.width & 0xFFF, bits: 12)
        writer.write(spec.height & 0xFFF, bits: 12)
        writer.write(spec.aspect, bits: 4)
        writer.write(spec.rateCode, bits: 4)
        writer.write(spec.bitRateValue & 0x3FFFF, bits: 18)
        writer.write(1, bits: 1)
        writer.write(488, bits: 10)
        writer.write(0, bits: 3)  // constrained_parameters_flag, load_intra and load_non_intra matrices
        var header: [UInt8] = [0, 0, 1, 0xB3] + writer.finish()
        var ext = BitWriter()
        ext.write(1, bits: 4)
        ext.write(spec.profileAndLevel, bits: 8)
        ext.write(spec.progressive ? 1 : 0, bits: 1)
        ext.write(1, bits: 2)  // 4:2:0
        ext.write(spec.widthExtension, bits: 2)
        ext.write(spec.heightExtension, bits: 2)
        ext.write(spec.bitRateValue >> 18, bits: 12)
        ext.write(1, bits: 1)
        ext.write(0, bits: 8)
        ext.write(0, bits: 1)  // low_delay
        ext.write(spec.rateExtensionN, bits: 2)
        ext.write(spec.rateExtensionD, bits: 5)
        header += [0, 0, 1, 0xB5] + ext.finish()
        return header
    }

    static func gop(closed: Bool, brokenLink: Bool = false) -> [UInt8] {
        var writer = BitWriter()
        writer.write(0x0800, bits: 25)  // a time code with its marker bit
        writer.write(closed ? 1 : 0, bits: 1)
        writer.write(brokenLink ? 1 : 0, bits: 1)
        return [0, 0, 1, 0xB8] + writer.finish()
    }

    static func picture(_ spec: PictureSpec, slices: inout SeededGenerator) -> [UInt8] {
        var header = BitWriter()
        header.write(spec.temporalReference, bits: 10)
        header.write(spec.type, bits: 3)
        header.write(0xFFFF, bits: 16)
        if spec.type >= 2 { header.write(0b0111, bits: 4) }
        if spec.type == 3 { header.write(0b0111, bits: 4) }
        header.write(0, bits: 1)
        var bytes: [UInt8] = [0, 0, 1, 0x00] + header.finish()
        var ext = BitWriter()
        ext.write(8, bits: 4)
        ext.write(0xFFFF, bits: 16)
        ext.write(0, bits: 2)
        ext.write(spec.structure, bits: 2)
        ext.write(spec.topFieldFirst ? 1 : 0, bits: 1)
        ext.write(0b10000, bits: 5)
        ext.write(spec.repeatFirstField ? 1 : 0, bits: 1)
        ext.write(1, bits: 1)
        ext.write(spec.progressiveFrame ? 1 : 0, bits: 1)
        ext.write(0, bits: 1)
        bytes += [0, 0, 1, 0xB5] + ext.finish()
        if !spec.captions.isEmpty {
            bytes += captionUserData(spec.captions)
        }
        for slice in 1...max(1, spec.sliceCount) {
            bytes += [0, 0, 1, UInt8(slice)]
            // Slice data without start-code emulation, ending in a zero-stuffing run like broadcast encoders use.
            bytes += (0..<Int.random(in: 40...300, using: &slices)).map { _ in
                UInt8.random(in: 0x02...0xFF, using: &slices)
            }
            bytes += [UInt8](repeating: 0, count: Int.random(in: 0...12, using: &slices))
        }
        return bytes
    }

    static func captionUserData(_ triplets: [[UInt8]]) -> [UInt8] {
        var bytes: [UInt8] = [0, 0, 1, 0xB2, 0x47, 0x41, 0x39, 0x34, 0x03, 0x40 | UInt8(triplets.count), 0xFF]
        for triplet in triplets {
            bytes += triplet
        }
        return bytes + [0xFF]
    }

    /// Twenty cc_data triplets like 9.1 carries per picture: two 608 field triplets, then 708 padding.
    static func captionTriplets(seed: UInt8) -> [[UInt8]] {
        var triplets: [[UInt8]] = [[0xFC, 0x80 | seed, 0x80], [0xFD, 0x80, 0x80]]
        for _ in 0..<18 {
            triplets.append([0xFA, 0x00, 0x00])
        }
        return triplets
    }
}

enum AC3Fixtures {
    static let bitRates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]

    /// An AC-3 syncframe (bsid 8) with a valid CRC over everything after the syncword.
    static func frame(
        fscod: Int = 0,
        frmsizecod: Int = 28,
        acmod: Int = 7,
        lfe: Bool = true,
        random: inout SeededGenerator
    ) -> [UInt8] {
        let rates = [48_000, 44_100, 32_000]
        var words = bitRates[frmsizecod >> 1] * 96_000 / rates[fscod]
        if fscod == 1 { words += frmsizecod & 1 }
        var info = BitWriter()
        info.write(acmod, bits: 3)
        if (acmod & 1) != 0, acmod != 1 { info.write(0, bits: 2) }
        if (acmod & 4) != 0 { info.write(0, bits: 2) }
        if acmod == 2 { info.write(0, bits: 2) }
        info.write(lfe ? 1 : 0, bits: 1)
        let bytes: [UInt8] = [0x0B, 0x77, 0x00, 0x00, UInt8((fscod << 6) | frmsizecod), 0x40] + info.finish()
        return sealed(bytes, size: words * 2, random: &random)
    }

    /// An E-AC-3 syncframe (bsid 16).
    static func eac3Frame(
        streamType: Int = 0,
        substreamID: Int = 0,
        size: Int = 768,
        fscod: Int = 0,
        blocksCode: Int = 3,
        acmod: Int = 7,
        lfe: Bool = true,
        random: inout SeededGenerator
    ) -> [UInt8] {
        var writer = BitWriter()
        writer.write(streamType, bits: 2)
        writer.write(substreamID, bits: 3)
        writer.write(size / 2 - 1, bits: 11)
        writer.write(fscod, bits: 2)
        writer.write(blocksCode, bits: 2)
        writer.write(acmod, bits: 3)
        writer.write(lfe ? 1 : 0, bits: 1)
        writer.write(16, bits: 5)
        writer.write(0, bits: 3)
        return sealed([0x0B, 0x77] + writer.finish(), size: size, random: &random)
    }

    /// Fills to `size` with random bytes and appends the CRC that makes the frame check to zero.
    private static func sealed(_ header: [UInt8], size: Int, random: inout SeededGenerator) -> [UInt8] {
        var bytes = header + random.bytes(size - header.count - 2)
        let crc = ReferenceCRC.crc16(Array(bytes[2...]))
        bytes += [UInt8(crc >> 8), UInt8(crc & 0xFF)]
        return bytes
    }
}
