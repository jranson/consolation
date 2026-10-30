//
//  TransportStreamPipelineIngest.swift
//  PlaybackKit
//
//  The ingest: the source's chunks go into the time-shift ring and through the time-shift index, and wake the
//  reader. A finite source that can be reopened at an offset (`ByteSource.reopened(at:)`) is reopened when a seek
//  goes beyond what the ring holds: the ring is emptied and continues at the new offset, and a new ingest
//  generation starts, so chunks still in flight from the old one are dropped.
//

import Foundation
import MPEGTS
import os

nonisolated extension TransportStreamPipeline {
    /// Opens `source` and copies its chunks into the ring until it ends. Generation 0 is the first connection; it
    /// tells the pipeline what the source is.
    func ingest(from source: any ByteSource, generation: Int) -> Task<Void, Never> {
        Task { [weak self] in
            guard let self else { return }
            do {
                let chunks = try await source.open()
                let finite = source.isFinite
                if generation == 0 {
                    let program = source.programNumber
                    let length = source.contentLength
                    let reopenable = finite && length != nil && source.reopened(at: 0) != nil
                    if finite { index.useFileClock() }
                    queue.async {
                        self.requestedProgram = program
                        self.isFiniteSource = finite
                        self.contentLength = length
                        self.canReopen = reopenable
                        self.sourceOpened = true
                    }
                }
                for try await chunk in chunks {
                    if Task.isCancelled { break }
                    // A finite source never overwrites what the reader hasn't read; a live one keeps the newest.
                    if finite { try await waitForRoom(for: chunk.count, source: source) }
                    guard let offset = progress.append(chunk, to: ring, generation: generation) else { return }
                    index.ingest(chunk, at: offset, oldest: ring.oldestOffset, generation: generation)
                    let count = chunk.count
                    queue.async {
                        if PipelineTrace.isEnabled { self.trace.noteArrival(bytes: count) }
                        self.lastDataArrival = Date()
                        self.stallReported = false
                        self.pump()
                    }
                }
                queue.async { self.finishIngest(error: nil, generation: generation) }
            } catch {
                queue.async { self.finishIngest(error: error, generation: generation) }
            }
        }
    }

    /// Reopens a finite source at `offset` (on `queue`): the ring and the index start again there, and the reader
    /// waits for the new data.
    func reopen(at offset: Int64) {
        guard let source = source.reopened(at: offset) else { return }
        Self.log.info("Reopening the stream at byte \(offset)")
        ingestTask?.cancel()
        activeSource.cancel()
        activeSource = source
        let generation = progress.restart(ring, at: offset)
        ingestGeneration = generation
        index.reset(to: offset, generation: generation)
        readOffset = offset
        seek.originNoted = true
        ending = EndOfStream()
        demuxer.resynchronize()
        timelineGuard.reset()
        restartTimeline()
        lastDataArrival = Date()
        ingestTask = ingest(from: source, generation: generation)
    }
}
