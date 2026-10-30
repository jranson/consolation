//
//  FiniteSourceTests.swift
//  PlaybackKitTests
//
//  Finite transport streams (a file, or a complete .ts URL) arrive much faster than they play. The pipeline must not
//  lose unread data when the file is larger than the time-shift ring (the ingest waits and holds the source back),
//  must play to the end before reporting `.finished`, and the engine must stop there rather than reconnect.
//

import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

/// Hands over `data` in `chunk`-byte pieces as fast as the reader takes them, then ends: a file.
nonisolated final class FiniteSource: ByteSource, @unchecked Sendable {
    // @unchecked: `backlogged` is only touched under `lock`; the rest is immutable.
    let data: Data
    let chunk: Int
    private let lock = NSLock()
    private var heldBack = 0

    init(data: Data, chunk: Int) {
        self.data = data
        self.chunk = chunk
    }

    var isFinite: Bool { true }

    /// Times the pipeline asked the source to hold back.
    var holds: Int { lock.withLock { heldBack } }

    func setBacklogged(_ backlogged: Bool) {
        if backlogged { lock.withLock { heldBack += 1 } }
    }

    func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        var offset = 0
        while offset < data.count {
            continuation.yield(data.subdata(in: offset..<min(offset + chunk, data.count)))
            offset += chunk
        }
        continuation.finish()
        return stream
    }

    func cancel() {}
}

@Suite(.serialized)
struct FiniteSourceTests {
    /// A ring a fifth of the file's size: the ingest has to wait for the reader, nothing is overwritten unread, and
    /// the stream is reported finished (not ended or stalled) once it has played.
    @Test func playsAFileLargerThanTheRingToItsEnd() async throws {
        let data = try TilePipelineTests.fixture("testsrc-480i")
        let source = FiniteSource(data: data, chunk: 188 * 4)
        let log = StreamInfoLog()
        let renderer = SampleRenderer(videoRenderer: AVSampleBufferDisplayLayer().sampleBufferRenderer)
        let ring = MemoryByteRing(capacity: data.count / 5 / 188 * 188, minimum: 188)
        let pipeline = TransportStreamPipeline(source: source, ring: ring, renderer: renderer,
                                               preferredLanguage: "eng", playsAudio: false) { log.add($0) }
        pipeline.start()
        defer { pipeline.stop() }
        #expect(try await eventually { log.events.contains("finished") })
        #expect(log.started?.isLive == false)
        #expect(!log.events.contains("ended") && !log.events.contains("stalled") && log.failure == nil)
        #expect(pipeline.readPosition() == Int64(data.count))
        #expect(pipeline.progress.overruns == 0)
        #expect(source.holds > 0)
        #expect(pipeline.queue.sync { renderer.hasStartedClock && renderer.hasPlayedOut })
    }

    /// The engine stops in `.ended` at the end of a file and never opens it again.
    @Test func theEngineStopsAtTheEndOfAFile() async throws {
        let data = try TilePipelineTests.fixture("testsrc-480i")
        let opened = Counter()
        let engine = TransportStreamEngine(makeSource: {
            opened.increment()
            return FiniteSource(data: data, chunk: 188 * 16)
        }, timeShift: TimeShiftConfiguration(storage: .memory, capacityBytes: 4 << 20))
        engine.start()
        #expect(try await eventually { engine.state == .ended })
        #expect(engine.streamInfo.isLive == false)
        try await Task.sleep(for: .seconds(1.5))
        #expect(engine.state == .ended)
        #expect(opened.value == 1)
        engine.stop()
    }
}
