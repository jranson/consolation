//
//  NALDecoderConfiguration.swift
//  MPEGTS
//
//  The decoder configuration records of ISO/IEC 14496-15: `avcC` (AVCDecoderConfigurationRecord, H.264) and `hvcC`
//  (HEVCDecoderConfigurationRecord), as Matroska's CodecPrivate and MP4 sample descriptions carry them. They hold
//  the parameter sets and the size of the length prefix in front of each NAL unit of a sample. Also the conversion
//  of such length-prefixed samples to Annex B (start codes), which `NALVideoFramer` reads.
//

import Foundation

nonisolated public struct NALDecoderConfiguration: Sendable, Equatable {
    public var codec: NALVideoCodec
    /// Bytes in front of each NAL unit of a sample (1, 2 or 4).
    public var lengthSize: Int
    /// Raw parameter set NAL units, header included: H.264 SPSs then PPSs; HEVC VPSs, SPSs then PPSs.
    public var parameterSets: [Data]

    public init(codec: NALVideoCodec, lengthSize: Int, parameterSets: [Data]) {
        self.codec = codec
        self.lengthSize = lengthSize
        self.parameterSets = parameterSets
    }

    /// Parameter sets this record may list at most.
    static let maximumParameterSets = 64

    /// An `avcC` record, or nil when it is malformed.
    public static func avc(_ record: Data) -> NALDecoderConfiguration? {
        record.withUnsafeBytes { raw in avc(raw.bindMemory(to: UInt8.self)) }
    }

    static func avc(_ bytes: UnsafeBufferPointer<UInt8>) -> NALDecoderConfiguration? {
        // configurationVersion 1, profile, compatibility, level, then six reserved bits and lengthSizeMinusOne.
        guard bytes.count >= 7, bytes[0] == 1 else { return nil }
        let lengthSize = Int(bytes[4] & 0x03) + 1
        guard lengthSize != 3 else { return nil }
        var offset = 5
        var sets: [Data] = []
        // Three reserved bits and numOfSequenceParameterSets; then numOfPictureParameterSets.
        for mask in [UInt8(0x1F), 0xFF] {
            guard offset < bytes.count else { return nil }
            let count = Int(bytes[offset] & mask)
            offset += 1
            guard let listed = lengthPrefixedUnits(bytes, count: count, offset: &offset) else { return nil }
            sets += listed
        }
        guard !sets.isEmpty else { return nil }
        return NALDecoderConfiguration(codec: .h264, lengthSize: lengthSize, parameterSets: sets)
    }

    /// An `hvcC` record, or nil when it is malformed. Only VPS, SPS and PPS arrays are kept (SEI arrays aren't).
    public static func hevc(_ record: Data) -> NALDecoderConfiguration? {
        record.withUnsafeBytes { raw in hevc(raw.bindMemory(to: UInt8.self)) }
    }

    static func hevc(_ bytes: UnsafeBufferPointer<UInt8>) -> NALDecoderConfiguration? {
        // 21 bytes of profile, level and format facts, then lengthSizeMinusOne and numOfArrays.
        guard bytes.count >= 23, bytes[0] == 1 else { return nil }
        let lengthSize = Int(bytes[21] & 0x03) + 1
        guard lengthSize != 3 else { return nil }
        let arrays = Int(bytes[22])
        var offset = 23
        var byType: [Int: [Data]] = [:]
        for _ in 0..<arrays {
            guard offset + 3 <= bytes.count else { return nil }
            let type = Int(bytes[offset] & 0x3F)
            let count = ByteField.u16(bytes[offset + 1], bytes[offset + 2])
            offset += 3
            guard let units = lengthPrefixedUnits(bytes, count: count, offset: &offset) else { return nil }
            byType[type, default: []] += units
        }
        let sets = [32, 33, 34].flatMap { byType[$0] ?? [] }
        guard !sets.isEmpty else { return nil }
        return NALDecoderConfiguration(codec: .hevc, lengthSize: lengthSize, parameterSets: sets)
    }

    /// `count` units, each after a 16-bit size.
    private static func lengthPrefixedUnits(_ bytes: UnsafeBufferPointer<UInt8>, count: Int,
                                            offset: inout Int) -> [Data]? {
        guard count <= maximumParameterSets else { return nil }
        var units: [Data] = []
        for _ in 0..<count {
            guard offset + 2 <= bytes.count else { return nil }
            let size = ByteField.u16(bytes[offset], bytes[offset + 1])
            offset += 2
            guard size > 0, size <= bytes.count - offset else { return nil }
            units.append(Data(UnsafeBufferPointer(rebasing: bytes[offset..<(offset + size)])))
            offset += size
        }
        return units
    }

    /// Appends `sample` (length-prefixed NAL units) to `output` as Annex B, every unit after a four-byte start code.
    /// With `parameterSets` the configuration's parameter sets go first (in front of a keyframe, so a decoder can
    /// start there). Returns false, leaving `output` as it was, when a length runs past the end of the sample.
    public func appendAnnexB(_ sample: UnsafeBufferPointer<UInt8>, parameterSets: Bool,
                             to output: inout [UInt8]) -> Bool {
        let original = output.count
        let startCode: [UInt8] = [0, 0, 0, 1]
        if parameterSets {
            for set in self.parameterSets {
                output += startCode
                output += set
            }
        }
        var offset = 0
        while offset < sample.count {
            guard lengthSize <= sample.count - offset else { break }
            var size = 0
            for index in 0..<lengthSize { size = (size << 8) | Int(sample[offset + index]) }
            offset += lengthSize
            guard size <= sample.count - offset else {
                output.removeSubrange(original...)
                return false
            }
            if size > 0 {
                output += startCode
                output += UnsafeBufferPointer(rebasing: sample[offset..<(offset + size)])
            }
            offset += size
        }
        return true
    }
}
