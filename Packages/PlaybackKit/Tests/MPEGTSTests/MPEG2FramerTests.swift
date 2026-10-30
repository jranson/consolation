//
//  MPEG2FramerTests.swift
//  MPEGTSTests
//
//  Access-unit splitting, header parsing, start-up rules, timestamps and captions.
//

import Foundation
import Testing
import MPEGTS

struct MPEG2FramerTests {
    @Test func interlaced1080TopFieldFirst() throws {
        let pictures = StreamBuilder.gops(3)
        let events = demux(StreamBuilder.broadcast(pictures: pictures))
        let units = frameVideo(events.packets(pid: StreamBuilder.videoPID))
        #expect(units.count == pictures.count - 2)
        let first = try #require(units.first)
        #expect(first.isKeyframe)
        #expect(first.hasSequenceHeader)
        #expect(Array(first.data.prefix(4)) == [0, 0, 1, 0xB3])
        #expect(first.pictureType == .intra)
        #expect(first.temporalReference == 2)
        #expect(first.topFieldFirst)
        #expect(!first.progressiveFrame)
        #expect(first.pictureStructure == .frame)
        let sequence = first.sequence
        #expect(sequence.width == 1920)
        #expect(sequence.height == 1080)
        #expect(sequence.aspectRatioCode == 3)
        #expect(sequence.frameRate == MPEG2Rational(30000, 1001))
        #expect(!sequence.progressiveSequence)
        #expect(sequence.chromaFormat == 1)
        #expect(sequence.profileAndLevel == 0x44)
        #expect(sequence.bitRate == 19_400_000)
        #expect(sequence.hasSequenceExtension)
        #expect(first.duration == 3003)
    }

    @Test func progressive720p() throws {
        let pictures = StreamBuilder.gops(2, ticks: 1501, interlaced: false)
        let events = demux(StreamBuilder.broadcast(pictures: pictures, sequence: .hd720p))
        let units = frameVideo(events.packets(pid: StreamBuilder.videoPID))
        let first = try #require(units.first)
        #expect(first.sequence.width == 1280)
        #expect(first.sequence.height == 720)
        #expect(first.sequence.frameRate == MPEG2Rational(60000, 1001))
        #expect(first.sequence.progressiveSequence)
        #expect(first.progressiveFrame)
        #expect(!first.topFieldFirst)
        #expect(first.duration == 1501)
    }

    @Test func oneSamplePerPictureWithHeadersAttached() throws {
        var random = SeededGenerator(seed: 5)
        let pictures = StreamBuilder.gops(2)
        var packets: [PESPacket] = []
        var expected: [[UInt8]] = []
        for picture in pictures {
            let bytes = StreamBuilder.pictureBytes(picture, sequence: .hd1080i, random: &random)
            expected.append(bytes)
            packets.append(videoPES(bytes, pts: picture.pts, dts: picture.dts))
        }
        let units = frameVideo(packets)
        // The two leading B pictures of the first open GOP are dropped; everything else is one unit per picture.
        let kept = [expected[0]] + Array(expected[3...])
        #expect(units.map { Array($0.data) } == kept)
        #expect(units.filter(\.hasSequenceHeader).count == 2)
        #expect(units.filter(\.isKeyframe).count == 2)
        #expect(units.map(\.temporalReference) == [2, 5, 3, 4, 8, 6, 7, 2, 0, 1, 5, 3, 4, 8, 6, 7])
        let dts = units.map(\.dts)
        #expect(dts == dts.sorted())
        let keptPictures = [pictures[0]] + Array(pictures[3...])
        #expect(units.map(\.pts) == keptPictures.map(\.pts))
        #expect(units.map(\.dts) == keptPictures.map { $0.dts ?? $0.pts })
        #expect(units[0].pts - units[0].dts == 9009)
        #expect(units[2].pts == units[2].dts)
    }

    @Test func midGOPStartWaitsForSequenceHeaderAndI() throws {
        var random = SeededGenerator(seed: 6)
        let pictures = StreamBuilder.gops(2)
        // Join mid-GOP: start at the fourth picture (a P picture) of the first GOP.
        let packets = pictures[3...].map { picture in
            videoPES(StreamBuilder.pictureBytes(picture, sequence: .hd1080i, random: &random), pts: picture.pts,
                     dts: picture.dts)
        }
        let units = frameVideo(packets)
        #expect(units.count == 9 - 2)
        let first = try #require(units.first)
        #expect(first.isKeyframe)
        #expect(first.pts == pictures[9].pts)
    }

    @Test func closedGOPKeepsLeadingBPictures() {
        let pictures = StreamBuilder.gops(1)
        let events = demux(StreamBuilder.broadcast(pictures: pictures, closedGOP: true))
        let units = frameVideo(events.packets(pid: StreamBuilder.videoPID))
        #expect(units.count == pictures.count)
    }

    @Test func missingTimestampsAreInterpolated() {
        var random = SeededGenerator(seed: 8)
        let pictures = StreamBuilder.gops(1)
        var packets: [PESPacket] = []
        for (index, picture) in pictures.enumerated() {
            let bytes = StreamBuilder.pictureBytes(picture, sequence: .hd1080i, random: &random)
            // Only the I picture and the first P picture carry timestamps.
            let stamped = index == 0 || index == 3
            packets.append(videoPES(bytes, pts: stamped ? picture.pts : nil, dts: stamped ? picture.dts : nil))
        }
        let units = frameVideo(packets)
        #expect(units.map(\.dts) == pictures.enumerated().filter { ![1, 2].contains($0.offset) }.map { item in
            item.element.dts ?? item.element.pts
        })
        // B pictures: PTS = DTS; P pictures: DTS + the I/P reorder delay (9009).
        #expect(units.map(\.pts) == pictures.enumerated().filter { ![1, 2].contains($0.offset) }.map(\.element.pts))
    }

    @Test func severalPicturesInOnePESAndPicturesSplitAcrossPES() {
        var random = SeededGenerator(seed: 9)
        let pictures = StreamBuilder.gops(1, ticks: 3003)
        var stream: [UInt8] = []
        for picture in pictures {
            stream += StreamBuilder.pictureBytes(picture, sequence: .hd1080i, random: &random)
        }
        // One PES holding the first four pictures, then the rest cut at odd offsets with no timestamps.
        let firstEnd = stream.count / 2
        var packets = [videoPES(Array(stream[..<firstEnd]), pts: pictures[0].pts, dts: pictures[0].dts)]
        var offset = firstEnd
        while offset < stream.count {
            let end = min(stream.count, offset + 333)
            packets.append(videoPES(Array(stream[offset..<end])))
            offset = end
        }
        let units = frameVideo(packets)
        #expect(units.count == pictures.count - 2)
        #expect(units.map(\.dts) == units.map(\.dts).sorted())
        #expect(units.reduce(0) { $0 + $1.data.count } < stream.count)
    }

    @Test func captionsAreExtracted() throws {
        let pictures = StreamBuilder.gops(1, captions: true)
        let events = demux(StreamBuilder.broadcast(pictures: pictures))
        let units = frameVideo(events.packets(pid: StreamBuilder.videoPID))
        let first = try #require(units.first)
        let captions = try #require(first.captionData)
        #expect(captions.count == 60)
        #expect(Array(captions.prefix(6)) == [0xFC, 0x80, 0x80, 0xFD, 0x80, 0x80])
        #expect(units.allSatisfy { $0.captionData?.count == 60 })
    }

    @Test func fieldPicturesPairIntoOneUnit() throws {
        var random = SeededGenerator(seed: 10)
        var bytes = MPEG2Fixtures.sequenceHeader(.hd1080i) + MPEG2Fixtures.gop(closed: true)
        bytes += MPEG2Fixtures.picture(PictureSpec(type: 1, temporalReference: 0, structure: 1), slices: &random)
        bytes += MPEG2Fixtures.picture(PictureSpec(type: 2, temporalReference: 0, structure: 2), slices: &random)
        let secondStart = bytes.count
        bytes += MPEG2Fixtures.picture(PictureSpec(type: 2, temporalReference: 1, structure: 1), slices: &random)
        bytes += MPEG2Fixtures.picture(PictureSpec(type: 2, temporalReference: 1, structure: 2), slices: &random)
        let units = frameVideo([videoPES(bytes, pts: 9000)])
        #expect(units.count == 2)
        let first = try #require(units.first)
        #expect(first.data.count == secondStart)
        #expect(first.pictureStructure == .topField)
        #expect(first.duration == 3003)
        let secondDTS: Int64 = 9000 + 3003
        #expect(units.last?.dts == secondDTS)
    }

    @Test func repeatFirstFieldAndDimensionsExtension() throws {
        var random = SeededGenerator(seed: 12)
        var sequence = SequenceSpec(width: 4, height: 2160, rateCode: 1, progressive: true)
        sequence.widthExtension = 1
        var bytes = MPEG2Fixtures.sequenceHeader(sequence) + MPEG2Fixtures.gop(closed: true)
        var spec = PictureSpec(type: 1, temporalReference: 0, topFieldFirst: true, repeatFirstField: true,
                               progressiveFrame: true)
        bytes += MPEG2Fixtures.picture(spec, slices: &random)
        spec.type = 2
        spec.temporalReference = 1
        bytes += MPEG2Fixtures.picture(spec, slices: &random) + [0, 0, 1, 0xB7]
        let units = frameVideo([videoPES(bytes, pts: 0)])
        let first = try #require(units.first)
        #expect(first.sequence.width == 4100)
        #expect(first.sequence.height == 2160)
        #expect(first.repeatFirstField)
        // Progressive sequence, RFF and TFF: the frame is shown three times at 23.976 Hz.
        #expect(first.duration == 11_261)
        #expect(units.last?.dts == first.duration)
        #expect(units.last?.data.suffix(4) == Data([0, 0, 1, 0xB7]))
    }

    @Test func discontinuityIsCarriedToTheNextPicture() {
        var random = SeededGenerator(seed: 13)
        let pictures = StreamBuilder.gops(1)
        var packets: [PESPacket] = []
        for (index, picture) in pictures.enumerated() {
            let bytes = StreamBuilder.pictureBytes(picture, sequence: .hd1080i, random: &random)
            packets.append(videoPES(bytes, pts: picture.pts, dts: picture.dts, discontinuity: index == 4))
        }
        let units = frameVideo(packets)
        #expect(units.map(\.isDiscontinuity) == [false, false, true, false, false, false, false])
    }

    @Test func resetRestartsAtTheNextSyncSample() {
        var random = SeededGenerator(seed: 14)
        let pictures = StreamBuilder.gops(2)
        var framer = MPEG2Framer()
        var units: [MPEG2AccessUnit] = []
        for (index, picture) in pictures.enumerated() {
            if index == 4 { framer.reset() }
            let bytes = StreamBuilder.pictureBytes(picture, sequence: .hd1080i, random: &random)
            units += framer.append(videoPES(bytes, pts: picture.pts, dts: picture.dts))
        }
        units += framer.flush()
        #expect(units.first?.pictureType == .intra)
        #expect(units.filter(\.isKeyframe).count == 2)
        #expect(framer.sequence?.width == 1920)
    }

    /// picture_coding_type survives framing for every picture, in decode order: the decode tiers drop B pictures
    /// (`.reduced`) or keep only I pictures (`.keyframesOnly`) by it.
    @Test func pictureCodingTypesInDecodeOrder() {
        let pictures = StreamBuilder.gops(2)
        let events = demux(StreamBuilder.broadcast(pictures: pictures))
        let units = frameVideo(events.packets(pid: StreamBuilder.videoPID))
        // The first open GOP's two leading B pictures are dropped at start-up; every later one is kept.
        #expect(units.map(\.pictureType) == [.intra, .predicted, .bidirectional, .bidirectional, .predicted,
                                              .bidirectional, .bidirectional, .intra, .bidirectional,
                                              .bidirectional, .predicted, .bidirectional, .bidirectional,
                                              .predicted, .bidirectional, .bidirectional])
        #expect(units.filter(\.isKeyframe).map(\.pictureType) == [.intra, .intra])
    }
}
