import Foundation
import Testing
@testable import PlaybackKit

struct URLKindDetectorTests {
    private func kind(_ string: String) -> URLKind {
        URLKindDetector.detect(URL(string: string)!)
    }

    @Test func classifiesByExtension() {
        #expect(kind("https://example.com/vod/dash.mpd") == .dash)
        #expect(kind("https://example.com/vod/DASH.MPD?token=1") == .dash)
        #expect(kind("https://example.com/live/index.m3u8") == .hls)
        #expect(kind("https://example.com/live/list.m3u") == .hls)
        #expect(kind("http://example.com/rec/show.ts") == .transportStream)
        #expect(kind("http://example.com/rec/show.m2ts") == .transportStream)
        #expect(kind("file:///Users/someone/Movies/clip.MTS") == .transportStream)
        #expect(kind("https://example.com/a/movie.mp4") == .progressive)
        #expect(kind("https://example.com/a/movie.mov#t=10") == .progressive)
        #expect(kind("https://example.com/a/movie.m4v") == .progressive)
        #expect(kind("https://example.com/a/my%20movie.mp4") == .progressive)
    }

    @Test func classifiesByQuery() {
        #expect(kind("https://example.com/stream?format=m3u8") == .hls)
        #expect(kind("https://example.com/stream?output=ts&id=4") == .transportStream)
        #expect(kind("https://example.com/play?type=mpd") == .dash)
        #expect(kind("https://example.com/play?ext=.mp4") == .progressive)
        #expect(kind("https://example.com/video.ism/manifest(format=m3u8-aapl)") == .hls)
        #expect(kind("https://example.com/video.ism/manifest(format=mpd-time-csf)") == .dash)
        #expect(kind("https://example.com/stream?format=webm") == .unknown)
    }

    @Test func classifiesHDHomeRunStreams() {
        #expect(kind("http://192.0.2.10:5004/auto/v2.1") == .transportStream)
        #expect(kind("http://192.0.2.10:5004/auto/v7.1?duration=60") == .transportStream)
        #expect(kind("http://192.0.2.10:5004/tuner1/v9.1") == .transportStream)
        #expect(kind("http://192.0.2.10/tuner0/ch473000000") == .transportStream)
        #expect(kind("http://192.0.2.10/auto/v20.4") == .transportStream)
        #expect(kind("http://192.0.2.10/tuner/v2.1") == .unknown)
        #expect(kind("http://192.0.2.10/automobile/v2") == .unknown)
        #expect(kind("http://192.0.2.10/auto/info") == .unknown)
    }

    @Test func leavesTheRestUnknown() {
        #expect(kind("https://example.com/") == .unknown)
        #expect(kind("https://example.com/watch") == .unknown)
        #expect(kind("https://example.com/video.mkv") == .unknown)
        #expect(kind("https://example.com/archive.tar.gz") == .unknown)
    }

    @Test func mapsToAVPlayerInputKinds() {
        #expect(URLKind.dash.avPlayerInputKind == .dash)
        #expect(URLKind.hls.avPlayerInputKind == .hls)
        #expect(URLKind.progressive.avPlayerInputKind == .file)
        #expect(URLKind.transportStream.avPlayerInputKind == nil)
        #expect(URLKind.unknown.avPlayerInputKind == nil)
    }
}
