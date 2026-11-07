//
//  AudioSpecificConfig.swift
//  MPEGTS
//
//  MPEG-4 Audio's AudioSpecificConfig (ISO/IEC 14496-3 §1.6.2.1), the setup data of an AAC stream as Matroska's
//  CodecPrivate and MP4's `esds` carry it: the audio object type, sample rate and channel configuration, with the
//  SBR (HE-AAC) and PS (HE-AAC v2) extensions. A config can also be written from those facts, for files that name
//  the profile in their codec ID instead of storing one.
//

import Foundation

nonisolated public struct AudioSpecificConfig: Sendable, Equatable {
    /// 2 is AAC LC; 5 is SBR (HE-AAC); 29 is PS (HE-AAC v2).
    public var objectType: Int
    /// The core decoder's sample rate.
    public var sampleRate: Int
    /// channelConfiguration: 1-6 are 1 to 6 channels, 7 is 8 channels; 0 means a program config element says.
    public var channelConfiguration: Int
    /// The output rate of SBR (HE-AAC) streams, twice the core rate as a rule; nil without SBR.
    public var extensionSampleRate: Int?
    /// 5 (SBR) or 29 (PS, which implies SBR) when the config signals the extension explicitly.
    public var extensionObjectType: Int?
    /// The config's bytes as read (or as written by `init(objectType:sampleRate:channels:)`).
    public var bytes: Data

    static let sampleRates = [96_000, 88_200, 64_000, 48_000, 44_100, 32_000, 24_000, 22_050, 16_000, 12_000,
                              11_025, 8_000, 7_350]

    /// Core object types an AAC decoder may take: Main, LC, SSR, LTP, and the ER LC, LD and ELD types.
    static let decodableTypes: Set<Int> = [1, 2, 3, 4, 17, 23, 39]

    public static let objectTypeLC = 2
    public static let objectTypeSBR = 5
    public static let objectTypePS = 29

    /// Channels for the channel configuration (0 when it isn't one of the standard layouts).
    public var channelCount: Int {
        switch channelConfiguration {
        case 1...6: channelConfiguration
        case 7: 8
        default: 0
        }
    }

    /// Output samples per frame: 1024 for AAC, doubled by SBR.
    public var samplesPerFrame: Int { extensionSampleRate == nil ? 1_024 : 2_048 }

    /// The rate the decoder outputs.
    public var outputSampleRate: Int { extensionSampleRate ?? sampleRate }

    /// The profile as people know it: "HE-AAC v2" with PS, "HE-AAC" with SBR, else "AAC".
    public var profileName: String {
        if extensionObjectType == Self.objectTypePS { return "HE-AAC v2" }
        return extensionSampleRate == nil ? "AAC" : "HE-AAC"
    }

    /// Parses a config; nil when it is malformed or names a rate or object type that can't be AAC.
    public init?(_ data: Data) {
        guard !data.isEmpty, data.count <= 64 else { return nil }
        let parsed: AudioSpecificConfig? = data.withUnsafeBytes { raw in
            var reader = BitReader(raw.bindMemory(to: UInt8.self))
            var config = AudioSpecificConfig(bytes: data, objectType: Self.objectType(&reader))
            guard let rate = Self.sampleRate(&reader) else { return nil }
            config.sampleRate = rate
            config.channelConfiguration = reader.int(4)
            if config.objectType == Self.objectTypeSBR || config.objectType == Self.objectTypePS {
                // Explicit hierarchical signalling: the extension rate, then the core object type.
                config.extensionObjectType = config.objectType
                config.extensionSampleRate = Self.sampleRate(&reader)
                config.objectType = Self.objectType(&reader)
            }
            return reader.isOverrun ? nil : config
        }
        guard let parsed, Self.decodableTypes.contains(parsed.objectType) else { return nil }
        self = parsed
    }

    private init(bytes: Data, objectType: Int) {
        self.bytes = bytes
        self.objectType = objectType
        sampleRate = 0
        channelConfiguration = 0
    }

    /// A two-byte config for a plain AAC stream (object type 2 for LC), from its rate and channel count, for
    /// streams whose container names the profile instead of storing a config. Nil for a rate outside the table.
    public init?(objectType: Int = AudioSpecificConfig.objectTypeLC, sampleRate: Int, channels: Int) {
        guard let index = Self.sampleRates.firstIndex(of: sampleRate), (1...31).contains(objectType) else {
            return nil
        }
        let configuration = channels == 8 ? 7 : min(max(channels, 1), 6)
        // objectType (5 bits), samplingFrequencyIndex (4 bits), channelConfiguration (4 bits), three zero bits.
        let bits = (objectType << 11) | (index << 7) | (configuration << 3)
        self.objectType = objectType
        self.sampleRate = sampleRate
        channelConfiguration = configuration
        extensionSampleRate = nil
        extensionObjectType = nil
        bytes = Data([UInt8(truncatingIfNeeded: bits >> 8), UInt8(truncatingIfNeeded: bits)])
    }

    /// This core config with SBR (and, with `parametricStereo`, PS) signalled explicitly, hierarchically, at
    /// `outputSampleRate`: for streams that show SBR only in their payload (ADTS, and old Matroska files). Nil for a
    /// rate outside the table.
    public func signallingSBR(outputSampleRate: Int, parametricStereo: Bool = false) -> AudioSpecificConfig? {
        guard let core = Self.sampleRates.firstIndex(of: sampleRate),
              let output = Self.sampleRates.firstIndex(of: outputSampleRate), (1...30).contains(objectType) else {
            return nil
        }
        let type = parametricStereo ? Self.objectTypePS : Self.objectTypeSBR
        // Extension object type (5 bits), core rate index (4), channelConfiguration (4), extension rate index (4),
        // core object type (5) and three zero GASpecificConfig bits: 25 bits in four bytes.
        let bits = (type << 27) | (core << 23) | ((channelConfiguration & 0x0F) << 19) | (output << 15)
            | (objectType << 10)
        var config = self
        config.extensionObjectType = type
        config.extensionSampleRate = outputSampleRate
        config.bytes = Data([24, 16, 8, 0].map { UInt8(truncatingIfNeeded: bits >> $0) })
        return config
    }

    private static func objectType(_ reader: inout BitReader) -> Int {
        let type = reader.int(5)
        return type == 31 ? 32 + reader.int(6) : type
    }

    private static func sampleRate(_ reader: inout BitReader) -> Int? {
        let index = reader.int(4)
        guard index == 15 else { return index < sampleRates.count ? sampleRates[index] : nil }
        let explicit = reader.int(24)
        return explicit > 0 ? explicit : nil
    }
}
