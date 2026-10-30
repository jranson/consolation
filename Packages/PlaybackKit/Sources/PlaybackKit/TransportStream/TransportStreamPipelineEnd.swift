//
//  TransportStreamPipelineEnd.swift
//  PlaybackKit
//
//  The ends of a stream. A finite source (a file, or an HTTP response with a length) arrives faster than real time,
//  so its ingest finishes long before playback does: the ingest waits whenever the unread backlog would overwrite
//  data the reader hasn't reached (and asks the source to hold back), and when the reader has consumed everything,
//  the framers and the decoder are flushed, the clock runs out the queued pictures and audio, and only then is
//  `.finished` sent (the engine stops there; it reconnects only live sources). Also the stream announcement.
//

import AVFoundation
import Foundation
import os

/// The reader's position and whether the ingest is waiting for it, shared by the pipeline queue and the ingest task.
nonisolated final class IngestProgress: @unchecked Sendable {
    // @unchecked: every property is only touched under `lock`.
    private let lock = NSLock()
    private var offset: Int64 = 0
    private var waiting = false
    private var lastChange = Date()
    private var overrunCount = 0
    private var generation = 0

    var readOffset: Int64 {
        get { lock.withLock { offset } }
        set { lock.withLock { offset = newValue } }
    }

    /// The ingest is holding back because the ring is full of unread data.
    var isBacklogged: Bool { lock.withLock { waiting } }

    /// When the ingest last started or stopped waiting: no data arrives while it waits, which isn't a stall.
    var lastBacklogChange: Date { lock.withLock { lastChange } }

    /// Times the reader found its data already overwritten (a live pause that outlasted the ring).
    var overruns: Int { lock.withLock { overrunCount } }

    func noteOverrun() {
        lock.withLock { overrunCount += 1 }
    }

    func setBacklogged(_ backlogged: Bool) {
        lock.withLock {
            waiting = backlogged
            lastChange = Date()
        }
    }

    /// Appends a chunk of ingest `generation` and returns the offset it went to, or nil (dropped) when a reopen
    /// has started a newer ingest since.
    func append(_ chunk: Data, to ring: any ByteRing, generation: Int) -> Int64? {
        lock.withLock {
            guard generation == self.generation else { return nil }
            let offset = ring.writeHead
            ring.append(chunk)
            return offset
        }
    }

    /// Starts a new ingest generation at `offset` (a finite source reopened for a seek): the ring is emptied and
    /// continues there, and chunks still arriving from the old ingest are dropped. Returns the new generation.
    func restart(_ ring: any ByteRing, at offset: Int64) -> Int {
        lock.withLock {
            generation += 1
            ring.reset(to: offset)
            self.offset = offset
            return generation
        }
    }
}

/// How far a finite stream's end has got, on the pipeline queue.
nonisolated struct EndOfStream {
    /// The source delivered its last byte without an error.
    var ingestEnded = false
    /// The reader consumed the ring and the framers were flushed.
    var inputDrained = false
    /// The compressed pictures were all decoded and the decoder drained.
    var stageDrained = false
    var finished = false
    /// Sent `.finished` by then even if the clock seems not to reach the end (seconds of slack past the queue).
    var deadline: DispatchTime?
    static let slack = 3.0

    /// A seek moved the reader back: the end hasn't been reached any more.
    mutating func rewind() {
        inputDrained = false
        stageDrained = false
        finished = false
        deadline = nil
    }

    /// Restarts the play-out deadline from what is queued now (after the drain, or on resume from pause).
    mutating func restartDeadline(renderer: SampleRenderer) {
        guard stageDrained else { return }
        let queued = max(renderer.videoSecondsAhead, renderer.audioSecondsAhead, 0)
        deadline = .now() + queued + Self.slack
    }
}

nonisolated extension TransportStreamPipeline {
    /// Waits (finite sources only) until appending `count` bytes won't overwrite data the reader hasn't read. A
    /// chunk larger than the whole ring waits only for the reader to catch up completely.
    func waitForRoom(for count: Int, source: any ByteSource) async throws {
        var holding = false
        defer {
            if holding {
                progress.setBacklogged(false)
                source.setBacklogged(false)
            }
        }
        while true {
            let unread = ring.writeHead - progress.readOffset
            guard unread > 0, unread + Int64(count) > Int64(ring.capacity) else { return }
            if !holding {
                holding = true
                progress.setBacklogged(true)
                source.setBacklogged(true)
            }
            try await Task.sleep(for: .milliseconds(50))
        }
    }

    /// The source finished. A live source that ends is reported at once (the engine reconnects); a finite one is
    /// played out first (`advanceEnd`).
    func finishIngest(error: (any Error)?, generation: Int) {
        guard !stopped, generation == ingestGeneration else { return }
        let detail = error.map { String(describing: $0) } ?? "no error"
        Self.log.info("Ingest ended after \(self.ring.writeHead) bytes: \(detail, privacy: .public)")
        if error == nil, isFiniteSource {
            ending.ingestEnded = true
            index.markEnd()
            pump()
            wakeSoon()
            return
        }
        pump()
        if let error, !(error is CancellationError) {
            onEvent(.failed(Self.playbackError(from: error)))
        } else {
            onEvent(.ended)
        }
    }

    /// Moves a finite stream towards its end; called from the pump once the ingest has ended.
    func advanceEnd() {
        guard !ending.finished, !paused, !stopped else { return }
        if !ending.inputDrained {
            guard readOffset >= ring.writeHead else { return }
            ending.inputDrained = true
            let pictures = processor.flushVideo()
            pendingPictures.append(contentsOf: pictures)
            for picture in pictures { queueCaptions(from: picture) }
            announceIfNeeded()
            if let audio = processor.flushPendingAudio(), isPresentable(audio: audio) { renderer.enqueueAudio(audio) }
            renderer.markEndOfStream()
            decodePendingPictures()
        }
        if !ending.stageDrained {
            guard pendingPictures.isEmpty else { return }
            ending.stageDrained = true
            do {
                for sample in try videoStage.drain() { present(sample) }
            } catch {
                Self.log.error("Video drain failed: \(String(describing: error), privacy: .public)")
            }
            ending.restartDeadline(renderer: renderer)
        }
        let overdue = ending.deadline.map { DispatchTime.now() >= $0 } ?? false
        guard renderer.hasPlayedOut || overdue else { return }
        ending.finished = true
        Self.log.info("Finite stream played to its end")
        onEvent(.finished)
    }

    /// Tells the engine what the stream is, at its first picture.
    func announceIfNeeded() {
        guard !announced, let video = processor.videoFacts else { return }
        announced = true
        let codec = video.codec
        Self.log.info("First picture: \(codec, privacy: .public) \(video.width)x\(video.height), \(video.isInterlaced)")
        let audioCodec = processor.audioPID == nil ? nil : (processor.audioIsEAC3 ? "E-AC-3" : "AC-3")
        onEvent(.started(PlaybackStreamInfo(
            videoCodec: video.codec, audioCodec: audioCodec, width: video.width, height: video.height,
            frameRate: video.frameRate, isInterlaced: video.isInterlaced, audioChannels: processor.audioChannels,
            audioLanguage: processor.audioPID == nil ? nil : preferredLanguage, isLive: !isFiniteSource,
            unsupportedAudioCodec: unsupportedAudioCodec)))
    }
}
