//
//  HostedVideoPlayerTests.swift
//  ConsolationTests
//
//  YouTube links play in YouTube's embed, never an engine: playing at once, one window at a time,
//  stopping the engine player first, the history entry once it plays, and what the embed keeps and opens. No views, no
//  network (the embed's web view is never made).
//

import Foundation
import MediaSourceKit
import Testing
import YouTubePlayerKit
@testable import Consolation

@MainActor
struct HostedVideoPlayerTests {
    static let watchURL = URL(string: "https://www.youtube.com/watch?v=aBcDeFgHi_-&t=42")!

    @Test func otherURLsAreLeftToTheEngines() {
        let player = HostedVideoPlayer()
        #expect(!player.play(URL(string: "https://media.home.example/movie.mp4")!))
        #expect(!player.play(URL(string: "https://www.youtube.com.example.net/watch?v=aBcDeFgHi_-")!))
        #expect(!player.isActive)
    }

    @Test func aVideoPlaysAtOnceAndStopsTheEnginesFirst() throws {
        let player = HostedVideoPlayer()
        var stops = 0
        player.stopsEngines = { stops += 1 }
        #expect(player.play(Self.watchURL))
        let video = try #require(player.current)
        #expect(video.link == HostedVideoLink(videoID: "aBcDeFgHi_-", startSeconds: 42))
        #expect(stops == 1)
        player.play(HostedVideo(link: HostedVideoLink(videoID: "zYxWvUtSrQp"), title: "A bookmark"))
        #expect(player.current?.title == "A bookmark")
        #expect(stops == 2)
        player.stop()
        #expect(!player.isActive)
    }

    @Test func oneWindowShowsTheEmbedAndLeavingItStopsIt() {
        let player = HostedVideoPlayer()
        let first = UUID()
        let second = UUID()
        player.play(Self.watchURL)
        player.claim(for: first)
        player.claim(for: second)
        #expect(player.window == first)
        // Another window leaving Now Playing changes nothing.
        player.windowLeft(second)
        #expect(player.isActive)
        player.windowLeft(first)
        #expect(!player.isActive)
        #expect(player.window == nil)
    }

    @Test func aQuickPlayURLJoinsTheHistoryOnceItPlays() throws {
        let player = HostedVideoPlayer()
        var recorded: [URL] = []
        player.recordsHistory = { recorded.append($0) }
        player.play(Self.watchURL)
        #expect(recorded.isEmpty)
        let video = try #require(player.current)
        player.didBecomeReady(video)
        #expect(recorded == [Self.watchURL])
        // A bookmark has no Quick Play URL; a stale player's ready is ignored.
        player.play(HostedVideo(link: HostedVideoLink(videoID: "zYxWvUtSrQp")))
        player.didBecomeReady(video)
        player.didBecomeReady(try #require(player.current))
        #expect(recorded == [Self.watchURL])
        player.stop()
    }

    @Test func theSessionHandsYouTubeLinksToTheEmbed() {
        let player = HostedVideoPlayer()
        let session = PlayerSession(preferences: PlaybackPreferences(defaults: TestDefaults.make())) { _, _, _ in
            FakeEngine()
        }
        session.hostedVideos = player
        var stops = 0
        player.stopsEngines = { stops += 1 }
        session.play(Self.watchURL)
        #expect(player.isActive)
        #expect(!session.isActive)
        #expect(stops == 1)
        player.stop()
    }

    @Test func theEmbedKeepsNoDataAndOpensOnlyYouTubePages() {
        let player = YouTubeEmbedClient.player(for: HostedVideoLink(videoID: "aBcDeFgHi_-", startSeconds: 42))
        #expect(player.configuration.useNonPersistentWebsiteDataStore)
        #expect(player.parameters.startTime?.value == 42)
        #expect(player.source == .video(id: "aBcDeFgHi_-"))
        let opens = ["https://www.youtube.com/watch?v=aBcDeFgHi_-", "https://youtu.be/aBcDeFgHi_-",
                     "https://m.youtube.com/@SomeChannel"]
        let drops = ["https://googleads.g.doubleclick.net/pagead/x", "https://www.youtube.com.example.net/",
                     "http://www.youtube.com/watch?v=aBcDeFgHi_-", "https://notyoutube.com/", "youtube://watch/x"]
        for text in opens { #expect(YouTubeEmbedClient.opensInBrowser(URL(string: text)!), "\(text)") }
        for text in drops { #expect(!YouTubeEmbedClient.opensInBrowser(URL(string: text)!), "\(text)") }
    }

    @Test func aboutShowsTheShippedMITNotice() throws {
        let file = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent()
            .appending(path: "LICENSES/MIT-YouTubePlayerKit.txt")
        let shipped = try String(contentsOf: file, encoding: .utf8)
        #expect(YouTubeEmbedClient.licenseText == shipped.trimmingCharacters(in: .newlines))
    }
}
