//
//  TilePipelineTests.swift
//  PlaybackKitTests
//
//  The transport stream pipeline and engine as multi-view tiles: program selection from a two-program multiplex,
//  suspended tiles that keep reading, and tile settings that survive a reconnect.
//

import AVFoundation
import Foundation
import MPEGTS
import Testing
@testable import PlaybackKit

/// Hands over `data` in one chunk; then ends (a dropped connection), stays open until cancelled, or with
/// `repeating` hands it over again every 0.2 s (a live stream that never stalls).
nonisolated final class FixtureSource: ByteSource, @unchecked Sendable {
    // @unchecked: `task` is only touched under `lock`; the rest is immutable.
    let data: Data
    let programNumber: Int?
    let ends: Bool
    let repeating: Bool
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(data: Data, programNumber: Int? = nil, ends: Bool = false, repeating: Bool = false) {
        self.data = data
        self.programNumber = programNumber
        self.ends = ends
        self.repeating = repeating
    }

    func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        continuation.yield(data)
        if ends { continuation.finish() }
        if repeating {
            let data = data
            let task = Task.detached {
                while !Task.isCancelled {
                    try? await Task.sleep(for: .milliseconds(200))
                    continuation.yield(data)
                }
                continuation.finish()
            }
            lock.withLock { self.task = task }
        }
        return stream
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }
}

/// Collects a pipeline's events (they arrive on its queue).
nonisolated final class EventLog: @unchecked Sendable {
    // @unchecked: `events` is only touched under `lock`.
    private let lock = NSLock()
    private var events: [TransportStreamPipeline.Event] = []

    func add(_ event: TransportStreamPipeline.Event) {
        lock.withLock { events.append(event) }
    }

    var audioTracks: [AudioTrackOption]? {
        lock.withLock {
            events.compactMap { event -> [AudioTrackOption]? in
                if case .audioTracks(let tracks, _) = event { tracks } else { nil }
            }.last
        }
    }

    var hasStarted: Bool {
        lock.withLock { events.contains { if case .started = $0 { true } else { false } } }
    }
}

/// Polls `condition` every 20 ms for up to `seconds`.
func eventually(_ seconds: Double = 20, _ condition: () -> Bool) async throws -> Bool {
    let deadline = ContinuousClock.now + .seconds(seconds)
    while ContinuousClock.now < deadline {
        if condition() { return true }
        try await Task.sleep(for: .milliseconds(20))
    }
    return condition()
}

@Suite(.serialized)
struct TilePipelineTests {
    static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private func pipeline(_ source: any ByteSource, tier: DecodeTier = .single,
                          log: EventLog) throws -> TransportStreamPipeline {
        let renderer = SampleRenderer(videoRenderer: AVSampleBufferDisplayLayer().sampleBufferRenderer)
        let ring = MemoryByteRing(capacity: 4 << 20)
        return TransportStreamPipeline(source: source, ring: ring, renderer: renderer, preferredLanguage: "eng",
                                       tier: tier, playsAudio: false) { log.add($0) }
    }

    /// The source's program is played even when it isn't first in the PAT, and only its PIDs are reassembled.
    @Test(arguments: [3, 4])
    func playsTheRequestedProgramOfTwo(program: Int) async throws {
        let data = try Self.fixture("two-programs")
        let log = EventLog()
        let pipeline = try pipeline(FixtureSource(data: data, programNumber: program), log: log)
        pipeline.start()
        defer { pipeline.stop() }
        #expect(try await eventually { pipeline.tileState().program != nil && log.hasStarted })
        let state = pipeline.tileState()
        #expect(state.program == UInt16(program))
        // The fixture's program 3 has English audio and program 4 Spanish.
        #expect(log.audioTracks?.map(\.language) == [program == 3 ? "eng" : "spa"])
        var demuxer = TSDemuxer()
        let programs = demuxer.feed(data).compactMap { event -> [ProgramMap]? in
            if case .programs(let list) = event { list } else { nil }
        }.last ?? []
        let chosen = try #require(programs.first { Int($0.programNumber) == program })
        let other = try #require(programs.first { Int($0.programNumber) != program })
        let filter = try #require(state.pesFilter)
        #expect(filter.isSubset(of: Set(chosen.streams.map(\.pid))))
        #expect(filter.count == 2)
        #expect(filter.isDisjoint(with: other.streams.map(\.pid)))
    }

    @Test func aProgramMissingFromThePATFallsBackToTheFirst() async throws {
        let log = EventLog()
        let pipeline = try pipeline(FixtureSource(data: try Self.fixture("two-programs"), programNumber: 9), log: log)
        pipeline.start()
        defer { pipeline.stop() }
        #expect(try await eventually { pipeline.tileState().program != nil })
        #expect(pipeline.tileState().program == 3)
    }

    @Test func programChoiceWaitsForTheRequestedPMT() {
        let first = ProgramMap(programNumber: 3, pmtPID: 0x30, pcrPID: 0x41, streams: [])
        let second = ProgramMap(programNumber: 4, pmtPID: 0x40, pcrPID: 0x42, streams: [])
        #expect(TrackSelection.program(in: [first], listed: [3, 4], requested: 4) == nil)
        #expect(TrackSelection.program(in: [first, second], listed: [3, 4], requested: 4) == second)
        #expect(TrackSelection.program(in: [first, second], listed: [3, 4], requested: nil) == first)
        #expect(TrackSelection.program(in: [first], listed: [3], requested: 4) == first)
    }

    /// A suspended tile decodes nothing but keeps reading: it announces the stream and consumes the ring.
    @Test func suspendedTileKeepsReading() async throws {
        let data = try Self.fixture("testsrc-480i")
        let log = EventLog()
        let pipeline = try pipeline(FixtureSource(data: data), tier: .suspended, log: log)
        pipeline.start()
        defer { pipeline.stop() }
        #expect(try await eventually { log.hasStarted })
        #expect(try await eventually { pipeline.readPosition() >= Int64(data.count / 188 * 188) })
        #expect(pipeline.tileState().tier == .suspended)
    }
}

/// The engine keeps a tile's settings across reconnects: every new pipeline starts with them.
@Suite(.serialized)
struct TileEngineReconnectTests {
    @Test func tierAndAudioSurviveAReconnect() async throws {
        let data = try TilePipelineTests.fixture("testsrc-480i")
        let opened = Counter()
        // The first connection drops at once; the second stays up.
        let engine = TransportStreamEngine(makeSource: {
            opened.increment()
            return FixtureSource(data: data, ends: opened.value == 1, repeating: opened.value > 1)
        }, timeShift: TimeShiftConfiguration(storage: .memory, capacityBytes: 4 << 20))
        engine.start()
        engine.setDecodeTier(.reduced)
        engine.playsAudio = false
        engine.volume = 0.5
        #expect(engine.pipelineTileState?.tier == .reduced)
        // The engine reconnects after its first delay (1 s). Other suites can hold the main actor for seconds, so
        // the wait is generous.
        #expect(try await eventually { opened.value >= 2 && engine.pipelineTileState != nil })
        let state = try #require(engine.pipelineTileState)
        #expect(state.tier == .reduced)
        #expect(!state.playsAudio)
        #expect(engine.decodeTier == .reduced)
        engine.stop()
    }
}

nonisolated final class Counter: @unchecked Sendable {
    // @unchecked: `count` is only touched under `lock`.
    private let lock = NSLock()
    private var count = 0

    func increment() { lock.withLock { count += 1 } }
    var value: Int { lock.withLock { count } }
}
