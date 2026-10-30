//
//  PerformanceHarness.swift
//  PlaybackKitTests
//
//  Opt-in performance harness (never part of the CI gate): plays 1, 2 and 4 live engines at once from a local
//  capture, looped seamlessly (CaptureLoop) and paced at the capture's own rate, and reports process CPU, CPU
//  energy, wakeups, context switches, file writes and memory for each count. Run it in Packages/PlaybackKit with
//
//      PLAYBACKKIT_PERF=1 swift test -c release --filter PerformanceHarness
//
//  Optional: PLAYBACKKIT_PERF_DECODER=platform|libavcodec|both (libavcodec is the iPad, iPhone and Apple TV path),
//  PLAYBACKKIT_PERF_COUNTS=1,2,4, PLAYBACKKIT_PERF_SECONDS=20 and
//  PLAYBACKKIT_PERF_CAPTURE=<file in localdata/captures>. It needs a gitignored capture in localdata/captures. GPU
//  time isn't measured here (use Instruments' Metal System Trace).
//

import Darwin
import Foundation
@testable import PlaybackKit
import Testing

#if os(macOS)
struct PerformanceHarness {
    nonisolated static let capture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("localdata/captures")
        .appendingPathComponent(environment["PLAYBACKKIT_PERF_CAPTURE"] ?? "hdhr-9.1.ts")
    nonisolated static let environment = ProcessInfo.processInfo.environment
    nonisolated static let isEnabled = environment["PLAYBACKKIT_PERF"] == "1"
        && FileManager.default.fileExists(atPath: capture.path)
    /// How long each stream count is measured (`PLAYBACKKIT_PERF_SECONDS`), after a warm-up.
    static let measureSeconds = Double(environment["PLAYBACKKIT_PERF_SECONDS"] ?? "") ?? 20
    static let warmUpSeconds = 5.0
    /// Stream counts to measure, e.g. `PLAYBACKKIT_PERF_COUNTS=1,2,4`.
    static let counts = (environment["PLAYBACKKIT_PERF_COUNTS"] ?? "1,2,4").split(separator: ",").compactMap { Int($0) }
    /// `PLAYBACKKIT_PERF_DECODER`: `platform` (VideoToolbox on macOS), `libavcodec` (the iPad, iPhone and Apple TV path)
    /// or `both` (the default).
    static let decoders: [(name: String, preference: MPEG2DecoderPreference)] = {
        switch environment["PLAYBACKKIT_PERF_DECODER"] ?? "both" {
        case "platform": [("platform", .videoToolbox)]
        case "libavcodec": [("libavcodec", .libavcodec)]
        default: [("platform", .videoToolbox), ("libavcodec", .libavcodec)]
        }
    }()

    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(20)))
    func liveEnginesScale() async throws {
        let loop = try #require(CaptureLoop(data: Data(contentsOf: Self.capture)))
        var report: [String] = []
        for decoder in Self.decoders {
            for count in Self.counts {
                let line = try await measure(count: count, decoder: decoder.preference, loop: loop)
                report.append("\(decoder.name), " + line)
            }
        }
        print(String(format: "PerformanceHarness (%@, %.1f Mbps):", Self.capture.lastPathComponent,
                     loop.bytesPerSecond * 8 / 1_000_000) + "\n" + report.joined(separator: "\n"))
    }

    private func measure(count: Int, decoder: MPEG2DecoderPreference, loop: CaptureLoop) async throws -> String {
        let timeShift = TimeShiftConfiguration(storage: .temporaryFile, capacityBytes: 256 << 20)
        let engines = (0..<count).map { _ in
            TransportStreamEngine(makeSource: { PacedCaptureSource(loop: loop) }, timeShift: timeShift)
        }
        // Each pipeline makes its decoder synchronously in `start()`.
        VideoDecoders.$preferenceOverride.withValue(decoder) {
            engines.forEach { $0.start() }
        }
        try await Task.sleep(for: .seconds(Self.warmUpSeconds))
        let before = ProcessSample.now()
        try await Task.sleep(for: .seconds(Self.measureSeconds))
        let after = ProcessSample.now()
        let playing = engines.filter { $0.state == .playing }.count
        let shown = engines.map(\.diagnostics.framesShown).reduce(0, +)
        let dropped = engines.map(\.diagnostics.framesDropped).reduce(0, +)
        engines.forEach { $0.stop() }
        #expect(playing == count)
        try await Task.sleep(for: .seconds(1))
        let summary = after.report(since: before, streams: count, playing: playing)
        return summary + ", frames shown \(shown) dropped \(dropped)"
    }
}

/// CPU time, energy, wakeups, writes and memory footprint of this process.
struct ProcessSample {
    let cpuSeconds: Double
    let wall: Double
    let footprint: UInt64
    let energyNanojoules: UInt64
    let wakeups: UInt64
    let contextSwitches: Int
    let logicalWrites: UInt64

    static func now() -> ProcessSample {
        var usage = rusage()
        getrusage(RUSAGE_SELF, &usage)
        let cpu = Double(usage.ru_utime.tv_sec + usage.ru_stime.tv_sec)
            + Double(usage.ru_utime.tv_usec + usage.ru_stime.tv_usec) / 1_000_000
        var info = rusage_info_v6()
        _ = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V6, $0)
            }
        }
        return ProcessSample(cpuSeconds: cpu, wall: ProcessInfo.processInfo.systemUptime,
                             footprint: info.ri_phys_footprint, energyNanojoules: info.ri_energy_nj,
                             wakeups: info.ri_interrupt_wkups + info.ri_pkg_idle_wkups,
                             contextSwitches: Int(usage.ru_nvcsw + usage.ru_nivcsw),
                             logicalWrites: info.ri_logical_writes)
    }

    func report(since before: ProcessSample, streams: Int, playing: Int) -> String {
        let wall = wall - before.wall
        let cpu = (cpuSeconds - before.cpuSeconds) / wall * 100
        let milliwatts = Double(energyNanojoules - before.energyNanojoules) / wall / 1_000_000
        let wakeupRate = Double(wakeups - before.wakeups) / wall
        let switches = Double(contextSwitches - before.contextSwitches) / wall
        let writes = Double(logicalWrites - before.logicalWrites) / wall / 1_048_576
        return String(format: "%d stream(s): %d playing, CPU %.1f%% of one core (%.1f%% each), CPU energy %.0f mW, "
                        + "wakeups %.0f/s, context switches %.0f/s, writes %.1f MB/s, footprint %.0f MB",
                      streams, playing, cpu, cpu / Double(streams), milliwatts, wakeupRate, switches, writes,
                      Double(footprint) / 1_048_576)
    }
}

/// Replays a capture as an endless live stream at its own rate, like a tuner would.
/// Delivers a capture loop at its own rate. Without `shiftsTimestamps`, every pass jumps back to the capture's
/// first timestamps, as a broadcaster's splice or encoder restart without a discontinuity indicator would.
final class PacedCaptureSource: ByteSource, @unchecked Sendable {
    // @unchecked: `task` is only touched under `lock`.
    static let chunk = 188 * 348

    private let loop: CaptureLoop
    private let shiftsTimestamps: Bool
    private let lock = NSLock()
    private var task: Task<Void, Never>?

    init(loop: CaptureLoop, shiftsTimestamps: Bool = true) {
        self.loop = loop
        self.shiftsTimestamps = shiftsTimestamps
    }

    func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let (stream, continuation) = AsyncThrowingStream.makeStream(of: Data.self)
        let loop = loop
        let shifts = shiftsTimestamps
        let task = Task.detached {
            let clock = ContinuousClock()
            let start = clock.now
            var sent = 0
            var pass = 0
            var offset = 0
            while !Task.isCancelled {
                let end = min(offset + Self.chunk, loop.data.count)
                continuation.yield(loop.bytes(offset..<end, pass: pass, shiftsTimestamps: shifts))
                sent += end - offset
                offset = end
                if offset == loop.data.count {
                    offset = 0
                    pass += 1
                }
                // Deadlines, not intervals, so the rate never drifts below the broadcast's.
                try? await Task.sleep(until: start + .seconds(Double(sent) / loop.bytesPerSecond), clock: clock)
            }
            continuation.finish()
        }
        lock.withLock { self.task = task }
        return stream
    }

    func cancel() {
        lock.withLock { task }?.cancel()
    }
}
#endif
