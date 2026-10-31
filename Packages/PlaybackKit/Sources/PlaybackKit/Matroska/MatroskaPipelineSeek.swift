//
//  MatroskaPipelineSeek.swift
//  PlaybackKit
//
//  Seeking and the timeline. The timeline runs from the first picture (zero) to the Segment's duration. A seek reads
//  from the Cluster the Cues give for the target (from the ring when it still holds it, else by reopening the
//  source there) and decodes up to the target without showing anything earlier, as the transport stream pipeline
//  does. Without Cues it reopens at the offset the target's share of the file suggests and the demuxer searches for
//  the next Cluster. Cues written after the Clusters are read once, on their own connection, where the SeekHead says;
//  a file whose Info has no duration has its last Cluster read the same way.
//

import CoreMedia
import Foundation
import Matroska
import os

/// Where playback is on the timeline; on the pipeline's queue.
nonisolated struct MatroskaSeekState {
    /// The first picture's PTS (90 kHz): zero on the timeline.
    var originTicks: Int64?
    /// Video and audio before this PTS are never shown: reading starts at the keyframe before a seek's target.
    var presentFrom: Int64?
    /// The position reported until the clock reaches it: a seek's target.
    var heldPosition: Double?
    /// The last position the clock gave.
    var lastPosition: Double?
    /// Paused: the reader runs on until the picture at the new point is on screen.
    var previewing = false
    /// The length in seconds: the Segment's Info, else the last Cluster's time.
    var duration: Double?
    var probedDuration = false
}

nonisolated extension MatroskaPipeline {
    /// Seeks without Cues land this far before the target, so a keyframe likely comes before it.
    static let estimateLead = 0.03
    /// The end of a file without a duration: how much of it is read for the last Cluster's time.
    static let tailProbeBytes: Int64 = 8 << 20

    /// The reachable range, once the length is known.
    var timelineWindow: ClosedRange<Double>? {
        seek.duration.map { 0...max($0, 0) }
    }

    // MARK: Requests

    /// Moves playback to `time` seconds, clamped to the range. Keeps the pause: a paused stream shows the picture
    /// at the new point.
    func seek(toTime time: Double) {
        queue.async { [self] in
            defer {
                published.pendingSeek = nil
                publishTimeline()
            }
            guard !stopped, sourceOpened, let window = timelineWindow else { return }
            seek(to: min(max(time, window.lowerBound), window.upperBound))
        }
    }

    /// Moves playback by `seconds` (negative goes back).
    func skip(seconds: Double) {
        queue.async { [self] in
            guard !stopped, let window = timelineWindow, let position = currentPosition() else { return }
            seek(to: min(max(position + seconds, window.lowerBound), window.upperBound))
            publishTimeline()
        }
    }

    private func seek(to target: Double) {
        guard let segment, let feed, let origin = seek.originTicks else { return }
        let targetTicks = origin + Int64((target * 90_000).rounded())
        let landing: (offset: Int64, atCluster: Bool)
        if let point = cues?.point(atOrBefore: segment.timestamp(ticks: targetTicks), track: feed.video.number) {
            landing = (point.clusterOffset, true)
        } else if let estimate = estimatedOffset(for: target, in: segment) {
            landing = (estimate, false)
        } else {
            return
        }
        Self.log.info("Seek to \(target, format: .fixed(precision: 1)) s at byte \(landing.offset)")
        move(to: landing.offset, atCluster: landing.atCluster)
        seek.presentFrom = targetTicks
        seek.heldPosition = target
        seek.previewing = paused
        wakeSoon()
        pump()
    }

    /// Where the target's share of the file is, a little early.
    private func estimatedOffset(for target: Double, in segment: MatroskaSegment) -> Int64? {
        guard let duration = seek.duration, duration > 0,
              let end = segment.endOffset ?? contentLength else { return nil }
        let start = segment.firstClusterOffset
        let share = max(0, target / duration - Self.estimateLead)
        return start + Int64(Double(max(end - start, 0)) * min(share, 1))
    }

    /// Restarts reading at `offset`: from the ring when it holds it, else from the source reopened there.
    private func move(to offset: Int64, atCluster: Bool) {
        restartTimeline()
        ending.rewind()
        seek.heldPosition = nil
        demuxer.restart(at: offset, atElement: atCluster)
        if offset >= ring.oldestOffset, offset < ring.writeHead {
            readOffset = offset
        } else if canReopen {
            reopen(at: offset)
        } else {
            // Not reopenable: carry on from what the ring has, searching for a Cluster.
            readOffset = max(ring.oldestOffset, min(offset, ring.writeHead))
            demuxer.restart(at: readOffset, atElement: false)
        }
    }

    // MARK: Presentation

    /// The first picture sets the timeline's zero, and with it the length when the Info has none.
    func noteVideoTimestamp(_ pts: Int64) {
        guard seek.originTicks == nil else { return }
        seek.originTicks = pts
        if seek.duration == nil { probeDuration() }
    }

    /// Audio before a seek's target is dropped.
    func isPresentable(audio sample: CMSampleBuffer) -> Bool {
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

    /// The position on screen: a seek's target until the clock gets there, then the clock.
    func currentPosition() -> Double? {
        var mapped: Double?
        if let origin = seek.originTicks, let ticks = renderer.clockTicks {
            mapped = Double(ticks - origin) / 90_000
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
        guard let range = timelineWindow else { return }
        let position = currentPosition() ?? range.lowerBound
        let playing = !paused && seek.heldPosition == nil && renderer.clockTicks != nil && renderer.rate > 0
        published.snapshot = TimeShiftSnapshot(range: range, position: position, isPlaying: playing, isLive: false,
                                               sampledAt: DispatchTime.now().uptimeNanoseconds)
    }

    // MARK: Probes

    /// Cues met in the stream; a lower bound for a length the Info didn't give.
    func noteCues(_ found: MatroskaCues) {
        guard cues == nil, !found.isEmpty else { return }
        cues = found
        Self.log.info("Cues: \(found.points.count) points")
        if seek.duration == nil, let segment, let origin = seek.originTicks, let last = found.lastTime {
            let seconds = Double(segment.ticks(last) - origin) / 90_000
            if seconds > 0 { seek.duration = seconds }
        }
    }

    /// Reads the Cues where the SeekHead points, on their own connection, when they come after the Clusters.
    func probeCuesIfNeeded() {
        guard canReopen, cues == nil, let segment, let offset = segment.cuesOffset,
              let reader = source.reopened(at: offset) else { return }
        probeTask = Task { [weak self] in
            let found = await Self.readCues(from: reader, segment: segment, at: offset)
            guard let found, let self else { return }
            queue.async {
                guard !self.stopped else { return }
                self.noteCues(found)
                self.publishTimeline()
            }
        }
    }

    /// The length of a file whose Info has none, from the latest block near its end.
    private func probeDuration() {
        guard canReopen, !seek.probedDuration, let segment, let video = feed?.video.number,
              let origin = seek.originTicks, let end = segment.endOffset ?? contentLength else { return }
        seek.probedDuration = true
        let start = max(segment.firstClusterOffset, end - Self.tailProbeBytes)
        guard let reader = source.reopened(at: start) else { return }
        let previous = probeTask
        probeTask = Task { [weak self] in
            await previous?.value
            guard let last = await Self.latestTimestamp(from: reader, segment: segment, at: start, track: video),
                  let self else { return }
            let seconds = Double(segment.ticks(last) - origin) / 90_000
            queue.async {
                guard !self.stopped, seconds > (self.seek.duration ?? 0) else { return }
                Self.log.info("Length from the last Cluster: \(seconds, format: .fixed(precision: 1)) s")
                self.seek.duration = seconds
                self.publishTimeline()
            }
        }
    }

    @concurrent
    static func readCues(from source: any ByteSource, segment: MatroskaSegment, at offset: Int64) async
        -> MatroskaCues? {
        defer { source.cancel() }
        var demuxer = MatroskaDemuxer(continuing: segment, at: offset, atElement: true)
        var found: MatroskaCues?
        var read: Int64 = 0
        do {
            for try await chunk in try await source.open() {
                chunk.withUnsafeBytes { raw in
                    demuxer.feed(raw) { event in
                        if case .cues(let cues) = event { found = cues }
                    }
                }
                read += Int64(chunk.count)
                if found != nil || demuxer.failure != nil || read > Int64(MatroskaDemuxer.maximumCuesSize) + 4_096
                    || Task.isCancelled { break }
            }
        } catch {
            // Whatever was read before the connection dropped is all there is.
        }
        return found
    }

    @concurrent
    static func latestTimestamp(from source: any ByteSource, segment: MatroskaSegment, at offset: Int64,
                                track: UInt64) async -> Int64? {
        defer { source.cancel() }
        var demuxer = MatroskaDemuxer(continuing: segment, at: offset, atElement: false)
        var latest: Int64?
        var read: Int64 = 0
        do {
            for try await chunk in try await source.open() {
                chunk.withUnsafeBytes { raw in
                    demuxer.feed(raw) { event in
                        guard case .block(let block, _) = event, block.track == track else { return }
                        let end = block.timestamp + (block.duration ?? 0)
                        latest = max(latest ?? end, end)
                    }
                }
                read += Int64(chunk.count)
                if read >= tailProbeBytes || demuxer.failure != nil || Task.isCancelled { break }
            }
        } catch {
            // As for the Cues.
        }
        return latest
    }
}
