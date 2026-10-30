//
//  AVFoundationMalformedInputTests.swift
//  PlaybackKitTests
//
//  Fixed-seed random and mutated input for every parser on the AVFoundation side: MPD, HLS playlists and
//  attribute lists, ISO-BMFF init segments and fragments. Each must return a value or a typed error, never trap.
//

import Foundation
import Testing
@testable import PlaybackKit

struct AVFoundationMalformedInputTests {
    private static let mpdTokens = [
        "<MPD type=\"static\" mediaPresentationDuration=\"PT10S\">", "</MPD>", "<Period>", "</Period>",
        "<Period duration=\"PT-5S\">", "<AdaptationSet contentType=\"video\">",
        "<AdaptationSet mimeType=\"audio/mp4\">",
        "</AdaptationSet>", "<Representation id=\"r\" bandwidth=\"9\" codecs=\"hvc1\">", "</Representation>",
        "<Representation bandwidth=\"-1\" width=\"99999999999999999999\"/>",
        "<SegmentTemplate media=\"$Number%099d$-$Time$\" timescale=\"0\" startNumber=\"-4\">",
        "<SegmentTemplate duration=\"1\" media=\"$RepresentationID$\" initialization=\"$$\"/>", "</SegmentTemplate>",
        "<SegmentTimeline>", "</SegmentTimeline>", "<S d=\"1\" r=\"-1\"/>", "<S t=\"9223372036854775807\" d=\"5\"/>",
        "<S d=\"0\" r=\"100\"/>", "<S d=\"2\" r=\"99999999\"/>", "<BaseURL>../x/</BaseURL>", "<BaseURL>%%%</BaseURL>",
        "<AudioChannelConfiguration value=\"F\"/>", "<Role value=\"main\"/>", "&amp;", "<!-- c -->", "<![CDATA[x]]>",
        "<SegmentBase/>", "\u{0}", "<", ">", "\""
    ]

    @Test func mpdParserSurvivesRandomDocuments() {
        var random = SeededGenerator(seed: 0x51A7_E5ED)
        let url = URL(string: "https://example.com/a/m.mpd")!
        for _ in 0..<400 {
            let count = Int.random(in: 0...40, using: &random)
            let text = (0..<count).map { _ in Self.mpdTokens.randomElement(using: &random) ?? "" }.joined()
            exerciseMPD(Data(text.utf8), url: url)
        }
        for _ in 0..<200 {
            exerciseMPD(Data(random.bytes(Int.random(in: 0...512, using: &random))), url: url)
        }
    }

    @Test func mpdParserSurvivesMutatedSampleManifest() {
        var random = SeededGenerator(seed: 0xDA5_4D)
        let original = Array(DASHSampleFixture.mpd.utf8)
        let url = URL(string: DASHSampleFixture.manifestURLString)!
        for _ in 0..<60 {
            var bytes = original
            for _ in 0..<Int.random(in: 1...20, using: &random) {
                bytes[Int.random(in: 0..<bytes.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
            }
            let cut = Int.random(in: 0...bytes.count, using: &random)
            exerciseMPD(Data(bytes.prefix(cut)), url: url)
            exerciseMPD(Data(bytes), url: url)
        }
    }

    @Test func playlistParsersSurviveRandomText() {
        var random = SeededGenerator(seed: 0x4C5)
        let tokens = ["#EXTM3U\n", "#EXT-X-STREAM-INF:", "BANDWIDTH=", "CODECS=\"", "\"", ",", "=", "\n", "hvc1",
                      "mp4a", "RESOLUTION=1x1", "#EXT-X-MEDIA:TYPE=AUDIO,GROUP-ID=\"a\",URI=\"", "x.m3u8", "../",
                      "#EXT-X-MAP:URI=\"", "#EXT-X-BYTERANGE:", "@", "-1", "99999999999999999999", "\r\n", "\u{FEFF}",
                      "#EXT-X-I-FRAME-STREAM-INF:URI=\"", "AUDIO=\"a\"", "%zz", " "]
        let base = URL(string: "https://example.com/p/m.m3u8?t=1")!
        let probe = HLSRepairProbe(video: MediaTrackInfo(kind: .video, sampleEntry: "hvc1", codecs: "hvc1.1.6.L93.B0"),
                                   audio: nil)
        for _ in 0..<500 {
            let text = (0..<Int.random(in: 0...60, using: &random))
                .map { _ in tokens.randomElement(using: &random) ?? "" }.joined()
            if let playlist = HLSMultivariantPlaylist(text: text) {
                _ = HLSMultivariantRepair.needsRepair(playlist)
                let rewritten = HLSMultivariantRepair.rewrite(playlist, baseURL: base, probe: probe)
                #expect(rewritten.hasSuffix("\n"))
            }
            _ = HLSMediaPlaylistReferences(text: text, baseURL: base)
            _ = HLSAttributeList(parsing: Substring(text))
        }
    }

    @Test func isoParsersSurviveRandomAndMutatedBoxes() {
        var random = SeededGenerator(seed: 0x150)
        let samples = [Array(SampleInitSegmentFixtures.video), Array(SampleInitSegmentFixtures.audio),
                       Box.fragment(durations: Array(repeating: 1_001, count: 48))]
        for _ in 0..<300 {
            let noise = random.bytes(Int.random(in: 0...256, using: &random))
            exerciseISO(noise)
            var mutated = samples.randomElement(using: &random) ?? []
            for _ in 0..<Int.random(in: 1...12, using: &random) where !mutated.isEmpty {
                mutated[Int.random(in: 0..<mutated.count, using: &random)] = UInt8.random(in: 0...255, using: &random)
            }
            exerciseISO(mutated)
            exerciseISO(Array(mutated.prefix(Int.random(in: 0...mutated.count, using: &random))))
        }
    }

    @Test func translatorSurvivesHostileValues() throws {
        let url = URL(string: "https://example.com/m.mpd")!
        let endless = """
            <MPD type="static" mediaPresentationDuration="P99999999Y"><Period><AdaptationSet contentType="video">
              <Representation id="v" bandwidth="1"><SegmentTemplate media="$Number$" duration="1"/></Representation>
            </AdaptationSet></Period></MPD>
            """
        let endlessManifest = try DASHManifest(data: Data(endless.utf8), manifestURL: url)
        #expect(throws: DASHManifestError.tooLarge) { try DASHToHLSTranslator(manifest: endlessManifest).translate() }
        let hostile = """
            <MPD type="static" mediaPresentationDuration="PT4S"><Period>
              <AdaptationSet contentType="video" frameRate="1/0" lang="x&quot;y">
                <Representation id="bad&#10;id" bandwidth="9223372036854775807" width="-5" height="0">
                  <SegmentTemplate timescale="1" media="$RepresentationID$/$Number$" duration="1"/>
                </Representation>
              </AdaptationSet>
              <AdaptationSet contentType="audio" lang="e&quot;n&#10;g">
                <Representation id="a" bandwidth="128000">
                  <SegmentTemplate media="$Number$" duration="2"/>
                </Representation>
              </AdaptationSet>
            </Period></MPD>
            """
        let manifest = try DASHManifest(data: Data(hostile.utf8), manifestURL: url)
        let presentation = try DASHToHLSTranslator(manifest: manifest).translate()
        let lines = presentation.multivariantPlaylist.split(separator: "\n")
        #expect(lines.contains { $0.hasPrefix("#EXT-X-STREAM-INF:BANDWIDTH=\(Int.max),") })
        #expect(lines.contains { $0.contains("NAME=\"eng\",LANGUAGE=\"eng\"") })
        #expect(presentation.mediaPlaylists["video-0.m3u8"]?.contains("bad%0Aid/1") == true)
    }

    private func exerciseMPD(_ data: Data, url: URL) {
        guard let manifest = try? DASHManifest(data: data, manifestURL: url) else { return }
        let translator = DASHToHLSTranslator(manifest: manifest, policy: .allRepresentations)
        if let presentation = try? translator.translate() {
            #expect(presentation.multivariantPlaylist.hasPrefix("#EXTM3U\n"))
        }
    }

    private func exerciseISO(_ bytes: [UInt8]) {
        let data = Data(bytes)
        for track in ISOInitSegment.tracks(in: data) {
            #expect(!track.codecs.isEmpty)
        }
        _ = ISOFragment.frameRate(in: data, trackID: nil, timescale: 24_000, defaultDuration: 1_001)
        _ = ISOCodecStrings.hevc(hvcC: bytes[...], sampleEntry: "hvc1")
        _ = ISOCodecStrings.avc(avcC: bytes[...], sampleEntry: "avc1")
        _ = ISOCodecStrings.mpeg4Audio(esds: bytes[...])
        _ = ISOCodecStrings.ac3Channels(dac3: bytes[...])
        _ = ISOCodecStrings.eac3Channels(dec3: bytes[...])
        _ = ISOCodecStrings.transferCharacteristics(colr: bytes[...])
    }
}
