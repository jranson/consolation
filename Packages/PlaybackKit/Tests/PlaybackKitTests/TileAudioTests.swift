//
//  TileAudioTests.swift
//  PlaybackKitTests
//
//  Audio per multi-view tile: a silent tile frames its audio without enqueuing it ("virtual" audio), yet its clock
//  starts and its live-buffer guard acts exactly as an audible tile's; turning audio on enqueues only the kept audio
//  the clock hasn't reached.
//

import AVFoundation
import CoreMedia
import Foundation
import Testing
@testable import PlaybackKit

@Suite(.serialized)
struct TileAudioTests {
    /// 90 kHz ticks per audio sample buffer: four AC-3 frames of 1536 samples at 48 kHz (128 ms).
    static let sampleTicks: Int64 = 11_520
    static let firstAudio: Int64 = 900_000

    /// An AC-3 stereo sample buffer of four (dummy) frames.
    static func audioSample(_ index: Int) throws -> CMSampleBuffer {
        let format = try #require(SampleFormats.dolbyAudio(sampleRate: 48_000, channels: 2, isEAC3: false,
                                                           samplesPerFrame: 1_536))
        let frames = Array(repeating: Data(repeating: 0, count: 768), count: 4)
        return try #require(SampleFormats.audioSample(frames: frames, format: format,
                                                      pts: firstAudio + Int64(index) * sampleTicks))
    }

    static func renderer(playsAudio: Bool) -> SampleRenderer {
        let renderer = SampleRenderer(videoRenderer: AVSampleBufferDisplayLayer().sampleBufferRenderer)
        renderer.setPlaysAudio(playsAudio)
        renderer.noteSkippedVideo(at: SampleFormats.time(firstAudio))
        return renderer
    }

    /// The clock waits for `startAudioBuffer` of audio whether or not the audio is enqueued.
    @Test(arguments: [false, true])
    func clockStartsAfterTheSameAudio(playsAudio: Bool) throws {
        let renderer = Self.renderer(playsAudio: playsAudio)
        var started: Int?
        for index in 0..<12 {
            renderer.enqueueAudio(try Self.audioSample(index))
            if started == nil, renderer.hasStartedClock { started = index }
        }
        // 8 buffers (1.024 s) are the first to reach a second of audio.
        #expect(started == 7)
        #expect(renderer.submittedAudioSamples == (playsAudio ? 12 : 0))
        renderer.stop()
    }

    @Test func promotionEnqueuesOnlyWhatTheClockHasNotReached() async throws {
        let renderer = Self.renderer(playsAudio: false)
        let samples = try (0..<20).map { try Self.audioSample($0) }
        for sample in samples { renderer.enqueueAudio(sample) }
        #expect(renderer.hasStartedClock)
        // Let the clock pass the start cushion and some of the audio, then freeze it to compare exactly.
        try await Task.sleep(for: .milliseconds(1_200))
        renderer.setPaused(true)
        let now = renderer.currentTime
        let due = samples.filter { CMTimeCompare(CMSampleBufferGetPresentationTimeStamp($0), now) >= 0 }.count
        #expect(due > 0 && due < samples.count, "clock at \(now.seconds)")
        renderer.setPlaysAudio(true)
        #expect(renderer.submittedAudioSamples == due)
        // Turning it off again flushes; the timeline (and so the pacing) is untouched.
        let ahead = renderer.audioSecondsAhead
        renderer.setPlaysAudio(false)
        #expect(renderer.audioSecondsAhead == ahead)
        renderer.stop()
    }

    /// A silent tile rebuffers when its virtual audio runs low, and resumes once a second is queued again.
    @Test func liveBufferGuardWatchesVirtualAudio() async throws {
        let renderer = Self.renderer(playsAudio: false)
        for index in 0..<10 { renderer.enqueueAudio(try Self.audioSample(index)) }
        #expect(renderer.hasStartedClock)
        #expect(!renderer.guardLiveBuffer())
        // 1.28 s of audio plus the 0.5 s cushion: below the 0.3 s low-water mark after about 1.5 s (the synchronizer
        // applies a start a moment late).
        try await Task.sleep(for: .milliseconds(2_000))
        #expect(renderer.audioSecondsAhead < SampleRenderer.lowWaterAudio)
        #expect(renderer.guardLiveBuffer())
        #expect(renderer.isRebuffering)
        for index in 10..<24 { renderer.enqueueAudio(try Self.audioSample(index)) }
        #expect(!renderer.isRebuffering)
        #expect(renderer.submittedAudioSamples == 0)
        renderer.stop()
    }

    @Test func recentAudioKeepsUnplayedSamplesWithinItsSpan() throws {
        var recent = RecentAudio()
        let samples = try (0..<40).map { try Self.audioSample($0) }
        for sample in samples {
            let start = CMSampleBufferGetPresentationTimeStamp(sample)
            recent.append(sample, start: start, end: CMTimeAdd(start, CMSampleBufferGetDuration(sample)), now: nil)
        }
        // 40 x 128 ms = 5.12 s: the samples starting within 4 s of the newest end are kept.
        #expect(recent.count == 31)
        let clock = SampleFormats.time(Self.firstAudio + 36 * Self.sampleTicks)
        #expect(recent.samples(startingAtOrAfter: clock).count == 4)
        let last = samples[39]
        let start = CMSampleBufferGetPresentationTimeStamp(last)
        recent.append(last, start: start, end: start, now: clock)
        #expect(recent.count == 5)
    }
}
