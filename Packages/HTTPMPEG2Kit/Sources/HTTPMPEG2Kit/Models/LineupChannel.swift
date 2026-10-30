import Foundation

/// One entry of `lineup.json`.
///
/// Decoding is lenient: only `GuideNumber` is required. Flags arrive as `1`/`0`; an absent `Enabled` or
/// `Subscribed` means enabled and subscribed. The `?tuning` keys are present only when requested, and
/// `TransportStreamID` is missing on some multiplexes even then.
public nonisolated struct LineupChannel: Codable, Sendable, Hashable {
    public let guideNumber: String
    public let guideName: String
    /// The stream URL as the device returned it. Its host follows the request Host; never rewrite it.
    /// Absent when `Subscribed` is 0.
    public let url: URL?
    public let videoCodec: VideoCodec?
    public let audioCodec: AudioCodec?
    /// `HD: 1`.
    public let isHD: Bool
    /// `Favorite: 1`, the favorite flag on current firmware.
    public let favoriteFlag: Bool
    /// `DRM: 1`.
    public let drmFlag: Bool
    /// `Enabled: 0` means hidden in the device's channel editor (seen with `show=found` or `show=all`).
    public let isEnabled: Bool
    /// `Subscribed: 0` means not receivable (seen with `show=all`).
    public let isSubscribed: Bool
    /// Legacy comma-separated `Tags` (for example `"favorite,drm"`), lowercased; empty when absent.
    public let tags: [String]
    public let signalStrength: Int?
    public let signalQuality: Int?
    // `?tuning` keys.
    public let frequency: Int?
    public let modulation: String?
    public let programNumber: Int?
    public let transportStreamID: Int?
    public let plpConfig: String?

    public init(
        guideNumber: String,
        guideName: String = "",
        url: URL? = nil,
        videoCodec: VideoCodec? = nil,
        audioCodec: AudioCodec? = nil,
        isHD: Bool = false,
        favoriteFlag: Bool = false,
        drmFlag: Bool = false,
        isEnabled: Bool = true,
        isSubscribed: Bool = true,
        tags: [String] = [],
        signalStrength: Int? = nil,
        signalQuality: Int? = nil,
        frequency: Int? = nil,
        modulation: String? = nil,
        programNumber: Int? = nil,
        transportStreamID: Int? = nil,
        plpConfig: String? = nil
    ) {
        self.guideNumber = guideNumber
        self.guideName = guideName
        self.url = url
        self.videoCodec = videoCodec
        self.audioCodec = audioCodec
        self.isHD = isHD
        self.favoriteFlag = favoriteFlag
        self.drmFlag = drmFlag
        self.isEnabled = isEnabled
        self.isSubscribed = isSubscribed
        self.tags = tags
        self.signalStrength = signalStrength
        self.signalQuality = signalQuality
        self.frequency = frequency
        self.modulation = modulation
        self.programNumber = programNumber
        self.transportStreamID = transportStreamID
        self.plpConfig = plpConfig
    }

    /// `Favorite: 1`, or the legacy `Tags` contains `favorite`.
    public var isFavorite: Bool { favoriteFlag || tags.contains("favorite") }

    /// `DRM: 1`, or the legacy `Tags` contains `drm`. Such channels fail with 811 and must not be requested.
    public var isDRM: Bool { drmFlag || tags.contains("drm") }

    /// ATSC 3.0: `Modulation` is `atsc3`, or the video is HEVC, or the audio is AC-4.
    /// The codec test works without `?tuning`.
    public var isATSC3: Bool {
        modulation?.lowercased() == "atsc3" || videoCodec == .hevc || audioCodec == .ac4
    }

    /// Has a URL, is subscribed and is not DRM-protected.
    public var isPlayable: Bool { url != nil && isSubscribed && !isDRM }

    /// The channel's identity under the given lineup source (`LineupStatus.source`, e.g. `Antenna`).
    public func channelKey(source: String) -> ChannelKey {
        ChannelKey(source: source, guideNumber: guideNumber)
    }

    private enum CodingKeys: String, CodingKey {
        case guideNumber = "GuideNumber"
        case guideName = "GuideName"
        case url = "URL"
        case videoCodec = "VideoCodec"
        case audioCodec = "AudioCodec"
        case isHD = "HD"
        case favoriteFlag = "Favorite"
        case drmFlag = "DRM"
        case isEnabled = "Enabled"
        case isSubscribed = "Subscribed"
        case tags = "Tags"
        case signalStrength = "SignalStrength"
        case signalQuality = "SignalQuality"
        case frequency = "Frequency"
        case modulation = "Modulation"
        case programNumber = "ProgramNumber"
        case transportStreamID = "TransportStreamID"
        case plpConfig = "PLPConfig"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        guard let guideNumber = container.lenientString(.guideNumber)?
            .trimmingCharacters(in: .whitespaces), !guideNumber.isEmpty else {
            throw DecodingError.dataCorruptedError(
                forKey: .guideNumber, in: container, debugDescription: "Missing GuideNumber")
        }
        self.guideNumber = guideNumber
        guideName = container.lenientString(.guideName) ?? ""
        url = container.lenientURL(.url)
        videoCodec = container.lenientString(.videoCodec).map(VideoCodec.init(rawValue:))
        audioCodec = container.lenientString(.audioCodec).map(AudioCodec.init(rawValue:))
        isHD = container.lenientBool(.isHD) ?? false
        favoriteFlag = container.lenientBool(.favoriteFlag) ?? false
        drmFlag = container.lenientBool(.drmFlag) ?? false
        isEnabled = container.lenientBool(.isEnabled) ?? true
        isSubscribed = container.lenientBool(.isSubscribed) ?? true
        tags = Self.parseTags(container.lenientString(.tags))
        signalStrength = container.lenientInt(.signalStrength)
        signalQuality = container.lenientInt(.signalQuality)
        frequency = container.lenientInt(.frequency)
        modulation = container.lenientString(.modulation)
        programNumber = container.lenientInt(.programNumber)
        transportStreamID = container.lenientInt(.transportStreamID)
        plpConfig = container.lenientString(.plpConfig)
    }

    /// Encodes with the device's key names, so a cached lineup decodes the same way.
    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(guideNumber, forKey: .guideNumber)
        try container.encode(guideName, forKey: .guideName)
        try container.encodeIfPresent(url?.absoluteString, forKey: .url)
        try container.encodeIfPresent(videoCodec?.rawValue, forKey: .videoCodec)
        try container.encodeIfPresent(audioCodec?.rawValue, forKey: .audioCodec)
        try Self.encodeFlag(isHD, when: true, forKey: .isHD, in: &container)
        try Self.encodeFlag(favoriteFlag, when: true, forKey: .favoriteFlag, in: &container)
        try Self.encodeFlag(drmFlag, when: true, forKey: .drmFlag, in: &container)
        try Self.encodeFlag(isEnabled, when: false, forKey: .isEnabled, in: &container)
        try Self.encodeFlag(isSubscribed, when: false, forKey: .isSubscribed, in: &container)
        if !tags.isEmpty {
            try container.encode(tags.joined(separator: ","), forKey: .tags)
        }
        try container.encodeIfPresent(signalStrength, forKey: .signalStrength)
        try container.encodeIfPresent(signalQuality, forKey: .signalQuality)
        try container.encodeIfPresent(frequency, forKey: .frequency)
        try container.encodeIfPresent(modulation, forKey: .modulation)
        try container.encodeIfPresent(programNumber, forKey: .programNumber)
        try container.encodeIfPresent(transportStreamID, forKey: .transportStreamID)
        try container.encodeIfPresent(plpConfig, forKey: .plpConfig)
    }

    /// Writes a flag the way the device does: only when it differs from the default, as 1 or 0.
    private static func encodeFlag(
        _ value: Bool, when written: Bool, forKey key: CodingKeys,
        in container: inout KeyedEncodingContainer<CodingKeys>
    ) throws {
        guard value == written else { return }
        try container.encode(value ? 1 : 0, forKey: key)
    }

    static func parseTags(_ string: String?) -> [String] {
        guard let string else { return [] }
        return string.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces).lowercased() }
            .filter { !$0.isEmpty }
    }
}
