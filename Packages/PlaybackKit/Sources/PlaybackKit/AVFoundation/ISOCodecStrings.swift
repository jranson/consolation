//
//  ISOCodecStrings.swift
//  PlaybackKit
//
//  RFC 6381 codec strings, HLS VIDEO-RANGE and channel counts derived from sample-entry configuration boxes
//  (hvcC, avcC, esds, dac3, dec3, colr). Inputs are box payloads (the bytes after the box header) and are untrusted.
//

import Foundation

/// The HLS `VIDEO-RANGE` attribute.
public nonisolated enum HLSVideoRange: String, Equatable, Sendable {
    case sdr = "SDR"
    case hlg = "HLG"
    case perceptualQuantizer = "PQ"

    /// Maps ITU-T H.273 transfer characteristics: 16 is SMPTE ST 2084 (PQ), 18 is ARIB STD-B67 (HLG).
    public init(transferCharacteristics: Int) {
        switch transferCharacteristics {
        case 16: self = .perceptualQuantizer
        case 18: self = .hlg
        default: self = .sdr
        }
    }
}

/// What an `esds` box says about an MPEG-4 audio stream.
nonisolated struct ISOAudioConfig: Equatable, Sendable {
    var codecs: String
    var channels: Int?
    var sampleRate: Int?
}

/// MSB-first bit reader over a byte array. Reads past the end return nil.
nonisolated struct ISOBitReader {
    private let bytes: [UInt8]
    private(set) var bitOffset = 0

    init<Bytes: Collection>(_ bytes: Bytes) where Bytes.Element == UInt8 {
        self.bytes = Array(bytes)
    }

    mutating func read(_ count: Int) -> Int? {
        guard count >= 0, count <= 32, bitOffset + count <= bytes.count * 8 else { return nil }
        var value = 0
        for _ in 0..<count {
            let byte = bytes[bitOffset >> 3]
            let bit = (Int(byte) >> (7 - (bitOffset & 7))) & 1
            value = value << 1 | bit
            bitOffset += 1
        }
        return value
    }
}

nonisolated enum ISOCodecStrings {
    /// `hvc1.2.4.L150.90` style string from an `hvcC` payload.
    static func hevc(hvcC payload: ArraySlice<UInt8>, sampleEntry: String) -> String? {
        let config = Array(payload)
        guard config.count >= 13 else { return nil }
        let spaces = ["", "A", "B", "C"]
        let profileSpace = spaces[Int(config[1] >> 6)]
        let tier = (config[1] >> 5) & 1 == 1 ? "H" : "L"
        let profileIdc = config[1] & 0x1F
        var compatibility: UInt32 = 0
        for index in 2...5 {
            compatibility = compatibility << 8 | UInt32(config[index])
        }
        var reversed: UInt32 = 0
        for bit in 0..<32 where compatibility & (1 << UInt32(bit)) != 0 {
            reversed |= 1 << UInt32(31 - bit)
        }
        var constraints = Array(config[6..<12])
        while constraints.last == 0 {
            constraints.removeLast()
        }
        var parts = [sampleEntry, "\(profileSpace)\(profileIdc)", String(reversed, radix: 16, uppercase: true),
                     "\(tier)\(config[12])"]
        parts.append(contentsOf: constraints.map { hexByte($0) })
        return parts.joined(separator: ".")
    }

    /// `avc1.PPCCLL` from an `avcC` payload.
    static func avc(avcC payload: ArraySlice<UInt8>, sampleEntry: String) -> String? {
        let config = Array(payload)
        guard config.count >= 4, config[0] == 1 else { return nil }
        return "\(sampleEntry).\(hexByte(config[1]))\(hexByte(config[2]))\(hexByte(config[3]))"
    }

    /// The colour transfer characteristics from a `colr` payload of type `nclx` (ISO) or `nclc` (QuickTime).
    static func transferCharacteristics(colr payload: ArraySlice<UInt8>) -> Int? {
        let bytes = Array(payload)
        guard bytes.count >= 10 else { return nil }
        let type = bytes[0..<4]
        guard type.elementsEqual("nclx".utf8) || type.elementsEqual("nclc".utf8) else { return nil }
        return Int(bytes[6]) << 8 | Int(bytes[7])
    }

    /// `mp4a.40.<aot>` (or `mp4a.<oti>` for other object types), channels and sample rate from an `esds` payload.
    static func mpeg4Audio(esds payload: ArraySlice<UInt8>) -> ISOAudioConfig? {
        var cursor = DescriptorCursor(bytes: Array(payload))
        guard cursor.skip(4), let esHeader = cursor.descriptorHeader(), esHeader.tag == 0x03 else { return nil }
        guard cursor.skip(2), let flags = cursor.byte() else { return nil }
        if flags & 0x80 != 0, !cursor.skip(2) { return nil }
        if flags & 0x40 != 0 {
            guard let urlLength = cursor.byte(), cursor.skip(Int(urlLength)) else { return nil }
        }
        if flags & 0x20 != 0, !cursor.skip(2) { return nil }
        guard let configHeader = cursor.descriptorHeader(), configHeader.tag == 0x04,
              let objectType = cursor.byte(), cursor.skip(12) else { return nil }
        guard objectType == 0x40 else {
            return ISOAudioConfig(codecs: "mp4a.\(hexByte(objectType))", channels: nil, sampleRate: nil)
        }
        guard let specificHeader = cursor.descriptorHeader(), specificHeader.tag == 0x05,
              let specific = cursor.bytes(specificHeader.length) else {
            return ISOAudioConfig(codecs: "mp4a.40.2", channels: nil, sampleRate: nil)
        }
        return audioSpecificConfig(specific)
    }

    /// Channel count from a `dac3` payload (AC-3).
    static func ac3Channels(dac3 payload: ArraySlice<UInt8>) -> Int? {
        var reader = ISOBitReader(payload)
        guard reader.read(10) != nil, let acmod = reader.read(3), let lfe = reader.read(1) else { return nil }
        return acmodChannels[acmod] + lfe
    }

    /// Channel count of the first independent substream from a `dec3` payload (E-AC-3).
    static func eac3Channels(dec3 payload: ArraySlice<UInt8>) -> Int? {
        var reader = ISOBitReader(payload)
        guard reader.read(16) != nil, reader.read(12) != nil, let acmod = reader.read(3), let lfe = reader.read(1),
              reader.read(3) != nil, let dependents = reader.read(4) else { return nil }
        var channels = acmodChannels[acmod] + lfe
        if dependents > 0, let locations = reader.read(9) {
            let pairCounts = [2, 2, 1, 1, 2, 2, 2, 1, 1]
            for (bit, count) in pairCounts.enumerated() where locations & (1 << (8 - bit)) != 0 {
                channels += count
            }
        }
        return channels
    }

    /// AC-3 `acmod` to full-bandwidth channel count.
    static let acmodChannels = [2, 1, 2, 3, 3, 4, 4, 5]

    static func hexByte(_ byte: UInt8) -> String {
        let digits = Array("0123456789ABCDEF")
        return String([digits[Int(byte >> 4)], digits[Int(byte & 0x0F)]])
    }

    private static func audioSpecificConfig(_ bytes: [UInt8]) -> ISOAudioConfig? {
        var reader = ISOBitReader(bytes)
        guard var objectType = reader.read(5) else { return nil }
        if objectType == 31 {
            guard let extended = reader.read(6) else { return nil }
            objectType = 32 + extended
        }
        guard let frequencyIndex = reader.read(4) else { return nil }
        var sampleRate: Int?
        if frequencyIndex == 15 {
            sampleRate = reader.read(24)
        } else if frequencyIndex < sampleRates.count {
            sampleRate = sampleRates[frequencyIndex]
        }
        let configuration = reader.read(4) ?? 0
        return ISOAudioConfig(codecs: "mp4a.40.\(objectType)", channels: channelCount(configuration),
                              sampleRate: sampleRate)
    }

    private static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000,
                                      12_000, 11_025, 8_000, 7_350]

    /// MPEG-4 channelConfiguration to channel count; 0 means "in the program config element" and is unknown here.
    private static func channelCount(_ configuration: Int) -> Int? {
        switch configuration {
        case 1...6: configuration
        case 7, 12, 14: 8
        case 11: 7
        case 13: 24
        default: nil
        }
    }
}

/// Reads MPEG-4 descriptors (tag, then a length of up to four 7-bit groups).
private nonisolated struct DescriptorCursor {
    let bytes: [UInt8]
    var offset = 0

    mutating func byte() -> UInt8? {
        guard offset < bytes.count else { return nil }
        defer { offset += 1 }
        return bytes[offset]
    }

    mutating func skip(_ count: Int) -> Bool {
        guard count >= 0, bytes.count - offset >= count else { return false }
        offset += count
        return true
    }

    mutating func bytes(_ count: Int) -> [UInt8]? {
        guard count >= 0, bytes.count - offset >= count else { return nil }
        defer { offset += count }
        return Array(bytes[offset..<(offset + count)])
    }

    mutating func descriptorHeader() -> (tag: UInt8, length: Int)? {
        guard let tag = byte() else { return nil }
        var length = 0
        for _ in 0..<4 {
            guard let next = byte() else { return nil }
            length = length << 7 | Int(next & 0x7F)
            if next & 0x80 == 0 { return (tag, length) }
        }
        return (tag, length)
    }
}
