//
//  PlayerStatsTests.swift
//  ConsolationTests
//
//  The player's lines for the Video Stats overlay: codecs, audio format, container and protocol.
//

import Foundation
import PlaybackKit
import Testing
@testable import Consolation

struct PlayerStatsTests {
    @Test func tunerStreamNamesCodecsContainerAndProtocol() {
        let info = PlaybackStreamInfo(videoCodec: "MPEG-2", audioCodec: "AC-3", width: 1_920, height: 1_080,
                                      frameRate: 29.97, isInterlaced: true, audioChannels: 6, audioLanguage: "eng",
                                      isLive: true, container: "MPEG-TS")
        let items = PlayerStats.streamItems(info: info, delivery: PlayerStats.Delivery(text: "HTTP stream (tuner)"))
        #expect(items == ["Video: MPEG-2 1920x1080 @ 29.97i", "Audio: AC-3 5.1 eng", "Container: MPEG-TS",
                          "Protocol: HTTP stream (tuner)"])
    }

    @Test func unsupportedAudioIsNamedAndAnUnknownContainerIsLeftOut() {
        let info = PlaybackStreamInfo(videoCodec: "HEVC", unsupportedAudioCodec: "AC-4")
        #expect(PlayerStats.streamItems(info: info, delivery: nil) == ["Video: HEVC —", "Audio: AC-4 (unsupported)"])
    }

    @Test func directHLSAdmitsItsSegmentFormatIsUnknown() throws {
        let url = try #require(URL(string: "https://example.com/live/master.m3u8?token=secret"))
        let delivery = PlayerStats.delivery(kind: .hls, url: url, route: .direct)
        #expect(delivery.text == "HLS/HTTPS")
        let items = PlayerStats.streamItems(info: PlaybackStreamInfo(), delivery: delivery)
        #expect(items.contains("Container: TS or fMP4"))
        #expect(!items.joined().contains("secret"))
    }

    @Test func protocolsByInput() throws {
        let remote = try #require(URL(string: "http://example.com/video.mp4"))
        let local = URL(fileURLWithPath: "/tmp/video.mkv")
        #expect(PlayerStats.delivery(kind: .dash, url: remote, route: .translatedDASH).text == "DASH/HTTP (as HLS)")
        #expect(PlayerStats.delivery(kind: .file, url: remote, route: .direct).text == "HTTP progressive")
        #expect(PlayerStats.delivery(kind: .hls, url: remote, route: .repairedMultivariant).text
            == "HLS/HTTP (repaired)")
        #expect(PlayerStats.byteStream(url: local, isSeekable: true).text == "Local file")
        #expect(PlayerStats.byteStream(url: remote, isSeekable: true).text == "HTTP ranges")
        #expect(PlayerStats.byteStream(url: remote, isSeekable: false).text == "HTTP stream")
    }

    @Test func liveDiagnosticsStayShort() {
        var diagnostics = PlaybackDiagnostics()
        diagnostics.bytesPerSecond = 1_500_000
        diagnostics.framesDropped = 2
        diagnostics.secondsBehindLive = 1.25
        #expect(PlayerStats.diagnosticItems(diagnostics, isLive: true)
            == ["Bitrate: 12.0 Mbps", "Buffer: A 0.0s V 0.0s", "Drops: 2", "Behind: 1.2s"])
    }

    @Test func channelLayouts() {
        #expect([1, 2, 6, 8, 4].map(PlayerStats.channelLayout) == ["Mono", "Stereo", "5.1", "7.1", "4 ch"])
    }
}
