//
//  AVPlayerTimelineNetworkTests.swift
//  PlaybackKitTests
//
//  Opt-in network test (never part of `make test` or `make build`): the timeline and seeking on sample HDR10 HLS and
//  DASH test streams, through every route they take: the tone-mapped split (display forced not HDR-eligible) and the
//  repaired or translated multivariant playlist (forced eligible). Each must report an on-demand timeline of the real
//  length (about 2 h 25 min), seek to 600 s and 3000 s, and play on from there (in a split, with its audio following).
//  The streams come from `PLAYBACKKIT_HDR10_STREAMS`, as in `ToneMappedSplitNetworkTests`. Run it in
//  Packages/PlaybackKit with
//
//      PLAYBACKKIT_TIMELINE_NETWORK=1 PLAYBACKKIT_HDR10_STREAMS=https://<host>/<path>/ \
//          swift test --filter AVPlayerTimelineNetworkTests
//

import AVFoundation
import Foundation
@testable import PlaybackKit
import Testing

#if os(macOS)
@Suite(.serialized)
struct AVPlayerTimelineNetworkTests {
    nonisolated static let isEnabled = ProcessInfo.processInfo.environment["PLAYBACKKIT_TIMELINE_NETWORK"] == "1"
        && !ToneMappedSplitNetworkTests.base.isEmpty

    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let file: String
        let kind: AVPlayerEngine.InputKind
        let eligible: Bool
        var testDescription: String { "\(file) \(eligible ? "HDR-eligible" : "split")" }
    }

    nonisolated static let cases = [
        Case(file: "hls.m3u8", kind: .hls, eligible: false), Case(file: "hls.m3u8", kind: .hls, eligible: true),
        Case(file: "dash.mpd", kind: .dash, eligible: false), Case(file: "dash.mpd", kind: .dash, eligible: true)
    ]

    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(3)), arguments: cases)
    func seeksOnTheSampleStreams(_ item: Case) async throws {
        let url = try #require(URL(string: ToneMappedSplitNetworkTests.base + item.file))
        let configuration = AVPlayerEngine.Configuration(hdrEligibility: item.eligible ? .eligible : .ineligible)
        let engine = AVPlayerEngine(url: url, kind: item.kind, configuration: configuration)
        engine.isMuted = true
        defer { engine.stop() }
        engine.start()
        try await waitUntil(seconds: 30) { engine.timeline() != nil || !engine.state.isActive }
        let player = engine.player.currentItem
        let seekable = player?.seekableTimeRanges.map(\.timeRangeValue)
            .map { "\($0.start.seconds)+\($0.duration.seconds)" } ?? []
        print("Timeline \(item): route \(engine.route?.rawValue ?? "nil"), state \(engine.state), "
              + "duration \(player.map { $0.duration.seconds } ?? .nan), seekable \(seekable), "
              + "timeline \(String(describing: engine.timeline()))")
        let timeline = try #require(engine.timeline())
        #expect(!timeline.isLive)
        #expect(timeline.range.upperBound > 2 * 3_600 && timeline.range.upperBound < 3 * 3_600)
        for target in [600.0, 3_000.0] {
            engine.seek(toPosition: target)
            #expect(engine.timeline().map { abs($0.position - target) < 0.01 } == true, "reports the target at once")
            try await waitUntil(seconds: 30) { engine.currentTime > target + 2 }
            let position = engine.timeline()?.position ?? 0
            print("Timeline \(item): after seek to \(target): position \(position), state \(engine.state), "
                  + "drift \(engine.follower?.makeSnapshot().drift.map { "\($0)" } ?? "-")")
            #expect(position > target + 1 && position < target + 15, "plays on from \(target)")
            #expect(engine.state == .playing)
            if let follower = engine.follower {
                try await waitUntil(seconds: 10) { follower.makeSnapshot().drift != nil }
                #expect(abs(follower.makeSnapshot().drift ?? 1) <= SplitAudioSync.driftTolerance, "audio follows")
            }
        }
        engine.pause()
        engine.seek(toPosition: 1_200)
        try await waitUntil(seconds: 20) { abs(engine.currentTime - 1_200) < 1 }
        try await Task.sleep(for: .seconds(1))
        #expect(abs(engine.currentTime - 1_200) < 1, "a paused seek moves without playing")
        #expect(engine.state == .paused)
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
