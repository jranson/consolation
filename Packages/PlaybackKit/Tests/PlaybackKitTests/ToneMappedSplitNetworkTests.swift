//
//  ToneMappedSplitNetworkTests.swift
//  PlaybackKitTests
//
//  Opt-in network test (never part of `make test` or `make build`): plays sample HDR10 DASH and HLS test streams with
//  the display forced to "not HDR-eligible", and checks that the engine takes the tone-mapped split, that both players
//  come up, that the video plays and decodes, and that the audio stays within the drift tolerance, before and after a
//  seek. `PLAYBACKKIT_HDR10_STREAMS` is the URL of a directory holding the HDR10 title as `dash.mpd` and `hls.m3u8`.
//  Run it in Packages/PlaybackKit with
//
//      PLAYBACKKIT_SPLIT_NETWORK=1 PLAYBACKKIT_HDR10_STREAMS=https://<host>/<path>/ \
//          swift test --filter ToneMappedSplitNetworkTests
//

import AVFoundation
import Foundation
@testable import PlaybackKit
import Testing

#if os(macOS)
@Suite(.serialized)
struct ToneMappedSplitNetworkTests {
    /// The directory of the HDR10 test streams, from `PLAYBACKKIT_HDR10_STREAMS`, ending in "/"; empty when unset.
    nonisolated static let base: String = {
        let value = ProcessInfo.processInfo.environment["PLAYBACKKIT_HDR10_STREAMS"] ?? ""
        return value.isEmpty || value.hasSuffix("/") ? value : value + "/"
    }()
    nonisolated static let isEnabled = ProcessInfo.processInfo.environment["PLAYBACKKIT_SPLIT_NETWORK"] == "1"
        && !base.isEmpty

    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(2)))
    func playsSampleDASHAsSplit() async throws {
        try await measure(URL(string: Self.base + "dash.mpd")!, kind: .dash, label: "DASH")
    }

    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(2)))
    func playsSampleHLSAsSplit() async throws {
        try await measure(URL(string: Self.base + "hls.m3u8")!, kind: .hls, label: "HLS")
    }

    /// The real decision: the display's own eligibility. An HDR-capable display keeps the multivariant playlist;
    /// one without HDR takes the split, at load time or (if AVPlayer still gets the playlist) after its rejection.
    @Test(.enabled(if: isEnabled), .timeLimit(.minutes(2)))
    func followsTheDisplay() async throws {
        let eligible = AVPlayer.eligibleForHDRPlayback
        let engine = AVPlayerEngine(url: URL(string: Self.base + "dash.mpd")!, kind: .dash)
        engine.isMuted = true
        defer { engine.stop() }
        engine.start()
        try await waitUntil(seconds: 30) { engine.state == .playing || !engine.state.isActive }
        let start = engine.currentTime
        try await Task.sleep(for: .seconds(4))
        print(String(format: "ToneMappedSplit system: eligibleForHDRPlayback %@, route %@, state %@, "
                     + "advanced %.2f s in 4 s",
                     "\(eligible)", engine.route?.rawValue ?? "nil", "\(engine.state)", engine.currentTime - start))
        #expect(engine.state == .playing)
        #expect(engine.route == (eligible ? .translatedDASH : .toneMappedSplit))
        #expect(engine.currentTime - start > 2.5)
    }

    private func measure(_ url: URL, kind: AVPlayerEngine.InputKind, label: String) async throws {
        let configuration = AVPlayerEngine.Configuration(hdrEligibility: .ineligible)
        let engine = AVPlayerEngine(url: url, kind: kind, configuration: configuration)
        engine.isMuted = true
        defer { engine.stop() }
        let started = Date()
        engine.start()
        try await waitUntil(seconds: 30) { engine.state == .playing || !engine.state.isActive }
        let startup = Date().timeIntervalSince(started)
        #expect(engine.state == .playing, "\(label): \(engine.state)")
        #expect(engine.route == .toneMappedSplit)
        let follower = try #require(engine.follower)
        #expect(engine.player.currentItem?.status == .readyToPlay)
        #expect(follower.audioItem.status == .readyToPlay)
        #expect(follower.audioPlayer.isMuted)

        let first = try await sample(engine, follower, seconds: 8)
        let frame = await engine.latestFrame()
        #expect(frame != nil, "the video decodes")
        let frameFacts = frame.map { "\(CVPixelBufferGetWidth($0))x\(CVPixelBufferGetHeight($0))" } ?? "none"

        // Run the audio 10% fast, so it drifts ahead while playing; the follower must notice and rejoin it.
        let nudgeStart = Date()
        follower.audioPlayer.rate = 1.1
        var nudged = 0.0
        try await waitUntil(seconds: 10) {
            nudged = max(nudged, follower.makeSnapshot().drift ?? 0)
            return follower.joinCount > 0 && follower.audioPlayer.rate == 1
                && abs(follower.makeSnapshot().drift ?? 1) <= SplitAudioSync.driftTolerance
        }
        let correction = Date().timeIntervalSince(nudgeStart)
        let corrected = follower.makeSnapshot().drift ?? .infinity
        #expect(follower.joinCount > 0)
        #expect(abs(corrected) <= SplitAudioSync.driftTolerance)

        engine.pause()
        try await Task.sleep(for: .seconds(1))
        #expect(engine.player.rate == 0 && follower.audioPlayer.rate == 0, "pause stops both players")
        engine.resume()
        try await waitUntil(seconds: 10) { engine.state == .playing && follower.makeSnapshot().drift != nil }
        let resumed = try await sample(engine, follower, seconds: 3)
        #expect(resumed.advance > 1.5, "the video plays after a resume")
        #expect(resumed.maxDrift <= SplitAudioSync.driftTolerance)

        engine.seek(to: 600)
        try await waitUntil(seconds: 20) { engine.currentTime > 600.5 && follower.makeSnapshot().drift != nil }
        let second = try await sample(engine, follower, seconds: 6)

        print(String(format: """
            ToneMappedSplit %@: playing after %.2f s; video advanced %.2f s in 8 s; drift after settling: max %.1f ms, \
            mean %.1f ms (%d samples); after seek to 600 s: advanced %.2f s in 6 s, max %.1f ms, mean %.1f ms; \
            starts %d, joins %d, stalls %d; frame %@; size %dx%d; drift peaked at %.0f ms, corrected to %.1f ms in \
            %.2f s; after pause and resume: max %.1f ms
            """, label, startup, first.advance, first.maxDrift * 1000, first.meanDrift * 1000, first.count,
                     second.advance, second.maxDrift * 1000, second.meanDrift * 1000, follower.startCount,
                     follower.joinCount, engine.stallCount, frameFacts, engine.streamInfo.width ?? 0,
                     engine.streamInfo.height ?? 0, nudged * 1000, corrected * 1000, correction,
                     resumed.maxDrift * 1000))
        #expect(first.advance > 5, "the video plays")
        #expect(second.advance > 3, "the video plays after a seek")
        #expect(first.maxDrift <= SplitAudioSync.driftTolerance)
        #expect(second.maxDrift <= SplitAudioSync.driftTolerance)
    }

    private struct Sample {
        var advance: Double
        var maxDrift: Double
        var meanDrift: Double
        var count: Int
    }

    /// Video advance over `seconds`, and the drift every 100 ms once a second has passed since the last sync.
    private func sample(_ engine: AVPlayerEngine, _ follower: SplitAudioFollower,
                        seconds: Double) async throws -> Sample {
        let start = engine.currentTime
        var drifts: [Double] = []
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            try await Task.sleep(for: .milliseconds(100))
            let snapshot = follower.makeSnapshot()
            if let drift = snapshot.drift, (snapshot.secondsSinceSync ?? 0) >= SplitAudioSync.settleSeconds {
                drifts.append(abs(drift))
            }
        }
        return Sample(advance: engine.currentTime - start, maxDrift: drifts.max() ?? .infinity,
                      meanDrift: drifts.isEmpty ? .infinity : drifts.reduce(0, +) / Double(drifts.count),
                      count: drifts.count)
    }

    private func waitUntil(seconds: Double, _ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(50))
        }
    }
}
#endif
