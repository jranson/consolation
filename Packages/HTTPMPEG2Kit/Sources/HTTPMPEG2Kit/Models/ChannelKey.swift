import Foundation

/// The one channel identity: the lineup source plus the guide number.
///
/// Its string form is `tvch:<source>:<guideNumber>`, for example `tvch:Antenna:9.1`. It never contains a
/// DeviceID, host or IP address, so two devices on the same source that both list 7.1 share one key.
/// It encodes as that string, so it can be persisted as-is.
public nonisolated struct ChannelKey: Hashable, Sendable, Codable, Comparable, CustomStringConvertible {
    public static let scheme = "tvch"

    /// The lineup source, for example `Antenna` or `Cable` (from `LineupStatus.source`).
    public let source: String
    /// The virtual channel, for example `7.1` (ATSC) or `702` (cable).
    public let guideNumber: String

    public init(source: String, guideNumber: String) {
        self.source = source
        self.guideNumber = guideNumber
    }

    /// Parses `tvch:<source>:<guideNumber>`. Guide numbers never contain a colon, so the last colon
    /// separates the two parts.
    public init?(stringValue: String) {
        let prefix = Self.scheme + ":"
        guard stringValue.hasPrefix(prefix) else { return nil }
        let rest = stringValue.dropFirst(prefix.count)
        guard let separator = rest.lastIndex(of: ":") else { return nil }
        let source = String(rest[..<separator])
        let guideNumber = String(rest[rest.index(after: separator)...])
        guard !source.isEmpty, !guideNumber.isEmpty else { return nil }
        self.init(source: source, guideNumber: guideNumber)
    }

    public var stringValue: String { "\(Self.scheme):\(source):\(guideNumber)" }

    public var description: String { stringValue }

    /// Orders by source, then by guide number numerically (2.1 < 4.1 < 20.1 < 20.4 < 31.1).
    public static func < (lhs: ChannelKey, rhs: ChannelKey) -> Bool {
        if lhs.source != rhs.source { return lhs.source < rhs.source }
        return GuideNumberOrder.areInIncreasingOrder(lhs.guideNumber, rhs.guideNumber)
    }

    public init(from decoder: any Decoder) throws {
        let container = try decoder.singleValueContainer()
        let string = try container.decode(String.self)
        guard let key = ChannelKey(stringValue: string) else {
            throw DecodingError.dataCorruptedError(in: container, debugDescription: "Not a ChannelKey")
        }
        self = key
    }

    public func encode(to encoder: any Encoder) throws {
        var container = encoder.singleValueContainer()
        try container.encode(stringValue)
    }
}

/// Numeric ordering for guide numbers: major, then minor (`2.1 < 4.1 < 20.1 < 20.4 < 31.1`, `7 < 7.1`).
/// Locale-independent. Unparseable guide numbers sort after numeric ones, by plain string order.
public nonisolated enum GuideNumberOrder {
    /// `"20.4"` → (20, 4), `"7-1"` → (7, 1), `"702"` → (702, nil); nil when not numeric.
    public static func parts(of guideNumber: String) -> (major: Int, minor: Int?)? {
        let pieces = guideNumber.trimmingCharacters(in: .whitespaces)
            .split(maxSplits: 1, omittingEmptySubsequences: false) { $0 == "." || $0 == "-" }
        guard let first = pieces.first, let major = number(first) else { return nil }
        guard pieces.count == 2 else { return (major, nil) }
        guard let minor = number(pieces[1]) else { return nil }
        return (major, minor)
    }

    /// True when `lhs` sorts before `rhs`.
    public static func areInIncreasingOrder(_ lhs: String, _ rhs: String) -> Bool {
        switch (parts(of: lhs), parts(of: rhs)) {
        case let (left?, right?):
            if left.major != right.major { return left.major < right.major }
            if left.minor != right.minor { return (left.minor ?? -1) < (right.minor ?? -1) }
            return lhs < rhs
        case (.some, .none):
            return true
        case (.none, .some):
            return false
        case (.none, .none):
            return lhs < rhs
        }
    }

    private static func number(_ digits: Substring) -> Int? {
        guard !digits.isEmpty, digits.allSatisfy({ $0.isASCII && $0.isNumber }) else { return nil }
        return Int(digits)
    }
}

extension Sequence where Element == LineupChannel {
    /// The channels in guide-number order (2.1, 4.1, 20.1, 20.4, 31.1).
    public nonisolated func sortedByGuideNumber() -> [LineupChannel] {
        sorted { GuideNumberOrder.areInIncreasingOrder($0.guideNumber, $1.guideNumber) }
    }
}
