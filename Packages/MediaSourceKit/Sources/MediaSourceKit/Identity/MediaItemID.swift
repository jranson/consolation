import Foundation
import HTTPMPEG2Kit

/// One item of one source: the source plus a source-specific key.
///
/// Key forms: HDHomeRun live `ch:<GuideNumber>`, Quick Play `url:<SHA-256 hex of the URL>`, Folder and SMB
/// `file:<relative path>`, Plex `plex:<ratingKey>`. A key never holds a DeviceID, host, IP address or a URL that could
/// carry a token.
public nonisolated struct MediaItemID: Hashable, Codable, Sendable, CustomStringConvertible {
    public let source: SourceID
    public let key: String

    public init(source: SourceID, key: String) {
        self.source = source
        self.key = key
    }

    /// Prefix of HDHomeRun live channel keys: `ch:9.1`.
    public static let channelKeyPrefix = "ch:"
    /// Prefix of keys made from a hashed URL: `url:<SHA-256 hex>`.
    public static let urlKeyPrefix = "url:"

    /// The stable card identity in Home, `"<SourceID.raw>:<key>"`, for example `hdhr-live:Antenna:ch:7.1`.
    /// It is never parsed back: use `source` and `key`.
    public var cardID: String { "\(source.raw):\(key)" }

    public var description: String { cardID }

    /// The HDHomeRun live item for a channel: `hdhr-live:<source>` plus `ch:<GuideNumber>`, a 1:1 mapping of
    /// `ChannelKey` (`tvch:Antenna:9.1` becomes `hdhr-live:Antenna` + `ch:9.1`).
    public init(channel: ChannelKey) {
        self.init(source: .hdhomerunLive(lineupSource: channel.source),
                  key: Self.channelKeyPrefix + channel.guideNumber)
    }

    /// The `ChannelKey` of an HDHomeRun live item, otherwise nil. The inverse of `init(channel:)`.
    public var channelKey: ChannelKey? {
        guard let lineupSource = source.hdhomerunLineupSource, key.hasPrefix(Self.channelKeyPrefix) else {
            return nil
        }
        let guideNumber = String(key.dropFirst(Self.channelKeyPrefix.count))
        guard !guideNumber.isEmpty else { return nil }
        return ChannelKey(source: lineupSource, guideNumber: guideNumber)
    }
}
