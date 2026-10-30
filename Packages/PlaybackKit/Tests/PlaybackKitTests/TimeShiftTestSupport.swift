//
//  TimeShiftTestSupport.swift
//  PlaybackKitTests
//
//  Streams and sources for the timeline and seek tests: H.264 transport streams encoded here (SyntheticNALStream,
//  a keyframe every half second and no audio), a finite source that can be reopened at an offset like a file or a
//  range request, a live source that delivers in real time, and a pipeline with its event log.
//

import AVFoundation
import Foundation
@testable import PlaybackKit
import Testing
import VideoToolbox

#if os(macOS)
nonisolated enum TimeShiftStream {
    static let frameSeconds = Double(SyntheticNALStream.frameTicks) / 90_000
    static let keyframeInterval = 15

    /// Ten seconds (300 pictures at 29.97).
    static let tenSeconds = make(frames: 300)
    /// Three seconds.
    static let threeSeconds = make(frames: 90)

    /// The streams, encoded off the main actor (other suites' tests wait on it).
    static func ten() async -> Data? { await Task.detached { tenSeconds }.value }
    static func three() async -> Data? { await Task.detached { threeSeconds }.value }

    /// `frames` pictures with their timestamps moved by `shift` ticks.
    static func make(frames: Int, shift: Int64 = 0) -> Data? {
        guard var pictures = SyntheticNALStream.encode(kCMVideoCodecType_H264, frames: frames,
                                                       keyframeInterval: keyframeInterval) else { return nil }
        for index in pictures.indices {
            pictures[index].pts += shift
            pictures[index].dts += shift
        }
        return SyntheticNALStream.transportStream(pictures, streamType: 0x1B)
    }

    /// The PTS of a point on the index's clock (0 is the first picture).
    static func pts(at seconds: Double) -> Int64 {
        SyntheticNALStream.firstPTS + Int64((seconds * 90_000).rounded())
    }

    /// The last picture's time.
    static func lastPicture(of frames: Int) -> Double {
        Double(frames - 1) * frameSeconds
    }
}

/// A file or a ranged HTTP resource: finite, with a length, and reopened at any offset (each open is counted).
nonisolated final class ReopenableSource: ByteSource, @unchecked Sendable {
    // @unchecked: immutable apart from the shared counter.
    let data: Data
    let start: Int
    let chunk: Int
    let opens: Counter

    init(data: Data, start: Int = 0, chunk: Int = 188 * 64, opens: Counter = Counter()) {
        self.data = data
        self.start = start
        self.chunk = chunk
        self.opens = opens
    }

    var isFinite: Bool { true }
    var contentLength: Int64? { Int64(data.count) }

    func reopened(at offset: Int64) -> (any ByteSource)? {
        ReopenableSource(data: data, start: Int(offset), chunk: chunk, opens: opens)
    }

    func open() async throws -> AsyncThrowingStream<Data, any Error> {
        opens.increment()
        let cursor = Cursor(offset: start)
        let data = data
        let chunk = chunk
        // Pulled, as a file is read: nothing runs ahead of the ingest.
        return AsyncThrowingStream {
            cursor.next(of: data, chunk: chunk)
        }
    }

    func cancel() {}

    /// Where the next chunk starts (the stream pulls one chunk at a time).
    private nonisolated final class Cursor: @unchecked Sendable {
        // @unchecked: `offset` is only touched under `lock`.
        private let lock = NSLock()
        private var offset: Int

        init(offset: Int) {
            self.offset = offset
        }

        func next(of data: Data, chunk: Int) -> Data? {
            lock.withLock {
                guard offset < data.count else { return nil }
                defer { offset += chunk }
                return data.subdata(in: offset..<min(offset + chunk, data.count))
            }
        }
    }
}

/// A live stream: `data` delivered in `pieces` parts spread over `seconds`, then held open.
nonisolated final class PacedLiveSource: ByteSource, @unchecked Sendable {
    // @unchecked: `task` is only touched under `lock`.
    let data: Data
    let pieces: Int
    let seconds: Double
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(data: Data, pieces: Int, seconds: Double) {
        self.data = data
        self.pieces = pieces
        self.seconds = seconds
    }

    func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self, throwing: (any Error).self)
        let (data, pieces, seconds) = (data, pieces, seconds)
        let task = Task.detached {
            let size = (data.count / pieces / 188 + 1) * 188
            var offset = 0
            while offset < data.count, !Task.isCancelled {
                continuation.yield(data.subdata(in: offset..<min(offset + size, data.count)))
                offset += size
                try? await Task.sleep(for: .seconds(seconds / Double(pieces)))
            }
            while !Task.isCancelled { try? await Task.sleep(for: .milliseconds(100)) }
            continuation.finish()
        }
        lock.withLock { self.task = task }
        return stream
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }
}

/// A pipeline on a memory ring, video only, and what it reports.
struct SeekRig {
    let pipeline: TransportStreamPipeline
    let renderer: SampleRenderer
    let log = StreamInfoLog()

    init(source: any ByteSource, ringBytes: Int = 8 << 20) {
        let renderer = SampleRenderer(videoRenderer: AVSampleBufferDisplayLayer().sampleBufferRenderer)
        let log = log
        self.renderer = renderer
        pipeline = TransportStreamPipeline(source: source, ring: MemoryByteRing(capacity: ringBytes, minimum: 188),
                                           renderer: renderer, preferredLanguage: "eng",
                                           playsAudio: false) { log.add($0) }
    }

    var timeline: PlaybackTimeline? { pipeline.published.timeline() }

    /// The first picture queued since the last seek, once there is one.
    var firstPicturePTS: Int64? {
        pipeline.queue.sync {
            renderer.firstQueuedVideoTime.map { CMTimeConvertScale($0, timescale: 90_000, method: .default).value }
        }
    }

    var hasStartedClock: Bool {
        pipeline.queue.sync { renderer.hasStartedClock }
    }

    /// Waits until the pipeline's queue has run everything sent to it so far.
    func settle() {
        pipeline.queue.sync {}
    }
}
#endif
