//
//  TransportStreamPipelineSeek.swift
//  PlaybackKit
//
//  Seeking within the time-shift buffer. A seek reads from the random-access point the index has at or before the
//  target and decodes up to the target without showing anything earlier, so playback resumes within a picture of it.
//  "Go to Live" reads from the newest random-access point. A finite stream that can be reopened (a file, an HTTP
//  response with a length) is reopened near the target when the ring doesn't hold it: at an offset estimated from the
//  byte rate, then once more closer if the estimate missed.
//

import CoreMedia
import Foundation
import MPEGTS

nonisolated extension TransportStreamPipeline {
    /// A live stream's range ends this far before the newest picture received: about where playback runs at the
    /// live edge (the clock waits for a second of audio, and broadcast audio trails its video in the multiplex).
    static let liveEdgeAllowance = 2.0
    /// Seeks within this of the live edge go to live.
    static let liveSnap = 1.0
    /// A reopened finite stream starts this long before the target (at most a third of what the ring holds), so a
    /// random-access point precedes it.
    static let reopenLead = 3.0
    /// Reopens one seek may take, and how far short of a target new data may stop before reopening nearer (closer
    /// than that, the reader decodes its way there).
    static let reopenAttempts = 3
    static let reopenReach = 10.0

    var isReading: Bool { !paused || seek.previewing }

    /// Where a seek may land: never in the bytes the ring overwrites next once it is full.
    var seekFloor: Int64 {
        let oldest = ring.oldestOffset
        guard ring.writeHead - oldest >= Int64(ring.capacity) else { return oldest }
        return oldest + Int64(min(ring.capacity / 32, 8 << 20))
    }

    /// The reachable range on the index's clock: a live stream's buffered window up to its live edge, a finite
    /// stream's whole length when it can be reopened (else what the ring holds).
    var timelineWindow: ClosedRange<Double>? {
        let window = index.window(from: seekFloor)
        guard isFiniteSource else {
            guard let window else { return nil }
            return window.lowerBound...max(window.lowerBound, window.upperBound - Self.liveEdgeAllowance)
        }
        guard canReopen else { return window }
        guard let duration = seek.fileDuration else { return nil }
        return 0...max(duration, window?.upperBound ?? 0)
    }

    // MARK: Requests

    /// Moves playback to `time` on the index's clock, clamped to the range. Keeps the pause: a paused stream shows
    /// the picture at the new point.
    func seek(toTime time: Double) {
        queue.async { [self] in
            defer {
                published.pendingSeek = nil
                publishTimeline()
            }
            guard !stopped, sourceOpened, let window = timelineWindow else { return }
            let target = min(max(time, window.lowerBound), window.upperBound)
            if !isFiniteSource, target >= window.upperBound - Self.liveSnap { return goLive() }
            seek(to: target, attempts: 0)
        }
    }

    /// Moves playback back to live, dropping what is buffered after the reader.
    func jumpToLive() {
        queue.async { [self] in
            guard !stopped else { return }
            goLive()
            publishTimeline()
        }
    }

    /// Moves playback by `seconds` (negative goes back) on the timeline; by the average byte rate before there is
    /// one.
    func skip(seconds: Double) {
        queue.async { [self] in
            guard !stopped else { return }
            if let window = timelineWindow, let position = currentPosition() {
                let target = min(max(position + seconds, window.lowerBound), window.upperBound)
                if !isFiniteSource, target >= window.upperBound - Self.liveSnap { goLive() } else {
                    seek(to: target, attempts: 0)
                }
                return publishTimeline()
            }
            let elapsed = max(Date().timeIntervalSince(ingestStart), 1)
            let bytesPerSecond = Double(ring.writeHead) / elapsed
            let target = readOffset + Int64(bytesPerSecond * seconds)
            reposition(to: min(max(target, ring.oldestOffset), max(ring.writeHead - Self.liveEdgeBytes, 0)))
            pump()
        }
    }

    // MARK: Moving the reader

    /// Restarts reading at `offset` (rounded to a packet unless `exact`) with a new presentation timeline.
    func reposition(to offset: Int64, exact: Bool = false) {
        readOffset = exact ? offset : offset - offset % 188
        seek.originNoted = true
        ending.rewind()
        demuxer.resynchronize()
        timelineGuard.reset()
        restartTimeline()
        seek.heldPosition = nil
        seek.region = nil
    }

    /// Seeks to `target` (within the range); a finite stream is reopened while the ring doesn't hold it.
    func seek(to target: Double, attempts: Int) {
        if isFiniteSource, canReopen, attempts < Self.reopenAttempts, !ringHolds(target) {
            return reopen(toward: target, attempts: attempts, from: index.firstPoint)
        }
        guard let point = index.seekPoint(for: target, from: seekFloor) else { return }
        reposition(to: point.offset, exact: true)
        let landing = max(target, point.time)
        seek.target = (point.pts + Int64(((landing - point.time) * 90_000).rounded()), landing)
        seek.heldPosition = landing
        seek.previewing = paused
        wakeSoon()
        pump()
    }

    /// Reads from the newest random-access point (or, before the index has one, close to the head).
    func goLive() {
        if let point = index.newestRandomAccess(before: ring.writeHead, from: seekFloor) {
            reposition(to: point.offset, exact: true)
        } else {
            reposition(to: max(ring.oldestOffset, ring.writeHead - Self.liveEdgeBytes))
        }
        seek.lastPosition = timelineWindow?.upperBound
        seek.previewing = paused
        pump()
    }

    private func ringHolds(_ target: Double) -> Bool {
        guard let held = index.window(from: ring.oldestOffset) else { return false }
        return held.contains(target) || (target > held.upperBound && ending.ingestEnded)
    }

    /// Reopens a finite stream near `target`, from the byte rate and a known point (`from`) if there is one.
    private func reopen(toward target: Double, attempts: Int, from known: TimeShiftPoint?) {
        guard let length = contentLength, let rate = seek.bytesPerSecond, rate > 0 else {
            return seek(to: target, attempts: Self.reopenAttempts)
        }
        let lead = min(Self.reopenLead, Double(ring.capacity) / rate / 3)
        let start = max(0, target - lead)
        let estimate = known.map { $0.offset + Int64((start - $0.time) * rate) } ?? Int64(start * rate)
        let offset = min(max(estimate, 0), max(length - 188 * 64, 0))
        reopen(at: offset - offset % 188)
        seek.region = (target, attempts + 1)
        seek.heldPosition = target
        seek.previewing = paused
        wakeSoon()
    }

    /// While a reopened finite stream's first data arrives, the reader waits (true). Then the seek goes on within
    /// the new data, or the stream is reopened nearer when the estimate missed.
    func awaitsRegion() -> Bool {
        guard let region = seek.region else { return false }
        guard let first = index.firstPoint, let newest = index.newest else {
            if ending.ingestEnded { seek.region = nil }
            return !ending.ingestEnded
        }
        let attemptsLeft = region.attempts < Self.reopenAttempts
        if first.time > region.target + 0.5, first.offset > 0, attemptsLeft {
            reopen(toward: region.target, attempts: region.attempts, from: first)
            return true
        }
        if newest < region.target, !ending.ingestEnded {
            if attemptsLeft, region.target - newest > Self.reopenReach {
                reopen(toward: region.target, attempts: region.attempts, from: first)
                return true
            }
            // Near enough, or the ring is full: read on from the newest point and decode up to the target.
            guard progress.isBacklogged || !attemptsLeft else { return true }
        }
        seek.region = nil
        seek(to: region.target, attempts: Self.reopenAttempts)
        return true
    }

    // MARK: Presentation

    /// Anchors a new presentation timeline at its first picture: a seek's target gives the cut-off PTS; otherwise
    /// the index gives the picture's time.
    func noteVideoTimestamp(_ pts: Int64?) {
        guard let pts else { return }
        if isFiniteSource, !seek.originNoted {
            seek.originNoted = true
            index.confirmFileOrigin(pts: pts)
            probeDuration(firstPTS: pts)
        }
        guard seek.anchor == nil else { return }
        if let target = seek.target {
            let from = Timestamp33.unwrap(target.indexPTS, near: pts)
            seek.presentFrom = from
            seek.anchor = (from, target.time)
            seek.target = nil
        } else if let time = index.time(ofPTS: pts, near: readOffset) {
            seek.anchor = (pts, time)
        }
    }

    /// Audio is held back until a seek's first picture is read, and dropped when it ends before the target.
    func isPresentable(audio sample: CMSampleBuffer) -> Bool {
        guard seek.target == nil else { return false }
        guard let from = seek.presentFrom else { return true }
        let end = CMTimeAdd(CMSampleBufferGetPresentationTimeStamp(sample), CMSampleBufferGetDuration(sample))
        return CMTimeConvertScale(end, timescale: SampleFormats.timescale, method: .default).value > from
    }

    /// Queues a decoded picture, unless it comes before a seek's target.
    func present(_ sample: CMSampleBuffer) {
        if let from = seek.presentFrom {
            let time = CMSampleBufferGetOutputPresentationTimeStamp(sample)
            guard CMTimeConvertScale(time, timescale: SampleFormats.timescale, method: .default).value >= from else {
                return
            }
        }
        renderer.enqueueVideo(sample)
    }

    // MARK: Publishing

    /// The position on screen, on the index's clock: a seek's target until the clock gets there, then the clock.
    func currentPosition() -> Double? {
        var mapped: Double?
        if let anchor = seek.anchor, let ticks = renderer.clockTicks {
            mapped = anchor.time + Double(ticks - anchor.pts) / 90_000
        }
        if let held = seek.heldPosition {
            guard let mapped, mapped >= held - 0.05 else { return held }
            seek.heldPosition = nil
        }
        if let mapped { seek.lastPosition = mapped }
        return seek.lastPosition
    }

    /// Publishes the timeline for the engine (on every wake-up and after every seek).
    func publishTimeline() {
        if isFiniteSource {
            seek.bytesPerSecond = index.bytesPerSecond ?? seek.bytesPerSecond
            if let duration = index.duration ?? seek.probedDuration {
                seek.fileDuration = duration
            } else if seek.fileDuration == nil, let length = contentLength, let rate = seek.bytesPerSecond, rate > 0,
                      seek.region == nil {
                // An estimate, taken once: re-averaging a variable bit rate would move the end, and with it the
                // position's place on the timeline, while it plays. The probe or the end replaces it.
                seek.fileDuration = Double(length) / rate
            }
        }
        guard let range = timelineWindow else { return }
        let position = currentPosition() ?? (isFiniteSource ? range.lowerBound : range.upperBound)
        let playing = !paused && seek.heldPosition == nil && renderer.clockTicks != nil && renderer.rate > 0
        published.snapshot = TimeShiftSnapshot(range: range, position: position, isPlaying: playing,
                                               isLive: !isFiniteSource,
                                               sampledAt: DispatchTime.now().uptimeNanoseconds)
    }
}
