//
//  MatroskaPipelineTests.swift
//  PlaybackKitTests
//
//  The Matroska pipeline and engine on synthetic H.264 files: playing to the end, reading Cues written after the
//  Clusters on a second connection and seeking with them, and saying what it can't play.
//

import AVFoundation
import Foundation
import Matroska
import MatroskaTestSupport
import Testing
@testable import PlaybackKit

#if os(macOS)
/// A file in memory that can be reopened at any offset, as `FileByteSource` and `HTTPByteSource` can.
nonisolated final class ReopenableDataSource: ByteSource, @unchecked Sendable {
    // @unchecked: `opened` is only touched under `lock`; the rest is immutable.
    let data: Data
    let offset: Int
    private let lock = NSLock()
    private var opened: [Int] = []
    private let parent: ReopenableDataSource?

    init(data: Data, offset: Int = 0, parent: ReopenableDataSource? = nil) {
        self.data = data
        self.offset = offset
        self.parent = parent
    }

    var isFinite: Bool { true }
    var contentLength: Int64? { Int64(data.count) }

    func reopened(at offset: Int64) -> (any ByteSource)? {
        ReopenableDataSource(data: data, offset: Int(offset), parent: parent ?? self)
    }

    /// The offsets every source made from this one was opened at.
    var openedOffsets: [Int] { lock.withLock { opened } }

    func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let root = parent ?? self
        root.lock.withLock { root.opened.append(offset) }
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        var position = min(offset, data.count)
        while position < data.count {
            continuation.yield(data.subdata(in: position..<min(position + 32_768, data.count)))
            position += 32_768
        }
        continuation.finish()
        return stream
    }

    func cancel() {}
}

/// A Matroska pipeline's events.
nonisolated final class MatroskaEventLog: @unchecked Sendable {
    // @unchecked: every property is only touched under `lock`.
    private let lock = NSLock()
    private var info: PlaybackStreamInfo?
    private var error: PlaybackError?
    private var kinds: [String] = []

    func add(_ event: MatroskaPipeline.Event) {
        lock.withLock {
            switch event {
            case .started(let started): info = started
            case .failed(let failure): error = failure
            default: break
            }
            kinds.append(String(describing: event).prefix { $0 != "(" }.description)
        }
    }

    var started: PlaybackStreamInfo? { lock.withLock { info } }
    var failure: PlaybackError? { lock.withLock { error } }
    var events: [String] { lock.withLock { kinds } }
}

@Suite(.serialized)
struct MatroskaPipelineTests {
    private func pipeline(_ source: any ByteSource, log: MatroskaEventLog) -> (MatroskaPipeline, SampleRenderer) {
        let renderer = SampleRenderer(videoRenderer: AVSampleBufferDisplayLayer().sampleBufferRenderer)
        let pipeline = MatroskaPipeline(source: source, ring: MemoryByteRing(capacity: 1 << 20), renderer: renderer,
                                        preferredLanguage: "eng") { log.add($0) }
        return (pipeline, renderer)
    }

    @Test func playsASyntheticFileToItsEnd() async throws {
        let file = try #require(SyntheticMatroska.h264(frames: 45, keyframeInterval: 15))
        let log = MatroskaEventLog()
        let (pipeline, renderer) = pipeline(FiniteSource(data: file.data, chunk: 4_096), log: log)
        pipeline.start()
        defer { pipeline.stop() }
        #expect(try await eventually { log.events.contains("finished") })
        let info = try #require(log.started)
        #expect(info.videoCodec == "H.264" && info.width == 320 && info.height == 240)
        #expect(info.isLive == false && info.audioCodec == nil)
        #expect(log.failure == nil)
        #expect(pipeline.queue.sync { renderer.hasStartedClock && renderer.hasPlayedOut })
    }

    @Test func readsTheCuesAtTheEndAndSeeksWithThem() async throws {
        let file = try #require(SyntheticMatroska.h264(frames: 120, keyframeInterval: 30))
        let source = ReopenableDataSource(data: file.data)
        let log = MatroskaEventLog()
        let (pipeline, _) = pipeline(source, log: log)
        pipeline.start()
        defer { pipeline.stop() }
        let clusters = file.clusters.count
        #expect(clusters >= 4)
        #expect(try await eventually { pipeline.queue.sync { pipeline.cues?.points.count } == clusters })
        // The Cues were read on their own connection, where the SeekHead points.
        #expect(source.openedOffsets.count >= 2)
        let range = try #require(pipeline.published.timeline()?.range)
        #expect(abs(range.upperBound - 4.004) < 0.01)
        pipeline.seek(toTime: 3.2)
        #expect(try await eventually(5) {
            guard let position = pipeline.published.timeline()?.position else { return false }
            return position >= 3.2 && position < 3.6
        })
        #expect(pipeline.queue.sync { pipeline.seek.presentFrom != nil })
        #expect(try await eventually { log.events.contains("finished") })
        #expect(log.failure == nil)
    }

    @Test func unplayableVideoFailsWithItsName() async throws {
        let vp9 = MatroskaTestTrack(number: 1, type: 1, codecID: "V_VP9")
        var file = MatroskaTestFile(tracks: [vp9], frames: [MatroskaTestFrame(track: 1, timestamp: 0,
                                                                               isKeyframe: true, data: [0x82])])
        file.write()
        let log = MatroskaEventLog()
        let (pipeline, _) = pipeline(FiniteSource(data: file.data, chunk: 4_096), log: log)
        pipeline.start()
        defer { pipeline.stop() }
        #expect(try await eventually { log.failure != nil })
        #expect(log.failure?.kind == .unsupportedFormat)
        #expect(log.failure?.title.contains("VP9") == true)
    }

    @Test func audioItCantDecodeIsNamed() async throws {
        let dts = MatroskaTestTrack(number: 2, type: 2, codecID: "A_DTS", language: "eng")
        let frames = (0..<30).map { MatroskaTestFrame(track: 2, timestamp: Int64($0 * 10), isKeyframe: true,
                                                     data: [0x7F, 0xFE, 0x80, 0x01]) }
        let file = try #require(SyntheticMatroska.h264(frames: 30, keyframeInterval: 15, extraTracks: [dts],
                                                       extraFrames: frames))
        let log = MatroskaEventLog()
        let (pipeline, _) = pipeline(FiniteSource(data: file.data, chunk: 4_096), log: log)
        pipeline.start()
        defer { pipeline.stop() }
        #expect(try await eventually { log.started != nil })
        #expect(log.started?.unsupportedAudioCodec == "DTS")
        #expect(log.started?.audioCodec == nil)
    }

    @Test func theEngineStopsAtTheEndAndSeeksBack() async throws {
        let file = try #require(SyntheticMatroska.h264(frames: 30, keyframeInterval: 15))
        let engine = MatroskaEngine(makeSource: { ReopenableDataSource(data: file.data) }, bufferBytes: 1 << 20)
        engine.start()
        #expect(try await eventually { engine.state == .ended })
        #expect(engine.streamInfo.isLive == false)
        #expect(engine.audioTracks.isEmpty && engine.selectedAudioTrackID == nil)
        engine.seek(toPosition: 0.2)
        #expect(engine.state == .playing)
        #expect(try await eventually { engine.state == .ended })
        engine.stop()
    }
}
#endif
