//
//  MatroskaPipelineIngest.swift
//  PlaybackKit
//
//  The ingest and the end of the stream. The source's chunks go into the read-ahead ring, which never overwrites
//  what the reader hasn't read: the ingest waits (and asks the source to hold back) while the ring is full. A seek
//  beyond the ring reopens the source at the new offset in a new ingest generation, and a connection that drops is
//  reopened where its data stopped, a few times, before playback fails. At the end, the framers and the decoder are
//  flushed and the clock runs out what is queued before `.finished` is sent.
//

import AVFoundation
import Foundation
import os

nonisolated extension MatroskaPipeline {
    /// Reopens after a dropped connection at most this many times in a row (data arriving resets the count).
    static let maximumIngestRetries = 3
    static let ingestRetryDelay = Duration.seconds(1)

    /// Opens `source` and copies its chunks into the ring until it ends. Generation 0 is the first connection; it
    /// tells the pipeline what the source is.
    func ingest(from source: any ByteSource, generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                let chunks = try await source.open()
                if generation == 0 {
                    let finite = source.isFinite
                    let length = source.contentLength
                    let reopenable = finite && length != nil && source.reopened(at: 0) != nil
                    queue.async {
                        self.contentLength = length
                        self.canReopen = reopenable
                        self.sourceOpened = true
                        self.pump()
                    }
                }
                for try await chunk in chunks {
                    if Task.isCancelled { break }
                    try await waitForRoom(for: chunk.count, source: source)
                    guard progress.append(chunk, to: ring, generation: generation) != nil else { return }
                    let count = Int64(chunk.count)
                    queue.async {
                        self.bytesIngested += count
                        self.ingestRetries = 0
                        self.pump()
                    }
                }
                queue.async { self.finishIngest(error: nil, generation: generation) }
            } catch {
                queue.async { self.finishIngest(error: error, generation: generation) }
            }
        }
    }

    /// Waits until appending `count` bytes won't overwrite data the reader hasn't read. A chunk larger than the
    /// whole ring waits only for the reader to catch up completely.
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

    /// Reopens the source at `offset` (on `queue`): the ring starts again there, and the reader with it.
    func reopen(at offset: Int64) {
        guard let reopened = source.reopened(at: offset) else { return }
        Self.log.info("Reopening the stream at byte \(offset)")
        ingestTask?.cancel()
        activeSource.cancel()
        activeSource = reopened
        ingestGeneration = progress.restart(ring, at: offset)
        readOffset = offset
        ending = EndOfStream()
        ingestTask = ingest(from: reopened, generation: ingestGeneration)
    }

    /// The source finished: played out (`advanceEnd`) after a clean end, reopened where it stopped after a dropped
    /// connection, or failed.
    func finishIngest(error: (any Error)?, generation: Int) {
        guard !stopped, generation == ingestGeneration else { return }
        guard let error else {
            Self.log.info("Ingest ended at byte \(self.ring.writeHead)")
            ending.ingestEnded = true
            pump()
            wakeSoon()
            return
        }
        guard !(error is CancellationError) else { return }
        let reachedEnd = contentLength.map { ring.writeHead >= $0 } ?? false
        if canReopen, !reachedEnd, ingestRetries < Self.maximumIngestRetries {
            ingestRetries += 1
            Self.log.notice("Connection dropped (\(String(describing: error), privacy: .public)); resuming")
            resumeIngest()
            return
        }
        Self.log.error("Ingest failed: \(String(describing: error), privacy: .public)")
        pump()
        fail(TransportStreamPipeline.playbackError(from: error))
    }

    /// Reopens the source where the ring's data stops, after a moment, keeping what the ring holds.
    private func resumeIngest() {
        let generation = progress.resume()
        ingestGeneration = generation
        let offset = ring.writeHead
        ingestTask = Task { [weak self] in
            try? await Task.sleep(for: Self.ingestRetryDelay)
            guard !Task.isCancelled, let self else { return }
            queue.async {
                guard !self.stopped, generation == self.ingestGeneration,
                      let reopened = self.source.reopened(at: offset) else { return }
                self.activeSource.cancel()
                self.activeSource = reopened
                self.ingestTask = self.ingest(from: reopened, generation: generation)
            }
        }
    }

    /// Moves the stream towards its end; called from the pump once the ingest has ended.
    func advanceEnd() {
        guard !ending.finished, !paused, !stopped else { return }
        if !ending.inputDrained {
            guard readOffset >= ring.writeHead else { return }
            ending.inputDrained = true
            if var current = feed.take() {
                let pictures = current.flushVideo()
                let audio = current.flushAudio()
                feed = current
                for picture in pictures { noteVideoTimestamp(picture.info.pts) }
                pendingPictures.append(contentsOf: pictures)
                if let audio, isPresentable(audio: audio) { renderer.enqueueAudio(audio) }
            }
            announceIfNeeded()
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
        Self.log.info("Played to the end")
        onEvent(.finished)
    }

    /// Tells the engine what the stream is, at its first picture.
    func announceIfNeeded() {
        guard !announced, let video = feed?.processor.videoFacts else { return }
        announced = true
        Self.log.info("First picture: \(video.codec, privacy: .public) \(video.width)x\(video.height)")
        var info = PlaybackStreamInfo(
            videoCodec: video.codec, width: video.width, height: video.height, frameRate: video.frameRate,
            isInterlaced: video.isInterlaced, isLive: false, unsupportedAudioCodec: unsupportedAudioCodec)
        applyAudioFacts(to: &info)
        announcedInfo = info
        onEvent(.started(info))
    }

    /// Sends `.info` when the audio facts announced have changed since (the channel count arrived, or another
    /// track plays).
    func refreshAudioFacts() {
        guard var info = announcedInfo else { return }
        let before = info
        applyAudioFacts(to: &info)
        info.unsupportedAudioCodec = unsupportedAudioCodec
        guard info != before else { return }
        announcedInfo = info
        onEvent(.info(info))
    }

    private func applyAudioFacts(to info: inout PlaybackStreamInfo) {
        info.audioCodec = feed?.audioName
        info.audioChannels = feed?.audioChannels
        info.audioLanguage = feed?.audio.flatMap(MatroskaTrackSelection.displayLanguage)
    }
}
