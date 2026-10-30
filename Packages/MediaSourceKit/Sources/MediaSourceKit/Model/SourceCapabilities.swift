import Foundation

/// What a source can do, reported after it connects (a Plex server without a DVR drops `recordings`). The UI picks
/// shelves, buttons and settings from these and never branches on `SourceKind`.
public nonisolated struct SourceCapabilities: OptionSet, Hashable, Codable, Sendable {
    public let rawValue: UInt32

    public init(rawValue: UInt32) {
        self.rawValue = rawValue
    }

    public static let browse = Self(rawValue: 1 << 0)
    public static let search = Self(rawValue: 1 << 1)
    public static let liveTV = Self(rawValue: 1 << 2)
    public static let recordings = Self(rawValue: 1 << 3)
    public static let inProgressRecordings = Self(rawValue: 1 << 4)
    public static let guide = Self(rawValue: 1 << 5)
    public static let serverArtwork = Self(rawValue: 1 << 6)
    public static let watchStateRead = Self(rawValue: 1 << 7)
    /// Opt-in only.
    public static let watchStateWrite = Self(rawValue: 1 << 8)
    public static let directPlay = Self(rawValue: 1 << 9)
    /// A last-resort fallback only.
    public static let serverTranscode = Self(rawValue: 1 << 10)
    public static let tunerAccounting = Self(rawValue: 1 << 11)
    public static let lanDiscovery = Self(rawValue: 1 << 12)
    public static let requiresAuth = Self(rawValue: 1 << 13)
    /// Never on by default.
    public static let destructiveOps = Self(rawValue: 1 << 14)
}
