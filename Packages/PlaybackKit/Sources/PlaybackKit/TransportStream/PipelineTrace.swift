//
//  PipelineTrace.swift
//  PlaybackKit
//
//  The optional per-second health trace for diagnosing smoothness: buffer levels, dropped frames, clock rate, plus what
//  happened in the last second (bytes received, chunks, pictures decoded with their average and worst decode time,
//  pump wake-ups and the longest gap between them). The app turns it on (`PlaybackHealthTrace.isEnabled`), for
//  example from a launch environment variable; the line goes to the log and to stdout, so a device launch with
//  `devicectl ... --console` shows it.
//

import Foundation
import OSLog
import Synchronization

/// Whether transport-stream engines print the per-second health trace. Off unless the app turns it on, before
/// playback starts.
public nonisolated enum PlaybackHealthTrace {
    private static let enabled = Atomic<Bool>(false)

    public static var isEnabled: Bool {
        get { enabled.load(ordering: .relaxed) }
        set { enabled.store(newValue, ordering: .relaxed) }
    }
}

nonisolated struct PipelineTrace {
    static var isEnabled: Bool { PlaybackHealthTrace.isEnabled }
    static let log = Logger(subsystem: "PlaybackKit", category: "TransportStream")

    private var bytes = 0
    private var chunks = 0
    private var decodes = 0
    private var decodeTotal: UInt64 = 0
    private var decodeWorst: UInt64 = 0
    private var ticks = 0
    private var lastTick: UInt64 = 0
    private var worstTickGap: UInt64 = 0

    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    mutating func noteArrival(bytes count: Int) {
        bytes += count
        chunks += 1
    }

    mutating func noteDecode(since start: UInt64) {
        let elapsed = Self.now() - start
        decodes += 1
        decodeTotal += elapsed
        decodeWorst = max(decodeWorst, elapsed)
    }

    mutating func noteTick() {
        let now = Self.now()
        ticks += 1
        if lastTick > 0 { worstTickGap = max(worstTickGap, now - lastTick) }
        lastTick = now
    }

    /// One line for the last second, then starts the next second.
    mutating func report(_ diagnostics: PlaybackDiagnostics, behindSeconds: Double, pending: Int, rate: Float,
                         video: VideoStageTimings) {
        let average = decodes > 0 ? Double(decodeTotal) / Double(decodes) / 1e6 : 0
        let line = String(format: """
            Health: behind %.2f s, audio %.2f s, video %.2f s, pending %d, frames %d dropped %d, \
            rate %.4f | in %d KB/%d chunks, decoded %d avg %.1f ms worst %.1f ms, %d ticks, worst gap %.0f ms
            """, behindSeconds, diagnostics.audioSecondsBuffered, diagnostics.videoSecondsBuffered, pending,
            diagnostics.framesShown, diagnostics.framesDropped, rate, bytes / 1_024, chunks,
            decodes, average, Double(decodeWorst) / 1e6, ticks, Double(worstTickGap) / 1e6) + " | " + video.summary
        Self.log.notice("\(line, privacy: .public)")
        print(line)
        let tick = lastTick
        self = PipelineTrace()
        lastTick = tick
    }
}
