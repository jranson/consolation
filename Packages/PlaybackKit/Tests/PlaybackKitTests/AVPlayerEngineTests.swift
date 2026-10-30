import AVFoundation
import Foundation
import Testing
@testable import PlaybackKit

@MainActor
struct AVPlayerEngineTests {
    private let remote = URL(string: "https://media.example.com/vod/title/hls.m3u8")!

    @Test func startsIdleWithAnAspectFitLayer() throws {
        let engine = AVPlayerEngine(url: remote, kind: .hls)
        #expect(engine.state == .idle)
        #expect(engine.route == nil)
        #expect(engine.streamInfo == PlaybackStreamInfo())
        let layer = try #require(engine.displayLayer as? AVPlayerLayer)
        #expect(layer === engine.playerLayer)
        #expect(layer.videoGravity == .resizeAspect)
        #expect(layer.player === engine.player)
        #expect(engine.currentTime == 0)
    }

    @Test func mutesThePlayer() {
        let engine = AVPlayerEngine(url: remote, kind: .file)
        engine.isMuted = true
        #expect(engine.player.isMuted)
        engine.isMuted = false
        #expect(!engine.player.isMuted)
    }

    @Test func stopIsFinalAndControlsNeedAStart() {
        let engine = AVPlayerEngine(url: remote, kind: .dash)
        engine.pause()
        engine.resume()
        #expect(engine.state == .idle)
        engine.stop()
        engine.start()
        #expect(engine.state == .idle)
        #expect(engine.player.currentItem == nil)
    }

    @Test func stopDuringConnectingReleasesEverything() {
        let engine = AVPlayerEngine(url: URL(string: "https://media.invalid/never.mpd")!, kind: .dash)
        engine.start()
        #expect(engine.state == .connecting)
        engine.start()
        #expect(engine.state == .connecting)
        engine.pause()
        #expect(engine.state == .paused)
        engine.stop()
        #expect(engine.state == .idle)
        #expect(engine.player.currentItem == nil)
    }

    @Test func reportsUnplayableLocalFiles() async throws {
        let file = FileManager.default.temporaryDirectory.appending(path: "PlaybackKit-\(UUID().uuidString).mp4")
        try Data(repeating: 0x5A, count: 4_096).write(to: file)
        defer { try? FileManager.default.removeItem(at: file) }
        let engine = AVPlayerEngine(url: file, kind: .file)
        engine.isMuted = true
        engine.start()
        let deadline = Date().addingTimeInterval(15)
        while Date() < deadline, engine.state.isActive {
            try await Task.sleep(for: .milliseconds(50))
        }
        guard case .failed(let error) = engine.state else {
            Issue.record("Expected a failure, got \(engine.state)")
            return
        }
        #expect(engine.route == .direct)
        #expect(error.domain != nil)
        #expect(error.code != nil)
        #expect(error.kind != .network)
        engine.stop()
    }

    @Test func mapsErrorsKeepingTheInnermostCode() {
        let rejection = NSError(domain: "AVFoundationErrorDomain", code: -11_800, userInfo: [
            NSLocalizedDescriptionKey: "The operation could not be completed",
            NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12_927)
        ])
        let mapped = PlaybackErrorMapping.playbackError(from: rejection)
        #expect(mapped.domain == "CoreMediaErrorDomain")
        #expect(mapped.code == -12_927)
        #expect(mapped.kind == .source)
        #expect(mapped.title == "The stream's playlist was rejected")
        #expect(mapped.detail.hasPrefix("AVFoundationErrorDomain -11800 / CoreMediaErrorDomain -12927."))

        let offline = PlaybackErrorMapping.playbackError(from: URLError(.notConnectedToInternet))
        #expect(offline.kind == .network)
        #expect(offline.code == NSURLErrorNotConnectedToInternet)
        #expect(PlaybackErrorMapping.playbackError(from: URLError(.cancelled)).kind == .cancelled)
        let unknownFormat = NSError(domain: "AVFoundationErrorDomain", code: -11_828)
        #expect(PlaybackErrorMapping.playbackError(from: unknownFormat).kind == .unsupportedFormat)
        let decode = NSError(domain: "AVFoundationErrorDomain", code: -11_821)
        #expect(PlaybackErrorMapping.playbackError(from: decode).kind == .decoder)
        #expect(PlaybackErrorMapping.playbackError(from: nil).kind == .source)
        let typed = PlaybackError(kind: .renderer, title: "Kept")
        #expect(PlaybackErrorMapping.playbackError(from: typed) == typed)
        let manifest = PlaybackErrorMapping.playbackError(from: DASHManifestError.unsupported("dynamic MPD"))
        #expect(manifest.kind == .unsupportedFormat)
        #expect(manifest.domain == PlaybackErrorMapping.manifestDomain)
    }

    @Test func neverKeepsQueryStringsInDetails() {
        let leaky = NSError(domain: NSURLErrorDomain, code: -1_100, userInfo: [
            NSLocalizedDescriptionKey: "Failed https://cdn.example.com/a/b.m3u8?token=SECRET&x=1 and "
                + "http://h.example.com/p#frag-SECRET plus custom-hls://abc/x.m3u8?k=SECRET."
        ])
        let detail = PlaybackErrorMapping.playbackError(from: leaky).detail
        #expect(!detail.contains("SECRET"))
        #expect(detail.contains("https://cdn.example.com/a/b.m3u8 and http://h.example.com/p plus custom-hls://abc/x.m3u8"))
    }

    @Test func playlistLoaderServesOnlyItsOwnURLs() throws {
        let loader = PlaylistResourceLoader(scheme: "Example-HLS")
        let presentation = HLSPresentation(multivariantPlaylist: "#EXTM3U\n", mediaPlaylists: ["video-0.m3u8": "#V\n"],
                                           streamInfo: PlaybackStreamInfo())
        loader.publish(presentation)
        let entry = try #require(loader.url(for: HLSPresentation.multivariantName))
        #expect(entry.scheme == "example-hls")
        #expect(entry.lastPathComponent == HLSPresentation.multivariantName)
        #expect(loader.playlistData(for: entry) == Data("#EXTM3U\n".utf8))
        let media = try #require(URL(string: "video-0.m3u8", relativeTo: entry)?.absoluteURL)
        #expect(loader.playlistData(for: media) == Data("#V\n".utf8))
        #expect(loader.playlistData(for: URL(string: "example-hls://someone-else/video-0.m3u8")!) == nil)
        #expect(loader.playlistData(for: URL(string: "https://\(loader.host)/video-0.m3u8")!) == nil)
        loader.removeAll()
        #expect(loader.playlistData(for: entry) == nil)
        #expect(loader.answeredRequests == 0)
    }
}
