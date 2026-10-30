import Foundation
import Testing
@testable import PlaybackKit

struct DASHToHLSTranslatorTests {
    private let origin = "https://media.example.com/vod/title/"

    private func sampleTranslator() throws -> DASHToHLSTranslator {
        let manifest = try DASHManifest(data: Data(DASHSampleFixture.mpd.utf8),
                                        manifestURL: URL(string: DASHSampleFixture.manifestURLString)!)
        return DASHToHLSTranslator(manifest: manifest)
    }

    private var sampleProbes: [String: MediaTrackInfo] {
        var probes: [String: MediaTrackInfo] = [:]
        probes["0"] = ISOInitSegment.tracks(in: SampleInitSegmentFixtures.video).first
        probes["1"] = ISOInitSegment.tracks(in: SampleInitSegmentFixtures.audio).first
        return probes
    }

    @Test func writesSampleMultivariantPlaylist() throws {
        let presentation = try sampleTranslator().translate(probes: sampleProbes)
        let expected = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID="audio",NAME="eng",LANGUAGE="eng",DEFAULT=YES,AUTOSELECT=YES,\
            CHANNELS="6",URI="audio-0.m3u8"
            #EXT-X-STREAM-INF:BANDWIDTH=9688845,RESOLUTION=3832x1600,CODECS="hvc1.2.4.L150.90,mp4a.40.2",\
            VIDEO-RANGE=PQ,FRAME-RATE=23.976,AUDIO="audio"
            video-0.m3u8

            """
        #expect(presentation.multivariantPlaylist == expected)
        #expect(presentation.mediaPlaylists.keys.sorted() == ["audio-0.m3u8", "video-0.m3u8"])
        let info = presentation.streamInfo
        #expect(info == PlaybackStreamInfo(videoCodec: "HEVC", audioCodec: "AAC", width: 3_832, height: 1_600,
                                           frameRate: 24_000.0 / 1_001.0, audioChannels: 6, audioLanguage: "eng"))
    }

    @Test func writesSampleMediaPlaylists() throws {
        let presentation = try sampleTranslator().translate(probes: sampleProbes)
        let video = try #require(presentation.mediaPlaylists["video-0.m3u8"])
        let videoLines = video.split(separator: "\n", omittingEmptySubsequences: false)
        let head = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-TARGETDURATION:16
            #EXT-X-MEDIA-SEQUENCE:1
            #EXT-X-PLAYLIST-TYPE:VOD
            #EXT-X-MAP:URI="\(origin)init-0.mp4"
            #EXTINF:10.00900,
            \(origin)segment-0-00001.m4s
            #EXTINF:10.01000,
            \(origin)segment-0-00002.m4s
            """
        #expect(videoLines.prefix(10).joined(separator: "\n") == head)
        let tail = """
            #EXTINF:0.20900,
            \(origin)segment-0-00873.m4s
            #EXT-X-ENDLIST

            """
        #expect(video.hasSuffix(tail))
        #expect(videoLines.filter { $0.hasPrefix("#EXTINF:") }.count == 873)

        let audio = try #require(presentation.mediaPlaylists["audio-0.m3u8"])
        #expect(audio.contains("#EXT-X-TARGETDURATION:6\n"))
        let audioHead = "#EXT-X-MAP:URI=\"\(origin)init-1.mp4\"\n#EXTINF:6.00167,\n\(origin)segment-1-00001.m4s\n"
        #expect(audio.contains(audioHead))
        #expect(audio.hasSuffix("#EXTINF:1.52533,\n\(origin)segment-1-01447.m4s\n#EXT-X-ENDLIST\n"))
        #expect(audio.split(separator: "\n").filter { $0.hasPrefix("#EXTINF:") }.count == 1_447)
    }

    @Test func alwaysEmitsRangeAndFrameRateWithoutProbes() throws {
        let presentation = try sampleTranslator().translate(probes: [:])
        let streamInf = presentation.multivariantPlaylist.split(separator: "\n")
            .first { $0.hasPrefix("#EXT-X-STREAM-INF:") }.map(String.init)
        let expected = "#EXT-X-STREAM-INF:BANDWIDTH=9688845,RESOLUTION=3832x1600,CODECS=\"hvc1,mp4a.40.2\","
            + "VIDEO-RANGE=SDR,FRAME-RATE=23.976,AUDIO=\"audio\""
        #expect(streamInf == expected)
    }

    @Test func selectsRepresentationsByPolicy() throws {
        let mpd = """
            <MPD type="static" mediaPresentationDuration="PT4S"><Period>
              <AdaptationSet contentType="video" frameRate="30">
                <SegmentTemplate timescale="1" duration="2" media="$RepresentationID$/$Number$.m4s"
                    initialization="$RepresentationID$/init.mp4"/>
                <Representation id="low" bandwidth="1000000" codecs="avc1.64001F" width="1280" height="720"/>
                <Representation id="high" bandwidth="5000000" codecs="avc1.640028" width="1920" height="1080"/>
              </AdaptationSet>
              <AdaptationSet contentType="audio" lang="en">
                <SegmentTemplate timescale="1" duration="2" media="en/$Number$.m4s"/>
                <Representation id="en" bandwidth="128000" codecs="mp4a.40.2"/>
              </AdaptationSet>
              <AdaptationSet contentType="audio" lang="en">
                <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
                <SegmentTemplate timescale="1" duration="2" media="en51/$Number$.m4s"/>
                <Representation id="en51" bandwidth="384000" codecs="ec-3"/>
              </AdaptationSet>
              <AdaptationSet contentType="text" mimeType="text/vtt">
                <Representation id="sub" bandwidth="1"/>
              </AdaptationSet>
            </Period></MPD>
            """
        let manifest = try DASHManifest(data: Data(mpd.utf8), manifestURL: URL(string: "https://example.com/m.mpd")!)
        let best = try DASHToHLSTranslator(manifest: manifest).selection()
        #expect(best.videos.map(\.id) == ["high"])
        #expect(best.audios.map(\.representation.id) == ["en", "en51"])
        let all = try DASHToHLSTranslator(manifest: manifest, policy: .allRepresentations).translate()
        let lines = all.multivariantPlaylist.split(separator: "\n").map(String.init)
        #expect(lines.contains { $0.contains("NAME=\"en\",LANGUAGE=\"en\",DEFAULT=NO") })
        #expect(lines.contains { $0.contains("NAME=\"en 2\",LANGUAGE=\"en\",DEFAULT=YES") })
        let lowVariant = "#EXT-X-STREAM-INF:BANDWIDTH=1384000,RESOLUTION=1280x720,"
            + "CODECS=\"avc1.64001F,mp4a.40.2,ec-3\",VIDEO-RANGE=SDR,FRAME-RATE=30.000,AUDIO=\"audio\""
        #expect(lines.contains(lowVariant))
        #expect(all.mediaPlaylists.count == 4)
        #expect(all.mediaPlaylists["video-1.m3u8"]?.contains("https://example.com/high/2.m4s") == true)
    }

    @Test func writesAudioOnlyPresentations() throws {
        let mpd = """
            <MPD type="static" mediaPresentationDuration="PT6S"><Period>
              <AdaptationSet contentType="audio">
                <SegmentTemplate timescale="48000" duration="96000" media="a/$Number$.m4s" initialization="a/i.mp4"/>
                <Representation id="a" bandwidth="96000" codecs="mp4a"/>
              </AdaptationSet>
            </Period></MPD>
            """
        let manifest = try DASHManifest(data: Data(mpd.utf8), manifestURL: URL(string: "https://example.com/m.mpd")!)
        var probe = MediaTrackInfo(kind: .audio, sampleEntry: "mp4a", codecs: "mp4a.40.5")
        probe.audioChannels = 2
        let presentation = try DASHToHLSTranslator(manifest: manifest).translate(probes: ["a": probe])
        let expected = """
            #EXTM3U
            #EXT-X-VERSION:7
            #EXT-X-INDEPENDENT-SEGMENTS
            #EXT-X-STREAM-INF:BANDWIDTH=96000,CODECS="mp4a.40.5"
            audio-0.m3u8

            """
        #expect(presentation.multivariantPlaylist == expected)
        #expect(presentation.streamInfo.audioChannels == 2)
    }

    @Test func replacesOnlyIncompleteCodecsOfTheSameFamily() {
        var hevc = MediaTrackInfo(kind: .video, sampleEntry: "hvc1", codecs: "hvc1.2.4.L150.90")
        #expect(DASHToHLSTranslator.codecs(declared: "hev1", probe: hevc) == ["hvc1.2.4.L150.90"])
        #expect(DASHToHLSTranslator.codecs(declared: "hvc1.1.6.L93.B0", probe: hevc) == ["hvc1.1.6.L93.B0"])
        #expect(DASHToHLSTranslator.codecs(declared: "avc1", probe: hevc) == ["avc1"])
        #expect(DASHToHLSTranslator.codecs(declared: nil, probe: hevc) == ["hvc1.2.4.L150.90"])
        #expect(DASHToHLSTranslator.codecs(declared: " avc1.64001F , mp4a.40.2 ", probe: nil)
                == ["avc1.64001F", "mp4a.40.2"])
        hevc.codecs = "hvc1"
        #expect(DASHToHLSTranslator.codecs(declared: "hvc1", probe: hevc) == ["hvc1"])
        #expect(HLSCodecs.isComplete("mp4a.40.2"))
        #expect(!HLSCodecs.isComplete("mp4a.40"))
        #expect(HLSCodecs.isComplete("mp4a.6B"))
        #expect(!HLSCodecs.isComplete("avc1"))
        #expect(!HLSCodecs.isComplete("avc1.6400"))
        #expect(HLSCodecs.isComplete("ec-3"))
        #expect(HLSCodecs.isComplete("dvh1.08.06"))
        #expect(!HLSCodecs.isComplete("dvh1.08"))
    }

    @Test func rejectsWhatItCannotTranslate() throws {
        let dynamic = DASHManifest(presentationType: .dynamic, mediaPresentationDuration: nil, minBufferTime: nil,
                                   periods: [])
        #expect(throws: DASHManifestError.unsupported("dynamic MPD")) {
            try DASHToHLSTranslator(manifest: dynamic).selection()
        }
        let textOnly = """
            <MPD type="static"><Period><AdaptationSet contentType="text">
              <Representation id="t" bandwidth="1"/></AdaptationSet></Period></MPD>
            """
        let manifest = try DASHManifest(data: Data(textOnly.utf8), manifestURL: URL(string: "https://example.com/m")!)
        #expect(throws: DASHManifestError.noPlayableRepresentations) {
            try DASHToHLSTranslator(manifest: manifest).selection()
        }
        let segmentList = """
            <MPD type="static"><Period><AdaptationSet contentType="video">
              <Representation id="v" bandwidth="1"><SegmentList duration="1"/></Representation>
            </AdaptationSet></Period></MPD>
            """
        let listManifest = try DASHManifest(data: Data(segmentList.utf8),
                                            manifestURL: URL(string: "https://example.com/m")!)
        #expect(throws: DASHManifestError.unsupported("SegmentList")) {
            try DASHToHLSTranslator(manifest: listManifest).selection()
        }
    }
}
