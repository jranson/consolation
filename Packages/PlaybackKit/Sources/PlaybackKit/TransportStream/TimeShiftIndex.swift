//
//  TimeShiftIndex.swift
//  PlaybackKit
//
//  Maps time to byte offsets in the time-shift ring, so a seek lands where it was asked to rather than where an
//  average byte rate guesses. The ingest scans every chunk it appends (PESStartScanner: packet headers only) and the
//  index keeps a sparse list of where video PES packets start, with their PTS: every random-access point (at most
//  five a second) and otherwise one a second. Points are dropped as the ring overwrites their data, so memory stays
//  small (a 2 GiB ring of a 19.4 Mbps channel holds about 14 minutes, a few thousand points).
//
//  The index has its own clock, in seconds from the first picture it saw. A live stream's clock follows the PTS from
//  picture to picture and steps over timestamp jumps (a broadcaster's splice), so it never runs backwards or leaps
//  hours; a file's clock is its PTS less the first picture's, which stays right when a seek reopens the file
//  elsewhere (`reset(to:generation:)`).
//

import Foundation
import MPEGTS

/// One point of the index: where a video PES starts, and when it plays.
nonisolated struct TimeShiftPoint: Equatable, Sendable {
    var offset: Int64
    /// The PES's PTS as the index unwrapped it (it can differ from the demuxer's by a multiple of 2^33).
    var pts: Int64
    /// Seconds on the index's clock.
    var time: Double
    var isRandomAccess: Bool
}

nonisolated final class TimeShiftIndex: @unchecked Sendable {
    // @unchecked: every mutable property is only touched under `lock` (the ingest task writes, the pipeline queue
    // reads).

    /// Keep a random-access point when at least this long after the last point kept, and any other picture after
    /// `plainSpacing`.
    static let keyframeSpacing = 0.2
    static let plainSpacing = 1.0
    /// A hard cap on points, oldest dropped first (about eight hours at three a second).
    static let maxPoints = 100_000
    /// Steps from one picture to the next outside these are timestamp jumps (as in `TimelineGuard`).
    static let backwardLimit: Int64 = 90_000
    static let forwardLimit: Int64 = 3 * 90_000
    /// The time a jump counts for on a live clock: about one picture.
    static let jumpStep = 1.0 / 30
    /// How far back from a target a seek looks for a random-access point before settling for any point.
    static let randomAccessSearch = 64

    private let lock = NSLock()
    private var scanner = PESStartScanner()
    private var points: [TimeShiftPoint] = []
    /// `points[firstIndex...]` are current; older ones are removed in batches.
    private var firstIndex = 0
    /// Everything before this offset has been scanned.
    private var scannedHead: Int64 = 0
    private var generation = 0
    private var usesFileClock = false
    private var lastPTS: Int64?
    private var lastTime = 0.0
    private var newestTime: Double?
    private var originPTS: Int64?
    private var originConfirmed = false
    private var endTime: Double?

    /// Files: time is the PTS less the first picture's (set before the first chunk is scanned).
    func useFileClock() {
        lock.withLock { usesFileClock = true }
    }

    /// Watches the program's video. Data that arrived before the PMT was read is scanned from the ring now.
    func selectVideo(pid: UInt16, kind: StreamKind?, ring: any ByteRing) {
        lock.withLock {
            guard pid != scanner.pid || kind != scanner.kind else { return }
            scanner.select(pid: pid, kind: kind)
            scanner.resetPosition()
            var offset = max(ring.oldestOffset, scannedHead)
            let head = ring.writeHead
            while offset < head {
                let data = ring.read(from: offset, maxLength: 1 << 20)
                guard !data.isEmpty else { break }
                add(scanner.scan(data, at: offset))
                offset += Int64(data.count)
            }
            scannedHead = max(scannedHead, offset)
            prune(below: ring.oldestOffset)
        }
    }

    /// Scans a chunk the ingest just appended at `offset`; `oldest` is the ring's oldest offset after it.
    func ingest(_ data: Data, at offset: Int64, oldest: Int64, generation: Int) {
        lock.withLock {
            guard generation == self.generation, scanner.pid != nil else { return }
            let end = offset + Int64(data.count)
            guard end > scannedHead else { return }
            let skip = Int(max(0, scannedHead - offset))
            let piece = skip == 0 ? data : data.subdata(in: (data.startIndex + skip)..<data.endIndex)
            add(scanner.scan(piece, at: offset + Int64(skip)))
            scannedHead = end
            prune(below: oldest)
        }
    }

    /// A finite source was reopened at `offset` (ingest `generation`): forget the points, keep the file's clock.
    func reset(to offset: Int64, generation: Int) {
        lock.withLock {
            self.generation = generation
            points.removeAll(keepingCapacity: true)
            firstIndex = 0
            scannedHead = offset
            scanner.resetPosition()
            newestTime = nil
        }
    }

    /// The file's first picture, which the reader saw: the file clock's zero. The index may have started scanning
    /// later (when the reader takes in more than the ring holds before the PMT is read), so its times move to match.
    func confirmFileOrigin(pts: Int64) {
        lock.withLock {
            guard usesFileClock, !originConfirmed else { return }
            originConfirmed = true
            guard let provisional = originPTS else {
                originPTS = pts
                return
            }
            let shift = Double(Timestamp33.ticks(from: pts, to: provisional)) / 90_000
            originPTS = Timestamp33.unwrap(pts, near: provisional)
            guard shift != 0 else { return }
            for index in points.indices { points[index].time += shift }
            newestTime = newestTime.map { $0 + shift }
            endTime = endTime.map { $0 + shift }
        }
    }

    /// A finite source delivered its last byte: its duration is now known.
    func markEnd() {
        lock.withLock { endTime = newestTime }
    }

    // MARK: Queries

    /// The time of the last picture of a finite source, once its end was read.
    var duration: Double? {
        lock.withLock { endTime }
    }

    /// The times that can be reached: from the first random-access point at or after `oldest` (or the first point,
    /// if none is near) to the newest picture scanned.
    func window(from oldest: Int64) -> ClosedRange<Double>? {
        lock.withLock {
            let lower = firstPoint(atOrAfter: oldest)
            guard lower < points.count, let newestTime else { return nil }
            let start = firstRandomAccess(from: lower) ?? lower
            return points[start].time...max(points[start].time, newestTime)
        }
    }

    /// Where to start reading to show `time`: the last random-access point at or before it, else the first one
    /// after it (at the start of the window), else the last point before it; never before `oldest`.
    func seekPoint(for time: Double, from oldest: Int64) -> TimeShiftPoint? {
        lock.withLock {
            let lower = firstPoint(atOrAfter: oldest)
            guard lower < points.count else { return nil }
            var low = lower
            var high = points.count
            while low < high {
                let middle = (low + high) / 2
                if points[middle].time <= time { low = middle + 1 } else { high = middle }
            }
            let candidate = max(lower, low - 1)
            var index = candidate
            while index >= lower, candidate - index < Self.randomAccessSearch {
                if points[index].isRandomAccess { return points[index] }
                index -= 1
            }
            return firstRandomAccess(from: candidate).map { points[$0] } ?? points[candidate]
        }
    }

    /// The newest random-access point at or before `limit` (where "Go to Live" starts reading).
    func newestRandomAccess(before limit: Int64, from oldest: Int64) -> TimeShiftPoint? {
        lock.withLock {
            let lower = firstPoint(atOrAfter: oldest)
            var index = points.count - 1
            while index >= lower, points.count - 1 - index < Self.randomAccessSearch {
                if points[index].isRandomAccess, points[index].offset <= limit { return points[index] }
                index -= 1
            }
            return nil
        }
    }

    /// The clock time of a picture the reader found near `offset`, from a nearby point on the same timeline.
    func time(ofPTS pts: Int64, near offset: Int64) -> Double? {
        lock.withLock {
            guard firstIndex < points.count else { return nil }
            let pivot = firstPoint(atOrAfter: offset + 1) - 1
            let range = max(firstIndex, pivot - 16)...min(points.count - 1, max(firstIndex, pivot) + 4)
            var best: (ticks: Int64, time: Double)?
            for index in range {
                let ticks = Timestamp33.ticks(from: points[index].pts, to: pts)
                guard abs(ticks) <= 10 * 90_000, abs(ticks) < abs(best?.ticks ?? .max) else { continue }
                best = (ticks, points[index].time + Double(ticks) / 90_000)
            }
            return best?.time
        }
    }

    /// The average byte rate over the points held, once they span a couple of seconds.
    var bytesPerSecond: Double? {
        lock.withLock {
            guard let first = points[safe: firstIndex], let last = points.last, last.time - first.time >= 2 else {
                return nil
            }
            return Double(last.offset - first.offset) / (last.time - first.time)
        }
    }

    /// The first point held (after a reopen, the first of the new region).
    var firstPoint: TimeShiftPoint? {
        lock.withLock { points[safe: firstIndex] }
    }

    /// The newest picture's time.
    var newest: Double? {
        lock.withLock { newestTime }
    }

    // MARK: Building

    private func add(_ starts: [PESStart]) {
        for start in starts {
            guard let pts = start.pts else { continue }
            let time = clockTime(of: pts)
            newestTime = max(newestTime ?? time, time)
            let spacing = start.isRandomAccess ? Self.keyframeSpacing : Self.plainSpacing
            if let last = points.last, points.count > firstIndex, time - last.time < spacing { continue }
            points.append(TimeShiftPoint(offset: start.offset, pts: pts, time: time,
                                         isRandomAccess: start.isRandomAccess))
        }
    }

    private func clockTime(of pts: Int64) -> Double {
        if usesFileClock {
            let origin = originPTS ?? pts
            originPTS = origin
            return max(0, Double(Timestamp33.ticks(from: origin, to: pts)) / 90_000)
        }
        defer { lastPTS = pts }
        guard let lastPTS else { return lastTime }
        let step = pts - lastPTS
        if step < -Self.backwardLimit || step > Self.forwardLimit {
            lastTime += Self.jumpStep
        } else {
            lastTime += Double(step) / 90_000
        }
        return lastTime
    }

    private func prune(below oldest: Int64) {
        while firstIndex < points.count, points[firstIndex].offset < oldest { firstIndex += 1 }
        if points.count - firstIndex > Self.maxPoints { firstIndex = points.count - Self.maxPoints }
        if firstIndex >= 4_096, firstIndex * 2 >= points.count {
            points.removeFirst(firstIndex)
            firstIndex = 0
        }
    }

    /// The first random-access point from `index` on, within `randomAccessSearch` points.
    private func firstRandomAccess(from index: Int) -> Int? {
        let end = min(points.count, index + Self.randomAccessSearch)
        return (index..<end).first { points[$0].isRandomAccess }
    }

    /// The index of the first current point at or after `offset` (`points.count` if none).
    private func firstPoint(atOrAfter offset: Int64) -> Int {
        var low = firstIndex
        var high = points.count
        while low < high {
            let middle = (low + high) / 2
            if points[middle].offset < offset { low = middle + 1 } else { high = middle }
        }
        return low
    }
}

private extension Array {
    nonisolated subscript(safe index: Int) -> Element? {
        indices.contains(index) ? self[index] : nil
    }
}
