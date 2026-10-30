//
//  VideoStageTimings.swift
//  PlaybackKit
//
//  Where the decode thread's time goes, stage by stage: the decoder's own work, encoding and committing GPU passes,
//  time blocked on the GPU, and wrapping pictures in sample buffers. Cheap enough to stay on (a couple of clock reads
//  per stage); `VideoFrameStage.takeTimings()` hands out the totals since the last call, e.g. once a second for the
//  pipeline's health trace. Signposts mark the same stages for Instruments (category "VideoStage").
//

import CoreVideo
import Foundation
import Metal
import os
import Synchronization

/// Seconds spent per stage since the last `VideoFrameStage.takeTimings()`.
nonisolated struct VideoStageTimings: Sendable, Equatable {
    /// Compressed pictures processed.
    var pictures = 0
    /// Wall time inside `VideoFrameStage.process`, and the thread's CPU time in it.
    var total: Double = 0
    var threadCPU: Double = 0
    /// The decoder itself (libavcodec or VideoToolbox), without the GPU conversion below.
    var decode: Double = 0
    /// Encoding and committing the I420-to-NV12 pass (libavcodec only).
    var conversionSubmit: Double = 0
    /// Encoding and committing the deinterlacer's pass.
    var deinterlaceSubmit: Double = 0
    /// Blocked waiting for GPU work to finish. Near zero while the GPU keeps up, since work is collected a picture
    /// later.
    var gpuWait: Double = 0
    /// Attachments, format descriptions and sample buffers.
    var output: Double = 0
    /// GPU execution time of the conversion and deinterlacing passes that completed (from the command buffers).
    var gpuBusy: Double = 0

    /// One line, in milliseconds per picture.
    var summary: String {
        let count = Double(max(pictures, 1))
        let perPicture = { (seconds: Double) in seconds / count * 1_000 }
        return String(format: "video %d pictures, per picture %.2f ms (CPU %.2f): decode %.2f, convert %.2f, "
                        + "deinterlace %.2f, GPU wait %.2f, output %.2f; GPU busy %.2f ms",
                      pictures, perPicture(total), perPicture(threadCPU), perPicture(decode),
                      perPicture(conversionSubmit), perPicture(deinterlaceSubmit), perPicture(gpuWait),
                      perPicture(output), perPicture(gpuBusy))
    }
}

/// Collects `VideoStageTimings` on the decode thread (not thread-safe; one per stage).
nonisolated final class VideoStageClock {
    static let signposter = OSSignposter(subsystem: "PlaybackKit", category: "VideoStage")

    private var timings = VideoStageTimings()

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }
    static func threadCPU() -> UInt64 { clock_gettime_nsec_np(CLOCK_THREAD_CPUTIME_ID) }

    /// Runs `body`, adding its wall time to `stage` and marking it with a signpost.
    func measure<Result>(_ stage: WritableKeyPath<VideoStageTimings, Double>, _ name: StaticString,
                         _ body: () throws -> Result) rethrows -> Result {
        let state = Self.signposter.beginInterval(name)
        let start = Self.now()
        defer {
            timings[keyPath: stage] += Double(Self.now() - start) / 1e9
            Self.signposter.endInterval(name, state)
        }
        return try body()
    }

    /// Adds `seconds` to `stage`, e.g. to take a nested stage's time back out of its parent.
    func add(_ seconds: Double, to stage: WritableKeyPath<VideoStageTimings, Double>) {
        timings[keyPath: stage] += seconds
    }

    func notePicture() {
        timings.pictures += 1
    }

    /// The totals since the last call.
    func take() -> VideoStageTimings {
        defer { timings = VideoStageTimings() }
        return timings
    }
}

/// Blocks until `commands` finished, counting the time as a GPU wait on `clock`. Returns at once for finished work.
nonisolated func waitForGPU(_ commands: (any MTLCommandBuffer)?, clock: VideoStageClock?) {
    guard let commands, commands.status.rawValue < MTLCommandBufferStatus.completed.rawValue else { return }
    if let clock {
        clock.measure(\.gpuWait, "GPU wait") { commands.waitUntilCompleted() }
    } else {
        commands.waitUntilCompleted()
    }
}

/// GPU execution time of completed command buffers; fed from Metal's completion threads.
nonisolated final class GPUTimeMeter: Sendable {
    private let total = Mutex<Double>(0)

    var seconds: Double { total.withLock { $0 } }

    /// Adds the GPU time of `commands` once they complete. Call before committing.
    func track(_ commands: any MTLCommandBuffer) {
        commands.addCompletedHandler { [self] done in
            let seconds = max(done.gpuEndTime - done.gpuStartTime, 0)
            total.withLock { $0 += seconds }
        }
    }
}

/// Keeps a GPU pass's inputs and outputs alive until its command buffer completes (passes use unretained references,
/// so nothing else would).
nonisolated final class PassResources: @unchecked Sendable {
    // @unchecked: the objects are only kept, never touched.
    private let objects: [AnyObject]

    init(_ objects: [AnyObject]) {
        self.objects = objects
    }

    /// Holds the resources until `commands` complete. Call before committing.
    func keep(until commands: any MTLCommandBuffer) {
        commands.addCompletedHandler { [self] _ in withExtendedLifetime(self) {} }
    }
}

/// Metal textures from a `CVMetalTextureCache` that in-flight GPU passes use. They must be released on the thread
/// that owns the cache (releasing one on Metal's completion thread races the cache and crashes), so they are kept
/// here until their pass completed and dropped on the owner's next call, or waited for when the owner goes away.
nonisolated final class RetiredTextures {
    private var pending: [(commands: any MTLCommandBuffer, textures: [CVMetalTexture])] = []

    /// Keeps `textures` until `commands` (committed) complete.
    func keep(_ textures: [CVMetalTexture], until commands: any MTLCommandBuffer) {
        pending.append((commands, textures))
    }

    /// Drops the textures of passes that completed.
    func prune() {
        pending.removeAll { $0.commands.status.rawValue >= MTLCommandBufferStatus.completed.rawValue }
    }

    deinit {
        for entry in pending { entry.commands.waitUntilCompleted() }
    }
}
