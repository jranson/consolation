import Foundation
import Testing
@testable import PlaybackKit

struct HLSMultivariantRepairTests {
    private let origin = "https://media.example.com/vod/title/"
    private var playlistURL: URL { URL(string: origin + "hls.m3u8")! }

    /// A real-world multivariant playlist as served.
    private let samplePlaylist = """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_A1",NAME="audio_1",DEFAULT=YES,URI="media_1.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=9690589,RESOLUTION=3832x1600,CODECS="hvc1,mp4a.40.2",AUDIO="group_A1"
        media_0.m3u8

        """

    private var repairedSamplePlaylist: String {
        """
        #EXTM3U
        #EXT-X-VERSION:7
        #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="group_A1",NAME="audio_1",DEFAULT=YES,URI="\(origin)media_1.m3u8"
        #EXT-X-STREAM-INF:BANDWIDTH=9690589,RESOLUTION=3832x1600,CODECS="hvc1.2.4.L150.90,mp4a.40.2",\
        AUDIO="group_A1",VIDEO-RANGE=PQ,FRAME-RATE=23.976
        \(origin)media_0.m3u8

        """
    }

    private var sampleVideoProbe: MediaTrackInfo? {
        var track = ISOInitSegment.tracks(in: SampleInitSegmentFixtures.video).first
        track?.frameRate = 24_000.0 / 1_001.0
        return track
    }

    @Test func parsesTheSamplePlaylist() throws {
        let playlist = try #require(HLSMultivariantPlaylist(text: samplePlaylist))
        #expect(playlist.isMultivariant)
        #expect(playlist.variants.count == 1)
        #expect(playlist.variants[0].uri == "media_0.m3u8")
        #expect(playlist.variants[0].attributes["CODECS"] == "hvc1,mp4a.40.2")
        #expect(playlist.variants[0].attributes["BANDWIDTH"] == "9690589")
        #expect(playlist.defaultAudioRendition(group: "group_A1")?["URI"] == "media_1.m3u8")
        #expect(HLSMultivariantRepair.needsRepair(playlist))
    }

    @Test func rewritesTheSamplePlaylist() throws {
        let playlist = try #require(HLSMultivariantPlaylist(text: samplePlaylist))
        let rewritten = HLSMultivariantRepair.rewrite(playlist, baseURL: playlistURL,
                                                      probe: HLSRepairProbe(video: sampleVideoProbe, audio: nil))
        #expect(rewritten == repairedSamplePlaylist)
        let reparsed = try #require(HLSMultivariantPlaylist(text: rewritten))
        #expect(!HLSMultivariantRepair.needsRepair(reparsed))
    }

    @Test func preparesTheSamplePlaylistFromProbes() async throws {
        let mediaPlaylist = """
            #EXTM3U
            #EXT-X-VERSION:6
            #EXT-X-TARGETDURATION:16
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-MAP:URI="init-0.mp4"
            #EXTINF:10.009000,
            #EXT-X-PROGRAM-DATE-TIME:2026-10-06T03:37:58.000+0100
            segment-0-00001.m4s
            """
        let fetcher = FakeMediaFetcher([
            origin + "hls.m3u8": Data(samplePlaylist.utf8),
            origin + "media_0.m3u8": Data(mediaPlaylist.utf8),
            origin + "init-0.mp4": SampleInitSegmentFixtures.video,
            origin + "segment-0-00001.m4s": Data(Box.fragment(durations: [984, 1_018, 1_008, 994, 1_001, 1_001]))
        ])
        let presentation = try await HLSMultivariantRepair.prepare(url: playlistURL, fetcher: fetcher, force: false)
        #expect(presentation?.multivariantPlaylist == repairedSamplePlaylist)
        #expect(presentation?.mediaPlaylists.isEmpty == true)
        #expect(presentation?.streamInfo.videoCodec == "HEVC")
        #expect(presentation?.streamInfo.audioCodec == "AAC")
        #expect(fetcher.requests == [origin + "hls.m3u8", origin + "media_0.m3u8", origin + "init-0.mp4",
                                     origin + "segment-0-00001.m4s"])
    }

    @Test func leavesCompletePlaylistsAndMediaPlaylistsAlone() async throws {
        let complete = """
            #EXTM3U
            #EXT-X-STREAM-INF:BANDWIDTH=5000000,RESOLUTION=1920x1080,CODECS="avc1.640028,mp4a.40.2",\
            VIDEO-RANGE=SDR,FRAME-RATE=29.970
            v.m3u8
            """
        let media = "#EXTM3U\n#EXT-X-TARGETDURATION:6\n#EXTINF:6,\nseg1.ts\n#EXT-X-ENDLIST\n"
        let fetcher = FakeMediaFetcher([origin + "complete.m3u8": Data(complete.utf8),
                                        origin + "media.m3u8": Data(media.utf8)])
        let completeURL = URL(string: origin + "complete.m3u8")!
        #expect(try await HLSMultivariantRepair.prepare(url: completeURL, fetcher: fetcher, force: false) == nil)
        let mediaURL = URL(string: origin + "media.m3u8")!
        #expect(try await HLSMultivariantRepair.prepare(url: mediaURL, fetcher: fetcher, force: true) == nil)
        #expect(fetcher.requests.count == 2)
        let notAPlaylist = FakeMediaFetcher([origin + "x.m3u8": Data("<html></html>".utf8)])
        let htmlURL = URL(string: origin + "x.m3u8")!
        #expect(try await HLSMultivariantRepair.prepare(url: htmlURL, fetcher: notAPlaylist, force: true) == nil)
    }

    @Test func returnsNilWhenProbingFindsNothing() async throws {
        let fetcher = FakeMediaFetcher([origin + "hls.m3u8": Data(samplePlaylist.utf8)])
        #expect(try await HLSMultivariantRepair.prepare(url: playlistURL, fetcher: fetcher, force: false) == nil)
        await #expect(throws: PlaybackError.self) {
            try await HLSMultivariantRepair.prepare(url: URL(string: origin + "missing.m3u8")!, fetcher: fetcher,
                                                    force: false)
        }
    }

    @Test func absolutizesEveryURIAndRepairsOtherVariantsConservatively() throws {
        let text = """
            #EXTM3U
            #EXT-X-SESSION-KEY:METHOD=AES-128,URI="keys/k1"
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="a",NAME="English",DEFAULT=YES,URI="https://cdn2.example.org/a.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160,CODECS="hvc1,mp4a",AUDIO="a"
            4k/index.m3u8?sig=1
            #EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,CODECS="hvc1,mp4a",AUDIO="a"
            ../hd/index.m3u8
            #EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,CODECS="hvc1",URI="iframes.m3u8"
            """
        let playlist = try #require(HLSMultivariantPlaylist(text: text))
        var audio = MediaTrackInfo(kind: .audio, sampleEntry: "mp4a", codecs: "mp4a.40.2")
        audio.audioChannels = 2
        let base = URL(string: "https://cdn.example.com/show/main.m3u8?token=abc")!
        let rewritten = HLSMultivariantRepair.rewrite(playlist, baseURL: base,
                                                      probe: HLSRepairProbe(video: sampleVideoProbe, audio: audio))
        let lines = rewritten.split(separator: "\n").map(String.init)
        #expect(lines[1] == "#EXT-X-SESSION-KEY:METHOD=AES-128,URI=\"https://cdn.example.com/show/keys/k1\"")
        #expect(lines[2].hasSuffix("URI=\"https://cdn2.example.org/a.m3u8\""))
        #expect(lines[3] == "#EXT-X-STREAM-INF:BANDWIDTH=9000000,RESOLUTION=3840x2160,"
                + "CODECS=\"hvc1.2.4.L150.90,mp4a.40.2\",AUDIO=\"a\",VIDEO-RANGE=PQ,FRAME-RATE=23.976")
        #expect(lines[4] == "https://cdn.example.com/show/4k/index.m3u8?sig=1")
        #expect(lines[5] == "#EXT-X-STREAM-INF:BANDWIDTH=3000000,RESOLUTION=1920x1080,"
                + "CODECS=\"hvc1,mp4a.40.2\",AUDIO=\"a\",VIDEO-RANGE=PQ,FRAME-RATE=23.976")
        #expect(lines[6] == "https://cdn.example.com/hd/index.m3u8")
        #expect(lines[7] == "#EXT-X-I-FRAME-STREAM-INF:BANDWIDTH=100000,CODECS=\"hvc1\","
                + "URI=\"https://cdn.example.com/show/iframes.m3u8\"")
    }

    @Test func recognisesAVPlayerRejections() {
        let rejection = NSError(domain: "AVFoundationErrorDomain", code: -11_800, userInfo: [
            NSUnderlyingErrorKey: NSError(domain: "CoreMediaErrorDomain", code: -12_927)
        ])
        #expect(HLSMultivariantRepair.isRepairTrigger(rejection))
        #expect(HLSMultivariantRepair.isRepairTrigger(NSError(domain: "CoreMediaErrorDomain", code: -12_646)))
        #expect(HLSMultivariantRepair.isRepairTrigger(NSError(domain: "CoreMediaErrorDomain", code: -1_002)))
        #expect(!HLSMultivariantRepair.isRepairTrigger(NSError(domain: NSURLErrorDomain, code: -1_009)))
        #expect(!HLSMultivariantRepair.isRepairTrigger(NSError(domain: "AVFoundationErrorDomain", code: -11_800)))
    }

    @Test func parsesAttributeLists() {
        var list = HLSAttributeList(parsing: #"BANDWIDTH=1,CODECS="avc1.64001F,mp4a.40.2",RESOLUTION=640x360,X="a=b""#)
        #expect(list.attributes.map(\.name) == ["BANDWIDTH", "CODECS", "RESOLUTION", "X"])
        #expect(list["CODECS"] == "avc1.64001F,mp4a.40.2")
        #expect(list["X"] == "a=b")
        #expect(list["MISSING"] == nil)
        list.set("BANDWIDTH", rawValue: "2")
        list.set("FRAME-RATE", rawValue: "25.000")
        let expected = #"BANDWIDTH=2,CODECS="avc1.64001F,mp4a.40.2",RESOLUTION=640x360,X="a=b",FRAME-RATE=25.000"#
        #expect(list.text == expected)
        #expect(HLSAttributeList(parsing: #"URI="unterminated,BANDWIDTH=1"#).attributes.count == 1)
        #expect(HLSAttributeList(parsing: "no attributes here").attributes.isEmpty)
    }

    @Test func findsMediaPlaylistReferences() {
        let text = """
            #EXTM3U
            #EXT-X-MAP:URI="init.mp4",BYTERANGE="720@0"
            #EXT-X-BYTERANGE:50000@720
            #EXTINF:6,
            media.mp4
            #EXTINF:6,
            media.mp4
            """
        let references = HLSMediaPlaylistReferences(text: text, baseURL: URL(string: "https://example.com/a/v.m3u8")!)
        #expect(references.initURL?.absoluteString == "https://example.com/a/init.mp4")
        #expect(references.initRange == 0...719)
        #expect(references.firstSegmentURL?.absoluteString == "https://example.com/a/media.mp4")
        #expect(references.firstSegmentRange == 720...50_719)
        #expect(HLSMediaPlaylistReferences.byteRange("") == nil)
        #expect(HLSMediaPlaylistReferences.byteRange("10") == 0...9)
        #expect(HLSMediaPlaylistReferences.byteRange("0@5") == nil)
        #expect(HLSMediaPlaylistReferences.byteRange("10@\(Int.max)") == nil)
        #expect(HLSMediaPlaylistReferences.byteRange("x@y") == nil)
    }
}
