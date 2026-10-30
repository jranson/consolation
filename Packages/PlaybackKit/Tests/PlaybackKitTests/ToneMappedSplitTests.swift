//
//  ToneMappedSplitTests.swift
//  PlaybackKitTests
//
//  The tone-mapped split route: when to take it, which media playlists it plays, the audio sync decisions, the
//  HDR error mapping, and the engine's fallback after AVPlayer rejects an HDR-only multivariant playlist. No
//  network: the engine tests use URLs on a private scheme that nothing serves.
//

import AVFoundation
import Foundation
@testable import PlaybackKit
import Testing

struct ToneMappedSplitPlanTests {
    private let base = URL(string: "https://media.example.com/vod/title/hls.m3u8")!

    private func playlist(_ text: String) throws -> HLSMultivariantPlaylist {
        try #require(HLSMultivariantPlaylist(text: text))
    }

    private let hdrOnly = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="English",LANGUAGE="en",DEFAULT=NO,URI="audio/en.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="aud",NAME="Deutsch",LANGUAGE="de",DEFAULT=YES,URI="audio/de.m3u8"
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="other",NAME="Commentary",URI="audio/c.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=4000000,RESOLUTION=1920x800,CODECS="hvc1.2.4.L120.90,mp4a.40.2",\
        VIDEO-RANGE=PQ,FRAME-RATE=23.976,AUDIO="aud"
        video/1080.m3u8
        #EXT-X-STREAM-INF:BANDWIDTH=9700000,RESOLUTION=3832x1600,CODECS="hvc1.2.4.L150.90,mp4a.40.2",\
        VIDEO-RANGE=PQ,FRAME-RATE=23.976,AUDIO="aud"
        https://cdn.example.com/video/2160.m3u8
        """

    @Test func splitsOnlyHDROnlyPlaylistsOnDisplaysWithoutHDR() throws {
        let hdr = try playlist(hdrOnly)
        #expect(ToneMappedSplitPlan.isHDROnly(hdr))
        #expect(ToneMappedSplitPlan.shouldSplit(hdr, hdrEligible: false))
        #expect(!ToneMappedSplitPlan.shouldSplit(hdr, hdrEligible: true))

        let hlg = try playlist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=1280x720,VIDEO-RANGE=HLG\nv.m3u8\n")
        #expect(ToneMappedSplitPlan.shouldSplit(hlg, hdrEligible: false))

        let mixed = try playlist(hdrOnly + "\n#EXT-X-STREAM-INF:BANDWIDTH=2000000,RESOLUTION=1280x534,"
                                 + "CODECS=\"avc1.640020\",VIDEO-RANGE=SDR,AUDIO=\"aud\"\nvideo/sdr.m3u8\n")
        #expect(!ToneMappedSplitPlan.isHDROnly(mixed), "an SDR variant lets AVPlayer play the multivariant playlist")
        #expect(!ToneMappedSplitPlan.shouldSplit(mixed, hdrEligible: false))

        let undeclared = try playlist("#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=3832x1600\nv.m3u8\n")
        #expect(!ToneMappedSplitPlan.isHDROnly(undeclared), "no VIDEO-RANGE means SDR")

        let audioOnly = try playlist(
            "#EXTM3U\n#EXT-X-STREAM-INF:BANDWIDTH=1,CODECS=\"mp4a.40.2\",VIDEO-RANGE=PQ\na.m3u8\n")
        #expect(!ToneMappedSplitPlan.isHDROnly(audioOnly))
    }

    @Test func picksTheBestDecodableVariantAndTheDefaultAudio() throws {
        let hdr = try playlist(hdrOnly)
        let plan = try #require(ToneMappedSplitPlan(playlist: hdr, baseURL: base) { _ in true })
        #expect(plan.videoURL.absoluteString == "https://cdn.example.com/video/2160.m3u8")
        #expect(plan.videoRange == .perceptualQuantizer)
        #expect(plan.bandwidth == 9_700_000)
        #expect(plan.renditions.map(\.language) == ["en", "de"], "only the variant's own AUDIO group")
        #expect(plan.selectedAudio == 1)
        #expect(plan.selectedAudioURL?.absoluteString == "https://media.example.com/vod/title/audio/de.m3u8")

        let level150 = try #require(ToneMappedSplitPlan(playlist: hdr, baseURL: base) { !$0.contains("L150") })
        #expect(level150.videoURL.absoluteString == "https://media.example.com/vod/title/video/1080.m3u8")
        let none = try #require(ToneMappedSplitPlan(playlist: hdr, baseURL: base) { _ in false })
        #expect(none.bandwidth == 9_700_000, "nothing decodable: the best variant, and AVPlayer reports why")
    }

    @Test func playsVideoAloneWithoutAnAudioRendition() throws {
        let muxed = try playlist("""
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=3840x2160,CODECS="hvc1.2.4.L153.90,ec-3",VIDEO-RANGE=PQ
            uhd.m3u8
            """)
        let plan = try #require(ToneMappedSplitPlan(playlist: muxed, baseURL: base) { _ in true })
        #expect(plan.renditions.isEmpty)
        #expect(plan.selectedAudio == nil)
        #expect(plan.selectedAudioURL == nil)
        #expect(plan.videoURL.absoluteString == "https://media.example.com/vod/title/uhd.m3u8")
        let firstWhenNoDefault = try playlist("""
            #EXTM3U
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="One",URI="one.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Two",URI="two.m3u8"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="Muxed",DEFAULT=YES
            #EXT-X-STREAM-INF:BANDWIDTH=1,RESOLUTION=640x360,VIDEO-RANGE=HLG,AUDIO="a"
            v.m3u8
            """)
        let first = try #require(ToneMappedSplitPlan(playlist: firstWhenNoDefault, baseURL: base) { _ in true })
        #expect(first.renditions.map(\.name) == ["One", "Two"])
        #expect(first.selectedAudio == 0)
    }

    @Test func plansTheTranslatedSampleDASH() throws {
        let manifest = try DASHManifest(data: Data(DASHSampleFixture.mpd.utf8),
                                        manifestURL: URL(string: DASHSampleFixture.manifestURLString)!)
        let translator = DASHToHLSTranslator(manifest: manifest)
        let selection = try translator.selection()
        let videoID = try #require(selection.videos.first?.id)
        var video = MediaTrackInfo(kind: .video, sampleEntry: "hvc1", codecs: "hvc1.2.4.L150.90")
        video.transferCharacteristics = 16
        video.frameRate = 24_000.0 / 1_001
        let presentation = try translator.translate(selection: selection, probes: [videoID: video])
        let multivariant = try playlist(presentation.multivariantPlaylist)
        #expect(ToneMappedSplitPlan.shouldSplit(multivariant, hdrEligible: false))
        let entry = URL(string: "example-hls://loader-host/\(HLSPresentation.multivariantName)")!
        let plan = try #require(ToneMappedSplitPlan(playlist: multivariant, baseURL: entry) { _ in true })
        #expect(plan.videoURL.absoluteString == "example-hls://loader-host/video-0.m3u8")
        #expect(plan.selectedAudioURL?.absoluteString == "example-hls://loader-host/audio-0.m3u8")
        #expect(presentation.mediaPlaylists["video-0.m3u8"] != nil)
        #expect(presentation.mediaPlaylists["audio-0.m3u8"] != nil)
    }
}

struct SplitAudioSyncTests {
    private func snapshot(wantsPlay: Bool = true, needsStart: Bool = false, isSyncing: Bool = false,
                          video: SplitAudioSync.PlayerStatus = .playing, audio: SplitAudioSync.PlayerStatus = .playing,
                          keepUp: Bool = true, hasData: Bool = true, audioReady: Bool = true, audioEnded: Bool = false,
                          drift: Double? = 0, sinceSync: Double? = 5, waiting: Double = 0) -> SplitAudioSync.Snapshot {
        SplitAudioSync.Snapshot(wantsPlay: wantsPlay, needsStart: needsStart, isSyncing: isSyncing, video: video,
                                audio: audio, videoLikelyToKeepUp: keepUp, videoHasData: hasData,
                                audioReady: audioReady, audioEnded: audioEnded, drift: drift,
                                secondsSinceSync: sinceSync, secondsWaiting: waiting)
    }

    @Test func startsBothOnceBothAreReady() {
        let first = snapshot(needsStart: true, video: .paused, audio: .paused, drift: nil, sinceSync: nil)
        #expect(SplitAudioSync.decide(first) == .startBoth)
        var notBuffered = first
        notBuffered.videoLikelyToKeepUp = false
        #expect(SplitAudioSync.decide(notBuffered) == .none)
        notBuffered.secondsWaiting = SplitAudioSync.restartTimeoutSeconds
        #expect(SplitAudioSync.decide(notBuffered) == .startBoth, "a slow buffer starts after the timeout")
        notBuffered.videoHasData = false
        #expect(SplitAudioSync.decide(notBuffered) == .none, "but never with an empty buffer")
        var audioLoading = first
        audioLoading.audioReady = false
        #expect(SplitAudioSync.decide(audioLoading) == .none)
        var syncing = first
        syncing.isSyncing = true
        #expect(SplitAudioSync.decide(syncing) == .none)
    }

    @Test func pausesTheAudioWhileTheVideoStallsAndRestartsBoth() {
        // The stall notification sets needsStart; the audio stops until the video can keep up again.
        let stalled = snapshot(needsStart: true, video: .paused, audio: .playing, keepUp: false, drift: nil)
        #expect(SplitAudioSync.decide(stalled) == .pauseAudio)
        var quiet = stalled
        quiet.audio = .paused
        #expect(SplitAudioSync.decide(quiet) == .none)
        quiet.videoLikelyToKeepUp = true
        #expect(SplitAudioSync.decide(quiet) == .startBoth)
        // A video the system paused (Picture in Picture controls) or that waits for data: the audio follows.
        #expect(SplitAudioSync.decide(snapshot(video: .paused, drift: nil)) == .pauseAudio)
        #expect(SplitAudioSync.decide(snapshot(video: .waiting, drift: nil)) == .pauseAudio)
        #expect(SplitAudioSync.decide(snapshot(video: .paused, audio: .paused, drift: nil)) == .none)
    }

    @Test func followsTheUsersPause() {
        #expect(SplitAudioSync.decide(snapshot(wantsPlay: false)) == .pauseAudio)
        #expect(SplitAudioSync.decide(snapshot(wantsPlay: false, needsStart: true, video: .paused,
                                               audio: .paused)) == .none)
    }

    @Test func rejoinsAudioThatStoppedOrDrifted() {
        #expect(SplitAudioSync.decide(snapshot(audio: .paused, drift: nil)) == .joinAudio)
        #expect(SplitAudioSync.decide(snapshot(audio: .waiting, drift: nil)) == .joinAudio)
        #expect(SplitAudioSync.decide(snapshot(drift: 0.059)) == .none)
        #expect(SplitAudioSync.decide(snapshot(drift: -0.059)) == .none)
        #expect(SplitAudioSync.decide(snapshot(drift: 0.061)) == .joinAudio)
        #expect(SplitAudioSync.decide(snapshot(drift: -0.2)) == .joinAudio)
        #expect(SplitAudioSync.decide(snapshot(drift: 0.2, sinceSync: 0.5)) == .none, "settling after a sync")
        #expect(SplitAudioSync.decide(snapshot(drift: 0.2, sinceSync: nil)) == .joinAudio)
        #expect(SplitAudioSync.decide(snapshot(audio: .paused, audioEnded: true)) == .none, "audio ran out")
        #expect(SplitAudioSync.decide(snapshot(audio: .paused, audioReady: false)) == .none)
        #expect(SplitAudioSync.driftTolerance >= 0.04 && SplitAudioSync.driftTolerance <= 0.08)
    }

    @Test func computesStartAndJoinTimes() throws {
        let start = SplitAudioSync.startTimes(itemTime: 600, hostNow: 1_000, lead: 0.15)
        #expect(start.itemTime == 600)
        #expect(start.hostTime == 1_000.15)
        #expect(SplitAudioSync.joinTarget(videoTime: 100, rate: 1, lead: 0.5) == 100.5)
        #expect(SplitAudioSync.joinTarget(videoTime: 100, rate: 0, lead: 0.5) == 100)
        let host = try #require(SplitAudioSync.hostTime(reaching: 100.5, videoTime: 100.2, hostNow: 50, rate: 1))
        #expect(abs(host - 50.3) < 1e-9)
        let past = try #require(SplitAudioSync.hostTime(reaching: 100.5, videoTime: 100.7, hostNow: 50, rate: 1))
        #expect(abs(past - 49.8) < 1e-9, "a target already passed maps to a host time in the past")
        let double = try #require(SplitAudioSync.hostTime(reaching: 101, videoTime: 100, hostNow: 0, rate: 2))
        #expect(double == 0.5)
        #expect(SplitAudioSync.hostTime(reaching: 101, videoTime: 100, hostNow: 0, rate: 0) == nil)
        #expect(SplitAudioSync.drift(audioTime: 10.05, videoTime: 10) > 0.049)
    }
}

@MainActor
struct ToneMappedSplitEngineTests {
    private let hdrOnlyText = """
        #EXTM3U
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="en",LANGUAGE="en",DEFAULT=YES,URI="audio-0.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=9690589,RESOLUTION=3832x1600,CODECS="hvc1.2.4.L150.90,mp4a.40.2",\
        VIDEO-RANGE=PQ,FRAME-RATE=23.976,AUDIO="audio"
        video-0.m3u8
        """
    private let entry = URL(string: "playbackkit-test://nowhere/multivariant.m3u8")!
    private let hdrRejection = NSError(domain: "AVFoundationErrorDomain", code: -11_868, userInfo: [
        NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -17_223)
    ])

    @Test func mapsHDRRejections() {
        #expect(PlaybackErrorMapping.isHDRVariantRejection(hdrRejection))
        #expect(PlaybackErrorMapping.isHDRVariantRejection(NSError(domain: "CoreMediaErrorDomain", code: -17_223)))
        #expect(!PlaybackErrorMapping.isHDRVariantRejection(NSError(domain: "Other", code: -17_223)))
        #expect(!PlaybackErrorMapping.isHDRVariantRejection(URLError(.timedOut)))
        let error = PlaybackErrorMapping.hdrDisplayRequired(from: hdrRejection)
        #expect(error.title == "This HDR stream needs an HDR display")
        #expect(error.kind == .unsupportedFormat)
        #expect(error.code == -17_223)
        #expect(AVPlayerEngine.isToneMappingFailure(hdrRejection))
        #expect(!AVPlayerEngine.isToneMappingFailure(URLError(.notConnectedToInternet)))
    }

    @Test func resolvesTheInjectedEligibility() {
        let url = URL(string: "https://media.example.com/a.mpd")!
        let never = AVPlayerEngine(url: url, kind: .dash, configuration: .init(hdrEligibility: .ineligible))
        #expect(!never.isHDREligible)
        let always = AVPlayerEngine(url: url, kind: .dash, configuration: .init(hdrEligibility: .eligible))
        #expect(always.isHDREligible)
        #expect(AVPlayerEngine.Configuration().hdrEligibility == .system)
    }

    @Test func fallsBackToTheSplitWhenAVPlayerRejectsAnHDROnlyPlaylist() async throws {
        let engine = AVPlayerEngine(url: URL(string: "https://media.example.com/a.mpd")!, kind: .dash,
                                    configuration: .init(hdrEligibility: .eligible))
        engine.isMuted = true
        engine.volume = 0.5
        engine.knownMultivariant = (try #require(HLSMultivariantPlaylist(text: hdrOnlyText)), entry)
        engine.handleFailure(hdrRejection, token: engine.generation)
        #expect(engine.state == .connecting)
        // Nothing serves these URLs, so the split itself fails soon after; catch the follower while it exists.
        var follower: SplitAudioFollower?
        try await waitUntil {
            follower = follower ?? engine.follower
            return follower != nil || !engine.state.isActive
        }
        #expect(engine.route == .toneMappedSplit)
        #expect(engine.attemptedSplit)
        let played = (engine.player.currentItem?.asset as? AVURLAsset)?.url.lastPathComponent
        #expect(played != HLSPresentation.multivariantName)
        if let follower {
            #expect(follower.audioPlayer.isMuted, "the user's mute moves to the audio player")
            #expect(follower.audioPlayer.volume == 0.5)
            #expect((follower.audioItem.asset as? AVURLAsset)?.url.lastPathComponent == "audio-0.m3u8")
        }
        #expect(engine.displayLayer === engine.playerLayer)
        engine.stop()
        #expect(engine.follower == nil)
        #expect(engine.player.currentItem == nil)
        #expect(engine.player.automaticallyWaitsToMinimizeStalling, "stopping the split restores automatic waiting")
    }

    @Test func failsAsBeforeWhenThePlaylistHasSDRVideo() async throws {
        let sdr = hdrOnlyText.replacingOccurrences(of: "VIDEO-RANGE=PQ", with: "VIDEO-RANGE=SDR")
        let engine = AVPlayerEngine(url: URL(string: "https://media.example.com/a.mpd")!, kind: .dash,
                                    configuration: .init(hdrEligibility: .eligible))
        engine.knownMultivariant = (try #require(HLSMultivariantPlaylist(text: sdr)), entry)
        engine.handleFailure(hdrRejection, token: engine.generation)
        try await waitUntil { !engine.state.isActive }
        guard case .failed(let error) = engine.state else {
            Issue.record("Expected a failure, got \(engine.state)")
            return
        }
        #expect(error.code == -17_223)
        #expect(error.title != "This HDR stream needs an HDR display")
        #expect(engine.route != .toneMappedSplit)
        engine.stop()
    }

    private func waitUntil(_ condition: () -> Bool) async throws {
        let deadline = Date().addingTimeInterval(5)
        while Date() < deadline, !condition() {
            try await Task.sleep(for: .milliseconds(20))
        }
    }
}
