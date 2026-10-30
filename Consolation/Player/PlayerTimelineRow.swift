//
//  PlayerTimelineRow.swift
//  Consolation
//
//  The row under the controls' buttons: the LIVE indicator (live content only) to the left of the timeline
//  scrubber, then the times. On-demand content shows elapsed and remaining time; live content shows how far behind
//  the live edge playback is.
//

import PlaybackKit
import SwiftUI

struct PlayerTimelineRow: View {
    let timeline: PlaybackTimeline
    /// Moves playback to a position the user committed on the scrubber.
    let onSeek: (Double) -> Void
    /// The user is working the scrubber (keeps the controls up).
    var onActivity: () -> Void = {}

    /// The point being scrubbed to, before it is committed (shown in the time labels).
    @State private var pending: Double?

    var body: some View {
        HStack(spacing: 14) {
            if timeline.isLive {
                LiveBadge(timeline: timeline)
            } else {
                timeLabel(TimeLabel.text(timeline.elapsed(at: pending)), alignment: .leading)
            }
            TimelineScrubber(timeline: timeline, pending: $pending, onCommit: onSeek, onActivity: onActivity)
            timeLabel(trailingLabel, sign: "−", alignment: .trailing)
        }
    }

    /// A time in a width that fits any time this timeline can show, so the scrubber between the labels keeps its
    /// size while the times change (seeking from 0:30 to 1:05:13 would otherwise move the whole track).
    private func timeLabel(_ text: String, sign: String = "", alignment: Alignment) -> some View {
        Text(sign + TimeLabel.widest(for: timeline.duration))
            .hidden()
            .overlay(alignment: alignment) { Text(text) }
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(text)
    }

    /// On demand: the time left. Live: how far behind the live edge the (pending) position is.
    private var trailingLabel: String {
        let position = pending ?? timeline.position
        let remaining = timeline.range.upperBound - position
        if timeline.isLive {
            return remaining <= PlaybackTimeline.liveTolerance ? "" : "−" + TimeLabel.text(remaining)
        }
        return "−" + TimeLabel.text(remaining)
    }
}

/// "LIVE" in red at the live edge; otherwise a dimmed "LIVE" (playback is behind it; Go to Live returns).
private struct LiveBadge: View {
    let timeline: PlaybackTimeline

    var body: some View {
        Text("LIVE")
            .font(.caption.weight(.heavy))
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(timeline.isAtLiveEdge ? Color.red : Color.secondary.opacity(0.35), in: .capsule)
            .foregroundStyle(.white)
            .accessibilityLabel(timeline.isAtLiveEdge ? "Live" : "Behind live")
    }
}

extension PlaybackTimeline {
    /// Seconds from the start of the range to `position` (or the position now).
    func elapsed(at position: Double?) -> Double {
        (position ?? self.position) - range.lowerBound
    }
}

/// "4:05" or "1:02:03".
enum TimeLabel {
    static func text(_ seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        let hours = total / 3_600
        let minutes = total / 60 % 60
        let secs = total % 60
        return hours > 0 ? String(format: "%d:%02d:%02d", hours, minutes, secs)
            : String(format: "%d:%02d", minutes, secs)
    }

    /// The widest time up to `seconds` ("00:00", "0:00:00", "00:00:00"), to reserve a label's width. Digits are
    /// drawn monospaced, so any digits of that shape take the same room.
    static func widest(for seconds: Double) -> String {
        let total = max(Int(seconds.rounded()), 0)
        if total >= 36_000 { return "00:00:00" }
        if total >= 3_600 { return "0:00:00" }
        return "00:00"
    }
}
