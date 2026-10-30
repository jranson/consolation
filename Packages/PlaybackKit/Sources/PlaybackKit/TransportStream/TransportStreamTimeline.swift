//
//  TransportStreamTimeline.swift
//  PlaybackKit
//
//  What a transport stream pipeline publishes for `PlaybackEngine.timeline()`, and its seek state. The pipeline
//  publishes a snapshot whenever it wakes (a few times a second, more while playing) and after every seek; the
//  engine reads it on the main actor without waiting for the pipeline's queue and moves the position on by the
//  time since, while playing.
//

import Foundation

/// The timeline as the pipeline last saw it, on the index's clock (`TimeShiftIndex`).
nonisolated struct TimeShiftSnapshot: Equatable, Sendable {
    var range: ClosedRange<Double>
    var position: Double
    /// The clock is running, so the position moves on in real time.
    var isPlaying: Bool
    var isLive: Bool
    /// When it was taken (`DispatchTime` uptime nanoseconds).
    var sampledAt: UInt64

    /// The position never moves on by more than this from one snapshot (a pipeline that stopped waking).
    static let maxExtrapolation = 1.0

    func timeline(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> PlaybackTimeline {
        var position = self.position
        if isPlaying, now > sampledAt {
            position += min(Double(now - sampledAt) / 1e9, Self.maxExtrapolation)
        }
        return PlaybackTimeline(range: range, position: position, isLive: isLive)
    }
}

/// The pipeline's latest snapshot, shared with the engine.
nonisolated final class TimelineBox: @unchecked Sendable {
    // @unchecked: both properties are only touched under `lock`.
    private let lock = NSLock()
    private var latest: TimeShiftSnapshot?
    private var requested: Double?

    var snapshot: TimeShiftSnapshot? {
        get { lock.withLock { latest } }
        set { lock.withLock { latest = newValue } }
    }

    /// A seek the engine asked for that the pipeline hasn't carried out yet: reported as the position meanwhile,
    /// so a scrubber doesn't spring back.
    var pendingSeek: Double? {
        get { lock.withLock { requested } }
        set { lock.withLock { requested = newValue } }
    }

    /// The timeline now, nil before the stream has a reachable range.
    func timeline(now: UInt64 = DispatchTime.now().uptimeNanoseconds) -> PlaybackTimeline? {
        lock.withLock {
            guard var snapshot = latest else { return nil }
            if let requested {
                snapshot.position = requested
                snapshot.isPlaying = false
            }
            return snapshot.timeline(now: now)
        }
    }
}

/// Where playback is on the time-shift timeline; on the pipeline's queue.
nonisolated struct SeekState {
    /// Maps the reader's PTS (the demuxer's) to the index's clock, for the current presentation timeline.
    var anchor: (pts: Int64, time: Double)?
    /// A seek's target as the index's PTS, until the first video PES read after the seek gives the reader's.
    var target: (indexPTS: Int64, time: Double)?
    /// Video and audio before this PTS (the reader's) are never shown: reading starts at the random-access point
    /// before a seek's target, and the pictures up to the target are only decoded as references.
    var presentFrom: Int64?
    /// The position reported until the clock reaches it: a seek's target.
    var heldPosition: Double?
    /// The last position the clock gave.
    var lastPosition: Double?
    /// Paused: the reader runs on until the picture at the new point is on screen.
    var previewing = false
    /// A finite source reopened at an estimated offset for a seek to `target`: the reader waits until the new data
    /// shows how close the estimate came.
    var region: (target: Double, attempts: Int)?
    /// The reader has seen a finite stream's first picture (or read from elsewhere), which sets the file clock.
    var originNoted = false
    /// Facts about a finite stream that outlive a reopen (which empties the index).
    var fileDuration: Double?
    var bytesPerSecond: Double?
    /// A finite stream's length from its last picture's PTS, read from its tail once (TransportStreamPipelineDuration).
    var probedDuration: Double?
    var durationProbed = false

    /// A new presentation timeline (after a seek, or a jump in the timestamps): the next picture anchors it.
    mutating func restartTimeline() {
        anchor = nil
        target = nil
        presentFrom = nil
    }
}
