import Foundation

/// A configured source's identity, stable across launches.
///
/// It uses the server's own identity where one exists (`plex:<machineIdentifier>`, `jf:<ServerId>`), so local
/// favorites and resume points survive removing and re-adding a source; sources without one use a UUID
/// (`folder:<UUID>`). HDHomeRun live TV is one logical source per lineup Source (`hdhr-live:Antenna`). A
/// `SourceID` never contains a DeviceID, host name or IP address. It encodes as its raw string.
public nonisolated struct SourceID: Hashable, Comparable, Codable, Sendable, CustomStringConvertible {
    public let raw: String

    public init(raw: String) {
        self.raw = raw
    }

    static let hdhomerunLivePrefix = "hdhr-live:"

    /// HDHomeRun live TV for one lineup Source, for example `hdhr-live:Antenna`. Every device with that Source
    /// backs the same logical source, so two tuners on one antenna list each channel once.
    public static func hdhomerunLive(lineupSource: String) -> SourceID {
        SourceID(raw: hdhomerunLivePrefix + lineupSource)
    }

    /// The lineup Source of an HDHomeRun live source (`Antenna` for `hdhr-live:Antenna`), otherwise nil.
    public var hdhomerunLineupSource: String? {
        guard raw.hasPrefix(Self.hdhomerunLivePrefix) else { return nil }
        let rest = String(raw.dropFirst(Self.hdhomerunLivePrefix.count))
        return rest.isEmpty ? nil : rest
    }

    /// The Quick Play history on this device. History is never synced, so one ID serves every device.
    public static let quickPlay = SourceID(raw: "quickplay")

    public var description: String { raw }

    public static func < (lhs: SourceID, rhs: SourceID) -> Bool {
        lhs.raw < rhs.raw
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        raw = try container.decode(String.self)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(raw)
    }
}

/// What kind of source a `SourceID` names. The UI decides what to show from `SourceCapabilities`, never from this.
public nonisolated enum SourceKind: String, Codable, Sendable, CaseIterable {
    case hdhomerun
    case quickPlay
    case folder
    case plex
    case smb
    case dlna
    case webdav
    case httpIndex
    case m3u
    case opds
    case bullpen
    case jellyfin
    case emby
    case channelsDVR
    case hdhomerunDVR
    case nfs
}
