//
//  TransportStreamPipelineDuration.swift
//  PlaybackKit
//
//  A finite transport stream's real length. A TS file has no duration field, and estimating one from the byte rate
//  misses by minutes on a variable-bit-rate broadcast. So once the first picture fixes the file clock's zero, the
//  last few megabytes are read once, on their own connection (`ByteSource.reopened(at:)`, a range request for HTTP),
//  and the last video PTS there gives the length on that clock. Playback never waits for it: until it lands the
//  timeline uses the estimate, and a stream that can't be reopened keeps it until its end is read.
//

import Foundation
import MPEGTS
import os

nonisolated extension TransportStreamPipeline {
    /// How much of the end the probe reads: a couple of seconds even at ATSC's 19.4 Mbps, so several pictures.
    static let durationProbeBytes: Int64 = 4 << 20

    /// Starts the probe for a reopenable finite stream whose first picture has `firstPTS` (on `queue`, once).
    func probeDuration(firstPTS: Int64) {
        guard isFiniteSource, canReopen, !seek.durationProbed, let length = contentLength,
              let video = currentProgram.flatMap(TrackSelection.video(in:)) else { return }
        seek.durationProbed = true
        let start = max(0, length - Self.durationProbeBytes)
        guard let tail = source.reopened(at: start) else { return }
        let pid = video.pid
        let kind = video.kind
        durationProbe = Task { [weak self] in
            guard let last = await Self.lastVideoPTS(in: tail, from: start, pid: pid, kind: kind) else { return }
            let seconds = Double(Timestamp33.ticks(from: firstPTS, to: last)) / 90_000
            guard seconds > 0, let self else { return }
            queue.async {
                guard !self.stopped else { return }
                Self.log.info("Stream length from its last picture: \(seconds, format: .fixed(precision: 1)) s")
                self.seek.probedDuration = seconds
                self.publishTimeline()
            }
        }
    }

    /// The latest PTS of `pid`'s pictures in what `source` delivers from `offset` (at most `durationProbeBytes`),
    /// or nil when there is none. Pictures arrive in decode order, so the latest is the largest, not the last.
    @concurrent
    static func lastVideoPTS(in source: any ByteSource, from offset: Int64, pid: UInt16,
                             kind: StreamKind?) async -> Int64? {
        defer { source.cancel() }
        var scanner = PESStartScanner()
        scanner.select(pid: pid, kind: kind)
        var position = offset
        var latest: Int64?
        do {
            for try await chunk in try await source.open() {
                for start in scanner.scan(chunk, at: position) {
                    guard let pts = start.pts else { continue }
                    latest = max(latest ?? pts, pts)
                }
                position += Int64(chunk.count)
                if Task.isCancelled || position - offset >= durationProbeBytes { break }
            }
        } catch {
            // A connection that drops mid-read still gave what it read.
        }
        return latest
    }
}
