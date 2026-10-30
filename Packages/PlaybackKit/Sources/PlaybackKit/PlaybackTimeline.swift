//
//  PlaybackTimeline.swift
//  PlaybackKit
//
//  The scrubbable range of what plays: an on-demand stream's whole length, or a live stream's time-shift buffer up to
//  its live edge. The player's timeline scrubber reads it a few times a second while the controls are up and calls
//  `seek(to:)` when the user commits a point; Back 10 and Forward 30 use `skip(by:)`.
//

import Foundation

/// Where playback is within what can be reached, in seconds on the engine's own clock (only differences and the
/// bounds are meaningful to a host).
nonisolated public struct PlaybackTimeline: Equatable, Sendable {
    /// The earliest and latest reachable points. For a live stream the upper bound is the live edge (what has been
    /// received so far, less the start-up cushion); for on-demand content it is the end.
    public var range: ClosedRange<Double>
    /// The point on screen now.
    public var position: Double
    /// Linear content (a tuner or a live stream): the range grows at the live edge, and "Go to Live" applies.
    public var isLive: Bool

    public init(range: ClosedRange<Double>, position: Double, isLive: Bool) {
        self.range = range
        self.position = min(max(position, range.lowerBound), range.upperBound)
        self.isLive = isLive
    }

    /// Seconds from the position to the end or the live edge.
    public var remaining: Double { range.upperBound - position }

    /// Seconds from the start of the range to the position.
    public var elapsed: Double { position - range.lowerBound }

    /// The length of the range.
    public var duration: Double { range.upperBound - range.lowerBound }

    /// A live stream counts as at the live edge within this many seconds of it.
    public static let liveTolerance = 4.0

    /// Whether a live stream plays at (or within `liveTolerance` of) its live edge.
    public var isAtLiveEdge: Bool { isLive && remaining <= Self.liveTolerance }

    /// The position as a fraction of the range, 0…1.
    public var fraction: Double {
        duration > 0 ? elapsed / duration : 1
    }

    /// The position for a fraction of the range, 0…1.
    public func position(atFraction fraction: Double) -> Double {
        range.lowerBound + min(max(fraction, 0), 1) * duration
    }
}

public extension PlaybackEngine {
    // Defaults for engines that can't seek: no timeline, and seeking does nothing.
    func timeline() -> PlaybackTimeline? { nil }
    func seek(toPosition position: Double) {}

    /// Moves by `seconds` within the timeline (negative goes back), clamped to it.
    func skip(by seconds: Double) {
        guard let timeline = timeline() else { return }
        let target = min(max(timeline.position + seconds, timeline.range.lowerBound), timeline.range.upperBound)
        seek(toPosition: target)
    }
}
