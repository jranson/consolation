//
//  AVPlayerEngineTimelineTests.swift
//  PlaybackKitTests
//
//  AVPlayerEngine's timeline offline: a small H.264 file written here (AVAssetWriter, a moving gradient) is on
//  demand with its duration, seeks land where asked (also while paused, which stays paused), and the timeline math
//  for live streams (the last seekable range, up to AVPlayer's distance from the live edge).
//

import AVFoundation
import CoreMedia
import Foundation
@testable import PlaybackKit
import Testing

#if os(macOS)
@Suite(.serialized)
struct AVPlayerEngineTimelineTests {
    /// Writes `seconds` of 160x120 H.264 at 30 frames a second, a keyframe every 10 frames.
    private static func writeMovie(seconds: Int) async throws -> URL {
        let url = FileManager.default.temporaryDirectory.appending(path: "PlaybackKit-\(UUID().uuidString).mp4")
        let writer = try AVAssetWriter(outputURL: url, fileType: .mp4)
        let input = AVAssetWriterInput(mediaType: .video, outputSettings: [
            AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: 160, AVVideoHeightKey: 120,
            AVVideoCompressionPropertiesKey: [AVVideoMaxKeyFrameIntervalKey: 10]
        ])
        input.expectsMediaDataInRealTime = false
        let adaptor = AVAssetWriterInputPixelBufferAdaptor(assetWriterInput: input, sourcePixelBufferAttributes: [
            kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
            kCVPixelBufferWidthKey as String: 160, kCVPixelBufferHeightKey as String: 120
        ])
        writer.add(input)
        #expect(writer.startWriting())
        writer.startSession(atSourceTime: .zero)
        for frame in 0..<(seconds * 30) {
            while !input.isReadyForMoreMediaData { try await Task.sleep(for: .milliseconds(5)) }
            let pool = try #require(adaptor.pixelBufferPool)
            var created: CVPixelBuffer?
            CVPixelBufferPoolCreatePixelBuffer(nil, pool, &created)
            let buffer = try #require(created)
            CVPixelBufferLockBaseAddress(buffer, [])
            if let base = CVPixelBufferGetBaseAddress(buffer) {
                memset(base, Int32(frame * 4 % 256), CVPixelBufferGetDataSize(buffer))
            }
            CVPixelBufferUnlockBaseAddress(buffer, [])
            #expect(adaptor.append(buffer, withPresentationTime: CMTime(value: CMTimeValue(frame), timescale: 30)))
        }
        input.markAsFinished()
        await writer.finishWriting()
        #expect(writer.status == .completed)
        return url
    }

    private func waitUntil(seconds: Double = 15, _ condition: () -> Bool) async throws -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
        return condition()
    }

    @Test func aFileHasItsDurationAndSeeks() async throws {
        let url = try await Self.writeMovie(seconds: 4)
        defer { try? FileManager.default.removeItem(at: url) }
        let engine = AVPlayerEngine(url: url, kind: .file)
        engine.isMuted = true
        defer { engine.stop() }
        #expect(engine.timeline() == nil)
        engine.start()
        #expect(try await waitUntil { engine.timeline() != nil })
        let timeline = try #require(engine.timeline())
        #expect(!timeline.isLive)
        #expect(timeline.range.lowerBound == 0)
        #expect(abs(timeline.range.upperBound - 4) < 0.1)

        engine.pause()
        engine.seek(toPosition: 2.5)
        // The target is reported at once, while the seek runs.
        #expect(engine.timeline()?.position == 2.5)
        #expect(try await waitUntil { abs(engine.currentTime - 2.5) < 0.25 && engine.seeks.target == nil })
        try await Task.sleep(for: .milliseconds(300))
        #expect(engine.state == .paused)
        #expect(abs(engine.currentTime - 2.5) < 0.25)

        // Fast scrubbing: only the latest of many requests is left to run.
        for step in 0..<20 { engine.seek(toPosition: Double(step) * 0.1) }
        #expect(abs((engine.timeline()?.position ?? -1) - 1.9) < 0.0001)
        #expect(try await waitUntil { engine.seeks.target == nil })
        #expect(abs(engine.currentTime - 1.9) < 0.25)
        engine.skip(by: -10)
        #expect(engine.timeline()?.position == 0)
        #expect(try await waitUntil { engine.seeks.target == nil })

        // A file that ended plays on after a seek back.
        engine.seek(toPosition: 3.6)
        engine.resume()
        #expect(try await waitUntil { engine.state == .ended })
        engine.seek(toPosition: 3)
        #expect(engine.state.isActive && engine.state != .paused)
        #expect(try await waitUntil { engine.state == .ended })
    }

    @Test func liveAndOnDemandMath() throws {
        let seconds = { (value: Double) in CMTime(seconds: value, preferredTimescale: 600) }
        let file = try #require(AVPlayerEngine.timeline(duration: seconds(90), seekable: [], position: 30,
                                                        liveOffset: .invalid))
        #expect(file.range == 0...90 && !file.isLive && file.position == 30)
        #expect(AVPlayerEngine.timeline(duration: .invalid, seekable: [], position: 0, liveOffset: .invalid) == nil)
        let ranges = [CMTimeRange(start: seconds(0), duration: seconds(10)),
                      CMTimeRange(start: seconds(100), duration: seconds(60))]
        let live = try #require(AVPlayerEngine.timeline(duration: .indefinite, seekable: ranges, position: 150,
                                                        liveOffset: seconds(18)))
        #expect(live.isLive)
        #expect(live.range == 100...142)
        #expect(live.position == 142)
        #expect(live.isAtLiveEdge)
        let noOffset = try #require(AVPlayerEngine.timeline(duration: .indefinite, seekable: ranges, position: 120,
                                                            liveOffset: .invalid))
        #expect(noOffset.range == 100...160)
        #expect(!noOffset.isAtLiveEdge)
        #expect(AVPlayerEngine.timeline(duration: .indefinite, seekable: [], position: 0, liveOffset: .zero) == nil)
    }
}
#endif
