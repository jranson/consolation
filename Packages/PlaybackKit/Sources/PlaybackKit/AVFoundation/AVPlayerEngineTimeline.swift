//
//  AVPlayerEngineTimeline.swift
//  PlaybackKit
//
//  The timeline for AVPlayer's content: on-demand HLS, DASH and files from 0 to their duration; live streams over their
//  last seekable range, up to AVPlayer's own distance from the live edge. Seeks are accurate to `seekTolerance` and
//  never pile up: while one is in flight, a newer request replaces any waiting one, and only the latest runs when it
//  finishes (fast scrubbing). Until it finishes, the position reported is the target. Seeks go through
//  `seek(to:tolerance:completion:)`, so a tone-mapped split's audio follows.
//

import AVFoundation
import CoreMedia
import Foundation

/// The seek in flight and the one waiting behind it.
nonisolated struct SeekQueue {
    /// The position the latest request asked for, reported until the seeks settle.
    var target: Double?
    var inFlight = false
    var waiting: Double?
    /// The content had ended: play on once the seeks land (a play while still at the end can be ignored).
    var resumesWhenDone = false
}

extension AVPlayerEngine {
    /// How far either side of the target an accurate seek may land.
    nonisolated static let seekTolerance = CMTime(value: 1, timescale: 5)

    /// Nil until the item is ready and has a duration or a seekable range.
    public func timeline() -> PlaybackTimeline? {
        guard isItemReady, let item = player.currentItem else { return nil }
        return Self.timeline(duration: item.duration, seekable: item.seekableTimeRanges.map(\.timeRangeValue),
                             position: seeks.target ?? currentTime, liveOffset: item.recommendedTimeOffsetFromLive)
    }

    /// Seeks within the timeline (clamped), keeping the pause; content that ended plays on from the new point.
    public func seek(toPosition position: Double) {
        guard let timeline = timeline(), position.isFinite else { return }
        let target = min(max(position, timeline.range.lowerBound), timeline.range.upperBound)
        seeks.target = target
        if state == .ended {
            state = .buffering
            seeks.resumesWhenDone = true
        }
        guard !seeks.inFlight else {
            seeks.waiting = target
            return
        }
        startSeek(to: target)
    }

    /// With `startsAtBeginning`, live content moves from AVPlayer's start near the live edge to the start of its
    /// seekable range, once, when it first becomes ready.
    func seekToStartIfAsked(_ item: AVPlayerItem) {
        guard configuration.startsAtBeginning, item.duration.isIndefinite,
              let timeline = timeline(), timeline.isLive else { return }
        seek(toPosition: timeline.range.lowerBound)
    }

    private func startSeek(to target: Double) {
        seeks.inFlight = true
        let token = generation
        seek(to: target, tolerance: Self.seekTolerance) { [weak self] _ in
            guard let self else { return }
            // A new item (a repair, a split fallback or a stop) starts with no seeks.
            guard self.generation == token else {
                self.seeks = SeekQueue()
                return
            }
            self.seeks.inFlight = false
            if let next = self.seeks.waiting {
                self.seeks.waiting = nil
                self.startSeek(to: next)
            } else {
                self.seeks.target = nil
                if self.seeks.resumesWhenDone {
                    self.seeks.resumesWhenDone = false
                    if let follower = self.follower { follower.resume() } else { self.player.play() }
                }
            }
        }
    }

    /// The timeline for an item's duration and seekable ranges: a numeric duration is on-demand content; an
    /// indefinite one is live, over the last seekable range, ending `liveOffset` (AVPlayer's recommended distance
    /// from the live edge, where it plays live) before its end.
    nonisolated static func timeline(duration: CMTime, seekable: [CMTimeRange], position: Double,
                                     liveOffset: CMTime) -> PlaybackTimeline? {
        if duration.isNumeric {
            let seconds = duration.seconds
            guard seconds.isFinite, seconds > 0 else { return nil }
            return PlaybackTimeline(range: 0...seconds, position: position, isLive: false)
        }
        guard duration.isIndefinite, let last = seekable.last(where: { $0.isValid && $0.duration.seconds > 0 }) else {
            return nil
        }
        let start = last.start.seconds
        let end = last.end.seconds
        guard start.isFinite, end.isFinite else { return nil }
        let offset = liveOffset.isNumeric && liveOffset.seconds.isFinite ? max(0, liveOffset.seconds) : 0
        return PlaybackTimeline(range: start...max(start, end - offset), position: position, isLive: true)
    }
}
