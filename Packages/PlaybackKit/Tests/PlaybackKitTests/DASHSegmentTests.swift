import Foundation
import Testing
@testable import PlaybackKit

struct DASHSegmentTests {
    private func sampleManifest() throws -> DASHManifest {
        try DASHManifest(data: Data(DASHSampleFixture.mpd.utf8),
                         manifestURL: URL(string: DASHSampleFixture.manifestURLString)!)
    }

    private func representation(_ template: DASHSegmentTemplate, id: String = "r1") -> DASHRepresentation {
        var rep = DASHRepresentation(id: id, bandwidth: 500_000,
                                     baseURL: URL(string: "https://cdn.example.com/show/")!)
        rep.segmentTemplate = template
        return rep
    }

    @Test func expandsSampleTimelines() throws {
        let manifest = try sampleManifest()
        let period = manifest.periods[0]
        let duration = manifest.duration(of: period)
        let video = period.adaptationSets[0].representations[0]
        let audio = period.adaptationSets[1].representations[0]
        let videoSegments = try video.segments(periodDuration: duration)
        let audioSegments = try audio.segments(periodDuration: duration)
        #expect(videoSegments.count == 873)
        #expect(audioSegments.count == 1_447)
        #expect(videoSegments.first?.url.absoluteString == "https://media.example.com/vod/title/segment-0-00001.m4s")
        #expect(videoSegments.last?.url.absoluteString == "https://media.example.com/vod/title/segment-0-00873.m4s")
        #expect(audioSegments.last?.url.absoluteString == "https://media.example.com/vod/title/segment-1-01447.m4s")
        #expect(videoSegments.first?.time == 168)
        #expect(videoSegments[1].time == 168 + 240_216)
        #expect(abs((videoSegments.first?.duration ?? 0) - 10.009) < 0.000_001)
        #expect(abs((videoSegments.last?.duration ?? 0) - 0.209) < 0.000_001)
        #expect(videoSegments.map(\.number) == Array(1...873))
        let videoTotal = videoSegments.reduce(0) { $0 + $1.duration }
        let audioTotal = audioSegments.reduce(0) { $0 + $1.duration }
        #expect(abs(videoTotal - 8_700.608) < 0.001)
        #expect(abs(audioTotal - 417_631_056.0 / 48_000.0) < 0.000_1)
        #expect(try video.initializationURL()?.absoluteString == "https://media.example.com/vod/title/init-0.mp4")
    }

    @Test func formatsTemplateIdentifiers() {
        let template = "$RepresentationID$/$Bandwidth$/$Number%05d$-$Time$-$Time%012d$-$$-$Unknown$.m4s"
        let expanded = DASHTemplate.expand(template, representationID: "v1", bandwidth: 4_000_000, number: 42,
                                           time: 1_234_567)
        #expect(expanded == "v1/4000000/00042-1234567-000001234567-$-$Unknown$.m4s")
        #expect(DASHTemplate.expand("$Number%3d$", representationID: "x", bandwidth: 1, number: 7) == "007")
        #expect(DASHTemplate.expand("$Number%d$", representationID: "x", bandwidth: 1, number: 7) == "7")
        #expect(DASHTemplate.expand("$Number%05x$", representationID: "x", bandwidth: 1, number: 7) == "$Number%05x$")
        #expect(DASHTemplate.expand("$Time$", representationID: "x", bandwidth: 1, number: 7) == "$Time$")
        #expect(DASHTemplate.expand("a$Number", representationID: "x", bandwidth: 1, number: 7) == "a$Number")
        #expect(DASHTemplate.expand("$RepresentationID%02d$", representationID: "x", bandwidth: 1)
                == "$RepresentationID%02d$")
        let wide = DASHTemplate.expand("$Number%0999d$", representationID: "x", bandwidth: 1, number: 1)
        #expect(wide.count == DASHTemplate.maxWidth)
    }

    @Test func expandsTimeBasedTemplatesWithRepeatToNextTime() throws {
        let timeline = [
            DASHTimelineEntry(time: 0, duration: 2_000, repeatCount: -1),
            DASHTimelineEntry(time: 10_000, duration: 3_000, repeatCount: 1),
            DASHTimelineEntry(time: nil, duration: 1_000, repeatCount: -1)
        ]
        let rep = representation(DASHSegmentTemplate(timescale: 1_000, media: "$RepresentationID$-$Time$.m4s",
                                                     startNumber: 10, timeline: timeline))
        let segments = try rep.segments(periodDuration: 20)
        #expect(segments.map(\.time) == [0, 2_000, 4_000, 6_000, 8_000, 10_000, 13_000, 16_000, 17_000, 18_000,
                                         19_000])
        #expect(segments.first?.number == 10)
        #expect(segments[5].url.absoluteString == "https://cdn.example.com/show/r1-10000.m4s")
        #expect(segments[6].duration == 3)
    }

    @Test func expandsDurationTemplates() throws {
        let rep = representation(DASHSegmentTemplate(timescale: 90_000, media: "seg-$Number%03d$.ts", startNumber: 0,
                                                     duration: 540_000))
        let segments = try rep.segments(periodDuration: 31)
        #expect(segments.count == 6)
        #expect(segments.first?.url.lastPathComponent == "seg-000.ts")
        #expect(segments.last?.url.lastPathComponent == "seg-005.ts")
        #expect(segments.dropLast().allSatisfy { $0.duration == 6 })
        #expect(abs((segments.last?.duration ?? 0) - 1) < 0.000_001)
    }

    @Test func requiresEnoughInformation() {
        let noDuration = representation(DASHSegmentTemplate(timescale: 1, media: "$Number$"))
        #expect(throws: DASHManifestError.missingSegmentInformation(representationID: "r1")) {
            try noDuration.segments(periodDuration: 10)
        }
        let openEnded = representation(DASHSegmentTemplate(
            media: "$Number$", timeline: [DASHTimelineEntry(time: 0, duration: 1, repeatCount: -1)]))
        #expect(throws: DASHManifestError.missingSegmentInformation(representationID: "r1")) {
            try openEnded.segments(periodDuration: nil)
        }
        let noMedia = representation(DASHSegmentTemplate(duration: 1))
        #expect(throws: DASHManifestError.missingSegmentInformation(representationID: "r1")) {
            try noMedia.segments(periodDuration: 10)
        }
    }

    @Test func capsAbsurdSegmentCounts() {
        let huge = representation(DASHSegmentTemplate(
            media: "$Number$", timeline: [DASHTimelineEntry(time: 0, duration: 1, repeatCount: Int.max)]))
        #expect(throws: DASHManifestError.tooLarge) { try huge.segments(periodDuration: nil) }
        let tiny = representation(DASHSegmentTemplate(timescale: 1_000_000, media: "$Number$", duration: 1))
        #expect(throws: DASHManifestError.tooLarge) { try tiny.segments(periodDuration: 3_600) }
        let overflow = representation(DASHSegmentTemplate(
            media: "$Number$", timeline: [DASHTimelineEntry(time: Int64.max - 1, duration: Int64.max, repeatCount: 3)]))
        #expect(throws: DASHManifestError.tooLarge) { try overflow.segments(periodDuration: nil) }
        let lateStart = representation(DASHSegmentTemplate(media: "$Number$", startNumber: Int.max, duration: 1))
        #expect(throws: DASHManifestError.tooLarge) { try lateStart.segments(periodDuration: 10) }
        let absurdRepeat = representation(DASHSegmentTemplate(
            media: "$Number$", timeline: [DASHTimelineEntry(time: 0, duration: 1, repeatCount: -1)]))
        #expect(throws: DASHManifestError.tooLarge) { try absurdRepeat.segments(periodDuration: 1e300) }
    }
}
