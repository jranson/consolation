import Foundation
import Testing
@testable import PlaybackKit

struct DASHManifestTests {
    private let sampleURL = URL(string: DASHSampleFixture.manifestURLString)!

    private func parse(_ text: String, url: String = "https://cdn.example.com/a/b/manifest.mpd") throws -> DASHManifest {
        try DASHManifest(data: Data(text.utf8), manifestURL: URL(string: url)!)
    }

    @Test func parsesSampleManifestStructure() throws {
        let manifest = try DASHManifest(data: Data(DASHSampleFixture.mpd.utf8), manifestURL: sampleURL)
        #expect(manifest.presentationType == .staticPresentation)
        #expect(abs((manifest.mediaPresentationDuration ?? 0) - 8_700.6) < 0.001)
        #expect(manifest.minBufferTime == 20)
        #expect(manifest.periods.count == 1)
        let period = try #require(manifest.periods.first)
        #expect(period.id == "0")
        #expect(period.start == 0)
        #expect(period.adaptationSets.map(\.contentType) == [.video, .audio])

        let video = try #require(period.adaptationSets[0].representations.first)
        #expect(video.id == "0")
        #expect(video.codecs == "hvc1")
        #expect(video.bandwidth == 9_304_845)
        #expect(video.width == 3_832 && video.height == 1_600)
        #expect(abs((video.frameRate ?? 0) - 24_000.0 / 1_001.0) < 0.000_001)
        #expect(video.mimeType == "video/mp4")
        #expect(video.baseURL == sampleURL)
        let template = try #require(video.segmentTemplate)
        #expect(template.timescale == 24_000)
        #expect(template.startNumber == 1)
        #expect(template.initialization == "init-$RepresentationID$.mp4")
        #expect(template.media == "segment-$RepresentationID$-$Number%05d$.m4s")
        #expect(template.timeline?.count == 267)
        #expect(template.timeline?.first == DASHTimelineEntry(time: 168, duration: 240_216, repeatCount: 0))

        let audioSet = period.adaptationSets[1]
        #expect(audioSet.language == "eng")
        let audio = try #require(audioSet.representations.first)
        #expect(audio.codecs == "mp4a.40.2")
        #expect(audio.audioChannels == 6)
        #expect(audio.audioSamplingRate == 48_000)
        #expect(audio.segmentTemplate?.timeline?.count == 3)
        let repeated = DASHTimelineEntry(time: nil, duration: 288_768, repeatCount: 1_444)
        #expect(audio.segmentTemplate?.timeline?[1] == repeated)
    }

    @Test func resolvesBaseURLAtEveryLevel() throws {
        let manifest = try parse("""
            <MPD xmlns="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT10S">
              <BaseURL>media/</BaseURL>
              <Period>
                <BaseURL> period1/ </BaseURL>
                <AdaptationSet mimeType="video/mp4" codecs="avc1.64001F">
                  <BaseURL>https://other.example.net/root/</BaseURL>
                  <SegmentTemplate timescale="1000" duration="2000" media="$RepresentationID$/$Number$.m4s"/>
                  <Representation id="v1" bandwidth="100"><BaseURL>low/</BaseURL></Representation>
                  <Representation id="v2" bandwidth="200"/>
                </AdaptationSet>
                <AdaptationSet mimeType="audio/mp4">
                  <SegmentTemplate timescale="1000" duration="2000" media="a/$Number$.m4s"/>
                  <Representation id="a1" bandwidth="64000" codecs="mp4a.40.2"/>
                </AdaptationSet>
              </Period>
            </MPD>
            """)
        let sets = manifest.periods[0].adaptationSets
        #expect(sets[0].representations[0].baseURL.absoluteString == "https://other.example.net/root/low/")
        #expect(sets[0].representations[1].baseURL.absoluteString == "https://other.example.net/root/")
        #expect(sets[1].representations[0].baseURL.absoluteString == "https://cdn.example.com/a/b/media/period1/")
        #expect(sets[0].representations[0].codecs == "avc1.64001F")
        #expect(sets[0].contentType == .video)
        let segments = try sets[1].representations[0].segments(periodDuration: 10)
        #expect(segments.first?.url.absoluteString == "https://cdn.example.com/a/b/media/period1/a/1.m4s")
    }

    @Test func inheritsTemplateAttributesAcrossLevels() throws {
        let manifest = try parse("""
            <MPD type="static" mediaPresentationDuration="PT8S">
              <Period duration="PT8S">
                <SegmentTemplate timescale="90000" startNumber="5"/>
                <AdaptationSet contentType="video">
                  <SegmentTemplate media="v-$Number$.mp4" initialization="v-init.mp4"/>
                  <Representation id="r" bandwidth="1" width="640" height="360" frameRate="25">
                    <SegmentTemplate duration="180000"/>
                  </Representation>
                </AdaptationSet>
              </Period>
            </MPD>
            """)
        let rep = manifest.periods[0].adaptationSets[0].representations[0]
        let template = try #require(rep.segmentTemplate)
        #expect(template.timescale == 90_000)
        #expect(template.startNumber == 5)
        #expect(template.duration == 180_000)
        #expect(template.media == "v-$Number$.mp4")
        #expect(rep.frameRate == 25)
        #expect(manifest.periods[0].duration == 8)
    }

    @Test func readsDescriptorsAndRoles() throws {
        let manifest = try parse("""
            <MPD type="static" mediaPresentationDuration="PT4S"><Period>
              <AdaptationSet contentType="video">
                <SupplementalProperty schemeIdUri="urn:mpeg:mpegB:cicp:TransferCharacteristics" value="18"/>
                <Representation id="v" bandwidth="1"><SegmentTemplate media="v$Number$" duration="1"/></Representation>
              </AdaptationSet>
              <AdaptationSet contentType="audio" lang="spa">
                <Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/>
                <AudioChannelConfiguration schemeIdUri="tag:dolby.com,2014:dash:audio_channel_configuration:2011"
                    value="F801"/>
                <Representation id="a" bandwidth="1"><SegmentTemplate media="a$Number$" duration="1"/></Representation>
              </AdaptationSet>
              <AdaptationSet contentType="audio">
                <AudioChannelConfiguration schemeIdUri="urn:mpeg:mpegB:cicp:ChannelConfiguration" value="7"/>
                <Representation id="b" bandwidth="1"><SegmentTemplate media="b$Number$" duration="1"/></Representation>
              </AdaptationSet>
            </Period></MPD>
            """)
        let sets = manifest.periods[0].adaptationSets
        #expect(sets[0].representations[0].transferCharacteristics == 18)
        #expect(sets[1].isMain)
        #expect(sets[1].language == "spa")
        #expect(sets[1].representations[0].audioChannels == 6)
        #expect(sets[2].representations[0].audioChannels == 8)
    }

    @Test func parsesDurationsAndFrameRates() {
        #expect(DASHAttributes.seconds("PT2H25M0.6S").map { abs($0 - 8_700.6) < 0.000_1 } == true)
        #expect(DASHAttributes.seconds("PT0S") == 0)
        #expect(DASHAttributes.seconds("P1DT1M") == 86_460)
        #expect(DASHAttributes.seconds("PT1.5S") == 1.5)
        #expect(DASHAttributes.seconds("P") == nil)
        #expect(DASHAttributes.seconds("PT5") == nil)
        #expect(DASHAttributes.seconds("10S") == nil)
        #expect(DASHAttributes.seconds("PT1X") == nil)
        #expect(DASHAttributes.frameRate("30000/1001").map { abs($0 - 29.97) < 0.001 } == true)
        #expect(DASHAttributes.frameRate("25") == 25)
        #expect(DASHAttributes.frameRate("25/0") == nil)
        #expect(DASHAttributes.frameRate("abc") == nil)
        #expect(DASHAttributes.frameRate("1/2/3") == nil)
    }

    @Test func handlesNamespacePrefixes() throws {
        let manifest = try parse("""
            <dash:MPD xmlns:dash="urn:mpeg:dash:schema:mpd:2011" type="static" mediaPresentationDuration="PT2S">
              <dash:Period><dash:AdaptationSet contentType="audio">
                <dash:Representation id="a" bandwidth="1" codecs="mp4a.40.2">
                  <dash:SegmentTemplate media="$Number$.m4s" duration="1"/>
                </dash:Representation>
              </dash:AdaptationSet></dash:Period>
            </dash:MPD>
            """)
        #expect(manifest.periods[0].adaptationSets[0].representations[0].segmentTemplate?.duration == 1)
    }

    @Test func recognisesDynamicAndUnsupportedAddressing() throws {
        let dynamic = try parse("""
            <MPD type="dynamic"><Period><AdaptationSet contentType="video">
              <Representation id="v" bandwidth="1"><SegmentBase indexRange="0-99"/></Representation>
            </AdaptationSet></Period></MPD>
            """)
        #expect(dynamic.presentationType == .dynamic)
        let rep = dynamic.periods[0].adaptationSets[0].representations[0]
        #expect(rep.unsupportedAddressing == "SegmentBase")
        #expect(throws: DASHManifestError.unsupported("SegmentBase")) { try rep.segments(periodDuration: 10) }
    }

    @Test func rejectsMalformedDocuments() {
        #expect(throws: DASHManifestError.self) { try parse("<MPD><Period>") }
        #expect(throws: DASHManifestError.notAnMPD) { try parse("<html><body/></html>") }
        #expect(throws: DASHManifestError.noPeriods) { try parse("<MPD type=\"static\"/>") }
        #expect(throws: DASHManifestError.self) { try parse("") }
        #expect(throws: DASHManifestError.self) { try parse("\u{0}\u{1}garbage<<>>") }
    }

    @Test func ignoresElementsInUnexpectedPlaces() throws {
        let manifest = try parse("""
            <MPD type="static" mediaPresentationDuration="PT2S"><Period>
              <AdaptationSet contentType="audio">
                <ContentComponent><Role schemeIdUri="urn:mpeg:dash:role:2011" value="main"/></ContentComponent>
                <Representation id="a" bandwidth="1">
                  <SubRepresentation><BaseURL>ignored/</BaseURL></SubRepresentation>
                  <SegmentTemplate media="$Number$.m4s" duration="1"/>
                </Representation>
                <S t="1" d="1"/>
              </AdaptationSet>
            </Period></MPD>
            """)
        let set = manifest.periods[0].adaptationSets[0]
        #expect(!set.isMain)
        #expect(set.representations[0].baseURL.absoluteString == "https://cdn.example.com/a/b/manifest.mpd")
        #expect(set.representations[0].segmentTemplate?.timeline == nil)
    }
}
