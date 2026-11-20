import Foundation

/// A suspected commercial break in a piece of media, in seconds from its start (as a player's position counts
/// them). Detection is a heuristic, so a player offers to skip a break rather than skipping it by itself.
public nonisolated struct AdBreak: Hashable, Sendable {
    public var start: Double
    /// Where the program resumes: seek here to skip the break.
    public var end: Double

    public init(start: Double, end: Double) {
        self.start = start
        self.end = end
    }

    /// The last moment of a break isn't worth a button: it would be gone before it could be pressed.
    public static let lastMoment = 1.0

    /// The break playing at `position` (seconds from the media's start), if there's one worth skipping.
    public static func playing(at position: Double, in breaks: [AdBreak]) -> AdBreak? {
        breaks.first { position >= $0.start && position < $0.end - lastMoment }
    }
}

/// What a source knows of an item's commercial breaks.
public nonisolated struct AdBreakList: Hashable, Sendable {
    /// In order, not overlapping; empty when none were found (or detection never ran).
    public var breaks: [AdBreak]
    /// Detection is still working: asking again later may find breaks.
    public var isPending: Bool

    public init(breaks: [AdBreak], isPending: Bool = false) {
        self.breaks = breaks
        self.isPending = isPending
    }

    public static let none = AdBreakList(breaks: [])
}
