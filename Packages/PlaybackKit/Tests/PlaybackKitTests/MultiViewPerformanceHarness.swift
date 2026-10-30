//
//  MultiViewPerformanceHarness.swift
//  PlaybackKitTests
//
//  Opt-in (never part of the CI gate): the multi-view decode tiers on paced copies of a local capture, with the
//  same process numbers as PerformanceHarness (CPU, CPU energy, wakeups, memory) per layout. Run it in
//  Packages/PlaybackKit with
//
//      PLAYBACKKIT_PERF=1 swift test -c release --filter MultiViewPerformanceHarness
//
//  Optional: PLAYBACKKIT_PERF_SECONDS and PLAYBACKKIT_PERF_CAPTURE as for PerformanceHarness (default hdhr-9.1.ts, 1080i).
//  libavcodec and the Metal GPU stage (the playback path on every platform). Audible tiles are muted so the run is
//  quiet; muting doesn't stop audio decoding, so they cost what an audible tile costs. Never touches the network.
//

import Foundation
@testable import PlaybackKit
import Testing

#if os(macOS)
struct MultiViewPerformanceHarness {
    struct Tile {
        let tier: DecodeTier
        let playsAudio: Bool
    }

    static let foreground = Tile(tier: .single, playsAudio: true)
    static let gridTile = Tile(tier: .full(fieldRate: false), playsAudio: false)
    static let hiddenTile = Tile(tier: .reduced, playsAudio: false)

    static let layouts: [(name: String, tiles: [Tile])] = [
        ("1 tile, field rate + audio", [foreground]),
        ("2 tiles, foreground + 1 bob silent", [foreground, gridTile]),
        ("4 tiles, foreground + 3 bob silent", [foreground] + Array(repeating: gridTile, count: 3)),
        ("4 tiles, foreground + 3 reduced silent", [foreground] + Array(repeating: hiddenTile, count: 3)),
        ("4 tiles, all field rate + audio (no tiers)", Array(repeating: foreground, count: 4))
    ]

    @Test(.enabled(if: PerformanceHarness.isEnabled), .timeLimit(.minutes(20)))
    func multiViewTiers() async throws {
        let loop = try #require(CaptureLoop(data: Data(contentsOf: PerformanceHarness.capture)))
        var report: [String] = []
        for layout in Self.layouts {
            report.append(layout.name + ": " + (try await measure(layout.tiles, loop: loop)))
        }
        print(String(format: "MultiViewPerformanceHarness (%@, %.1f Mbps, libavcodec):",
                     PerformanceHarness.capture.lastPathComponent, loop.bytesPerSecond * 8 / 1_000_000)
              + "\n" + report.joined(separator: "\n"))
    }

    private func measure(_ tiles: [Tile], loop: CaptureLoop) async throws -> String {
        let timeShift = TimeShiftConfiguration(storage: .temporaryFile, capacityBytes: 256 << 20)
        let engines = tiles.map { tile in
            let engine = TransportStreamEngine(makeSource: { PacedCaptureSource(loop: loop) }, timeShift: timeShift)
            engine.setDecodeTier(tile.tier)
            engine.playsAudio = tile.playsAudio
            engine.isMuted = true
            return engine
        }
        VideoDecoders.$preferenceOverride.withValue(.libavcodec) {
            engines.forEach { $0.start() }
        }
        try await Task.sleep(for: .seconds(PerformanceHarness.warmUpSeconds))
        let before = ProcessSample.now()
        try await Task.sleep(for: .seconds(PerformanceHarness.measureSeconds))
        let after = ProcessSample.now()
        let playing = engines.filter { $0.state == .playing }.count
        let shown = engines.map(\.diagnostics.framesShown)
        let dropped = engines.map(\.diagnostics.framesDropped).reduce(0, +)
        let behind = engines.map(\.diagnostics.secondsBehindLive).max() ?? 0
        engines.forEach { $0.stop() }
        #expect(playing == tiles.count)
        try await Task.sleep(for: .seconds(1))
        return after.report(since: before, streams: tiles.count, playing: playing)
            + ", frames shown per tile \(shown) dropped \(dropped)"
            + String(format: ", worst behind live %.1f s", behind)
    }
}
#endif
