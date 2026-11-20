//
//  PlaybackJump.swift
//  Consolation
//
//  Left and right on the video (Apple TV's remote, or a keyboard's arrow keys on any platform) jump 10 s back or
//  ahead, 30 s with Shift on a keyboard, where the stream can seek that way. A run of jumps adds up in a pill in the
//  upper right ("+20s") until 3 s after the last one.
//

import Foundation
import Observation
import PlaybackKit

/// A run of jumps: how far it has moved so far, and where the last one went.
nonisolated struct PlaybackJump: Equatable, Sendable {
    /// Seconds moved in this run (negative: back).
    var total: Double
    /// Where the last jump went, on the engine's clock.
    var target: Double
    /// When the last jump happened.
    var time: ContinuousClock.Instant

    static let step = 10.0
    /// Shift and an arrow key on a keyboard.
    static let largeStep = 30.0
    /// How long the pill stays after the last jump.
    static let pillDuration: Duration = .seconds(3)
    /// A jump that would move less than this (forward at the end) does nothing.
    static let minimumMove = 1.0

    /// The run after jumping `seconds` (negative: back) within `timeline`, continuing `previous` (nil starts a run);
    /// nil when playback can't move that way: forward at a live stream's live edge or at the end, back at the start.
    static func next(after previous: PlaybackJump?, by seconds: Double, in timeline: PlaybackTimeline,
                     isPlaying: Bool, now: ContinuousClock.Instant) -> PlaybackJump? {
        if seconds > 0, timeline.isAtLiveEdge { return nil }
        var start = timeline.position
        if let previous {
            // The engine may not report the last seek yet: start where it went, plus what has played since.
            start = previous.target + (isPlaying ? Self.seconds(now - previous.time) : 0)
        }
        start = min(max(start, timeline.range.lowerBound), timeline.range.upperBound)
        let target = min(max(start + seconds, timeline.range.lowerBound), timeline.range.upperBound)
        guard abs(target - start) >= minimumMove else { return nil }
        return PlaybackJump(total: (previous?.total ?? 0) + target - start, target: target, time: now)
    }

    /// The pill's text: "+10s", "−40s", "+1m 30s".
    var label: String {
        let rounded = Int(total.rounded())
        let sign = rounded > 0 ? "+" : rounded < 0 ? "−" : ""
        let seconds = abs(rounded)
        guard seconds >= 60 else { return "\(sign)\(seconds)s" }
        let remainder = seconds % 60
        return remainder == 0 ? "\(sign)\(seconds / 60)m" : "\(sign)\(seconds / 60)m \(remainder)s"
    }

    private static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}

/// The run of jumps on screen, if any. The player session owns one.
@Observable
final class PlaybackJumps {
    private(set) var current: PlaybackJump?
    @ObservationIgnored private var hideTask: Task<Void, Never>?

    /// Jumps `engine` by `seconds` and shows the run's total for `PlaybackJump.pillDuration` more. Does nothing when
    /// the stream can't seek that way.
    func jump(_ engine: any PlaybackEngine, by seconds: Double) {
        guard let timeline = engine.timeline(),
              let next = PlaybackJump.next(after: current, by: seconds, in: timeline,
                                           isPlaying: engine.state == .playing, now: .now) else { return }
        engine.seek(toPosition: next.target)
        current = next
        hideTask?.cancel()
        hideTask = Task { [weak self] in
            try? await Task.sleep(for: PlaybackJump.pillDuration)
            guard !Task.isCancelled else { return }
            self?.current = nil
        }
    }

    func clear() {
        hideTask?.cancel()
        current = nil
    }
}
