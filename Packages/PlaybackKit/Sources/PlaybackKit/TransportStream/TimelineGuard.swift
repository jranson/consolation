//
//  TimelineGuard.swift
//  PlaybackKit
//
//  Watches the timestamps of the streams being played for jumps: a broadcaster's splice or encoder restart can move
//  them seconds or hours, backwards or forwards, often without a discontinuity indicator. Enqueued as they are,
//  such samples sit far from the clock: the renderers stop taking video, reading stops, and playback stalls for
//  good. On a jump the pipeline starts a new timeline instead, as for a discontinuity.
//
//  Streams don't jump together. Broadcast audio trails its video by a second or two in the multiplex, so after the
//  video jumps, audio from the old timeline keeps arriving for a while. That audio is dropped until its own jump
//  arrives (or `lagLimit` passes), so the new clock never starts on a mix of the two timelines.
//

import Foundation

nonisolated struct TimelineGuard {
    enum Verdict: Equatable {
        /// On the current timeline.
        case accept
        /// Still on the old timeline after another stream jumped; drop it.
        case drop
        /// This stream jumped first: start a new timeline, then accept this packet as its first.
        case restart
        /// This stream caught up with a new timeline (its framer should start clean).
        case rejoin
    }

    /// A step back larger than this is a jump. Reordered B pictures step back by a few frames, never this much.
    static let backwardLimit: Int64 = 90_000
    /// A step forward larger than this is a jump. A shorter gap (lost signal) just plays out as a short freeze.
    static let forwardLimit: Int64 = 3 * 90_000
    /// A stream still on the old timeline this long after another jumped is taken as it is.
    static let lagLimit: Int64 = 4 * 90_000

    private struct Track {
        var last: Int64
        var timeline: Int
        /// While lagging: the first timestamp seen on the old timeline after the other stream jumped.
        var lagStart: Int64?
    }

    private var tracks: [UInt16: Track] = [:]
    private var timeline = 0

    /// Checks one PES of a played stream. Packets without a timestamp follow their stream's state.
    mutating func admit(pid: UInt16, pts: Int64?) -> Verdict {
        guard var track = tracks[pid] else {
            if let pts { tracks[pid] = Track(last: pts, timeline: timeline) }
            return .accept
        }
        defer { tracks[pid] = track }
        guard let pts else { return track.timeline == timeline ? .accept : .drop }
        let jumped = pts < track.last - Self.backwardLimit || pts > track.last + Self.forwardLimit
        track.last = pts
        if track.timeline == timeline {
            guard jumped else { return .accept }
            timeline += 1
            track.timeline = timeline
            return .restart
        }
        if jumped {
            track.timeline = timeline
            track.lagStart = nil
            return .rejoin
        }
        let lagStart = track.lagStart ?? pts
        track.lagStart = lagStart
        guard pts - lagStart > Self.lagLimit else { return .drop }
        track.timeline = timeline
        track.lagStart = nil
        return .rejoin
    }

    /// Forgets every stream, e.g. after a seek.
    mutating func reset() {
        self = TimelineGuard()
    }
}
