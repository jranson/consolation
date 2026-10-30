//
//  TimelineJumpReplay.swift
//  PlaybackKitTests
//
//  Opt-in regression test (never part of the CI gate): plays a local capture looped without shifting its
//  timestamps, so every pass jumps back in time with no discontinuity indicator or continuity break, and checks
//  that playback keeps going across the jumps. Before the timeline guard, the first jump stalled the pipeline for
//  good. Run it in Packages/PlaybackKit with
//
//      PLAYBACKKIT_REPLAY=1 swift test --filter TimelineJumpReplay
//
//  It needs a gitignored capture with audio in localdata/captures (PLAYBACKKIT_PERF_CAPTURE picks one, as for the
//  performance harness).
//

import Foundation
@testable import PlaybackKit
import Testing

#if os(macOS)
struct TimelineJumpReplay {
    nonisolated static let isEnabled = PerformanceHarness.environment["PLAYBACKKIT_REPLAY"] == "1"
        && FileManager.default.fileExists(atPath: PerformanceHarness.capture.path)

    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(2)))
    func keepsPlayingAcrossBackwardJumps() async throws {
        let loop = try #require(CaptureLoop(data: Data(contentsOf: PerformanceHarness.capture)))
        let passSeconds = Double(loop.data.count) / loop.bytesPerSecond
        let timeShift = TimeShiftConfiguration(storage: .temporaryFile, capacityBytes: 256 << 20)
        let engine = TransportStreamEngine(makeSource: { PacedCaptureSource(loop: loop, shiftsTimestamps: false) },
                                           timeShift: timeShift)
        engine.start()
        defer { engine.stop() }
        // Past the second jump and the restart after it (up to a GOP to the next I picture, plus the clock's audio
        // buffer), then a window in which frames must keep coming.
        try await Task.sleep(for: .seconds(passSeconds * 2 + 7))
        let before = engine.diagnostics.framesShown
        try await Task.sleep(for: .seconds(4))
        let shown = engine.diagnostics.framesShown - before
        print(String(format: "TimelineJumpReplay: %.1f s passes, %d frames shown in the last 4 s, audio %.2f s ahead",
                     passSeconds, shown, engine.diagnostics.audioSecondsBuffered))
        #expect(engine.state == .playing)
        #expect(shown > 60, "video kept moving after the timestamps jumped back")
        #expect(engine.diagnostics.audioSecondsBuffered > 0.3, "audio kept flowing")
    }
}
#endif
