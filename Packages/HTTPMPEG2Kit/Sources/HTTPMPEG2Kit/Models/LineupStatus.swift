import Foundation

/// A device's `lineup_status.json`.
///
/// `Source` is part of every channel's identity (`ChannelKey`). While a scan runs, stream requests fail
/// with 803. `Progress` and `Found` are only reported during a scan (believed, not yet observed).
public nonisolated struct LineupStatus: Codable, Sendable, Hashable {
    public let scanInProgress: Bool
    public let scanPossible: Bool
    /// The active lineup source, for example `Antenna` or `Cable`.
    public let source: String?
    public let sourceList: [String]
    public let progress: Int?
    public let found: Int?

    public init(
        scanInProgress: Bool = false,
        scanPossible: Bool = false,
        source: String? = nil,
        sourceList: [String] = [],
        progress: Int? = nil,
        found: Int? = nil
    ) {
        self.scanInProgress = scanInProgress
        self.scanPossible = scanPossible
        self.source = source
        self.sourceList = sourceList
        self.progress = progress
        self.found = found
    }

    private enum CodingKeys: String, CodingKey {
        case scanInProgress = "ScanInProgress"
        case scanPossible = "ScanPossible"
        case source = "Source"
        case sourceList = "SourceList"
        case progress = "Progress"
        case found = "Found"
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        scanInProgress = container.lenientBool(.scanInProgress) ?? false
        scanPossible = container.lenientBool(.scanPossible) ?? false
        source = container.lenientString(.source)
        sourceList = container.lenientStrings(.sourceList)
        progress = container.lenientInt(.progress)
        found = container.lenientInt(.found)
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(scanInProgress ? 1 : 0, forKey: .scanInProgress)
        try container.encode(scanPossible ? 1 : 0, forKey: .scanPossible)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encode(sourceList, forKey: .sourceList)
        try container.encodeIfPresent(progress, forKey: .progress)
        try container.encodeIfPresent(found, forKey: .found)
    }
}
