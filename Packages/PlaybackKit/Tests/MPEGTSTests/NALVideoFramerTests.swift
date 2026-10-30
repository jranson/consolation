//
//  NALVideoFramerTests.swift
//  MPEGTSTests
//
//  The H.264/HEVC framer on hand-built streams: header parsing (size and cropping, VUI, reorder depth, HEVC
//  sub-layers), access-unit boundaries with and without delimiters, length-prefixed samples, H.264 field pairs and
//  pic_struct, A/53 captions in SEI, start-up and leading-picture rules, reference marking for the decode tiers,
//  and hostile input. VideoToolbox-encoded streams are covered in PlaybackKitTests (NALVideoTests).
//

import Foundation
import Testing
@testable import MPEGTS

struct NALVideoFramerTests {
    private typealias NALFx = NALFixtures

    private static func header(_ options: NALFx.H264Options = NALFx.H264Options()) -> [UInt8] {
        NALFx.h264AUD + NALFx.h264SPS(options) + NALFx.h264PPS()
    }

    private static func frame(_ framer: inout NALVideoFramer, _ pieces: [([UInt8], Int64?)]) -> [NALAccessUnit] {
        var units: [NALAccessUnit] = []
        for (bytes, pts) in pieces { units += framer.append(NALFx.pes(bytes, pts: pts)) }
        return units + framer.flush()
    }

    @Test func parsesTheH264SequenceParameterSet() throws {
        let nal = Array(NALFx.h264SPS().dropFirst(4))
        let rbsp = nal.withUnsafeBufferPointer { NALSyntax.rbsp($0, from: 1) }
        let sps = try #require(rbsp.withUnsafeBufferPointer { H264Headers.sps($0) })
        #expect(sps.width == 1920)
        #expect(sps.height == 1080)
        #expect(!sps.frameMBsOnly)
        #expect(sps.frameRate == MPEG2Rational(30000, 1001))
        #expect(sps.maxNumReorderFrames == 2)
        #expect(sps.picStructPresent)
        #expect(sps.hrdDelays?.cpbRemovalDelayBits == 24)
        #expect(sps.format.allowsInterlace)

        var progressive = NALFx.H264Options()
        (progressive.frameMBsOnly, progressive.heightMapUnits, progressive.cropBottom) = (true, 45, 0)
        let small = Array(NALFx.h264SPS(progressive).dropFirst(4))
        let rbsp720 = small.withUnsafeBufferPointer { NALSyntax.rbsp($0, from: 1) }
        let sps720 = try #require(rbsp720.withUnsafeBufferPointer { H264Headers.sps($0) })
        #expect(sps720.width == 1920 && sps720.height == 720)
    }

    @Test func parsesTheHEVCSequenceParameterSet() throws {
        for subLayers in [1, 3] {
            let nal = Array(NALFx.hevcSPS(subLayers: subLayers, reorder: 3).dropFirst(4))
            let rbsp = nal.withUnsafeBufferPointer { NALSyntax.rbsp($0, from: 2) }
            let sps = try #require(rbsp.withUnsafeBufferPointer { HEVCHeaders.sps($0) })
            #expect(sps.width == 1920 && sps.height == 1080)
            #expect(sps.bitDepthLuma == 10)
            #expect(sps.maxSubLayersMinus1 == subLayers - 1)
            #expect(sps.maxNumReorderPics == 3)
            #expect(!sps.interlacedSource)
        }
    }

    /// Exp-Golomb codes read back what was written, and a run of zeros never traps.
    @Test func expGolombRoundTrips() {
        var bits = BitWriter()
        let values = [0, 1, 2, 7, 255, 65_535, 1 << 20]
        for value in values { bits.golomb(value) }
        for value in [-3, 0, 5] { bits.signedGolomb(value) }
        let bytes = bits.trailing()
        bytes.withUnsafeBufferPointer { pointer in
            var reader = BitReader(pointer)
            let unsigned = values.map { _ in reader.golomb() }
            let signed: [Int] = [reader.signedGolomb(), reader.signedGolomb(), reader.signedGolomb()]
            #expect(unsigned == values)
            #expect(signed == [-3, 0, 5])
            #expect(!reader.isOverrun)
        }
        let zeros = [UInt8](repeating: 0, count: 8)
        zeros.withUnsafeBufferPointer { pointer in
            var reader = BitReader(pointer)
            #expect(reader.golomb() == 0)
            #expect(reader.isOverrun)
        }
    }

    /// Progressive H.264: one unit per picture with or without delimiters, a two-slice picture stays whole, the
    /// samples are length-prefixed without AUD/SPS/PPS, and PTS/DTS come from the PES headers.
    @Test func framesProgressiveH264() throws {
        var options = NALFx.H264Options()
        (options.frameMBsOnly, options.cropBottom) = (true, 4)
        options.heightMapUnits = 68
        let idr = Self.header(options) + NALFx.h264Slice(type: 5, refIdc: 3, sliceType: 7, frameMBsOnly: true)
            + NALFx.h264Slice(type: 5, refIdc: 3, firstMB: 4080, sliceType: 7, frameMBsOnly: true)
        let pPicture = NALFx.h264Slice(refIdc: 2, sliceType: 5, frameNum: 1, frameMBsOnly: true)
        let bPicture = NALFx.h264AUD + NALFx.h264Slice(refIdc: 0, sliceType: 6, frameNum: 2, frameMBsOnly: true)
        var framer = NALVideoFramer(codec: .h264)
        var units = framer.append(NALFx.pes(idr, pts: 90_000 + 6_006, dts: 90_000))
        units += framer.append(NALFx.pes(pPicture, pts: 90_000 + 15_015, dts: 93_003))
        units += framer.append(NALFx.pes(bPicture, pts: 90_000 + 9_009, dts: 96_006))
        units += framer.flush()
        #expect(units.count == 3)
        #expect(units.map(\.pts) == [96_006, 105_015, 99_009])
        #expect(units.map(\.dts) == [90_000, 93_003, 96_006])
        #expect(units.map(\.isRandomAccess) == [true, false, false])
        #expect(units.map(\.isReference) == [true, true, false])
        #expect(units.allSatisfy { !$0.isInterlaced && $0.duration == 3_003 })
        #expect(NALFx.sampleTypes(units[0].data) == [5, 5])
        #expect(NALFx.sampleTypes(units[2].data) == [1])
        #expect(units[0].parameterSets.count == 2)
        #expect(units[0].format.width == 1920 && units[0].format.height == 1080)
        #expect(units[0].format.reorderDepth == 2)
    }

    /// Two field pictures of one frame become one sample; pic_struct decides frames that may be interlaced.
    @Test func joinsH264FieldPairsAndReadsPicStruct() throws {
        let top = Self.header() + NALFx.h264Slice(type: 5, refIdc: 3, sliceType: 7, field: false)
        let bottom = NALFx.h264AUD + NALFx.h264Slice(refIdc: 2, sliceType: 5, field: true)
        let bottomFirst = NALFx.h264AUD + NALFx.h264Slice(refIdc: 0, sliceType: 6, frameNum: 1, field: true)
        let topSecond = NALFx.h264AUD + NALFx.h264Slice(refIdc: 0, sliceType: 6, frameNum: 1, field: false)
        let progressiveFrame = NALFx.h264AUD + NALFx.sei([NALFx.picTiming(0)])
            + NALFx.h264Slice(refIdc: 2, sliceType: 5, frameNum: 1)
        let bottomFirstFrame = NALFx.h264AUD + NALFx.sei([NALFx.picTiming(6)])
            + NALFx.h264Slice(refIdc: 2, sliceType: 5, frameNum: 2)
        var framer = NALVideoFramer(codec: .h264)
        let units = Self.frame(&framer, [(top, 900_000), (bottom, nil), (bottomFirst, 903_003), (topSecond, nil),
                                         (progressiveFrame, 906_006), (bottomFirstFrame, 909_009)])
        #expect(units.count == 4)
        #expect(units.map(\.isInterlaced) == [true, true, false, true])
        #expect(units.map(\.topFieldFirst) == [true, false, true, false])
        #expect(units.map(\.duration) == [3_003, 3_003, 3_003, 4_504])
        #expect(units.map(\.isReference) == [true, false, true, true])
        #expect(NALFx.sampleTypes(units[0].data) == [5, 1])
        #expect(units[0].isRandomAccess)
    }

    /// A lone field (its partner lost) is emitted on its own, never joined to the next frame's field.
    @Test func aLoneFieldIsEmittedAlone() {
        let top = Self.header() + NALFx.h264Slice(type: 5, refIdc: 3, sliceType: 7, field: false)
        let nextTop = NALFx.h264AUD + NALFx.h264Slice(refIdc: 2, sliceType: 5, frameNum: 1, field: false)
        let nextBottom = NALFx.h264AUD + NALFx.h264Slice(refIdc: 2, sliceType: 5, frameNum: 1, field: true)
        var framer = NALVideoFramer(codec: .h264)
        let units = Self.frame(&framer, [(top, 900_000), (nextTop, 903_003), (nextBottom, nil)])
        #expect(units.count == 2)
        #expect(units.map(\.duration) == [1_501, 3_003])
    }

    @Test func extractsA53CaptionsFromSEI() throws {
        let picture = Self.header() + NALFx.sei([NALFx.captions()]) + NALFx.h264Slice(type: 5, refIdc: 3, sliceType: 7)
        var framer = NALVideoFramer(codec: .h264)
        let units = Self.frame(&framer, [(picture, 900_000)])
        let unit = try #require(units.first)
        #expect(unit.captionData == Data(NALFx.captionTriplets))
        #expect(NALFx.sampleTypes(unit.data) == [6, 5])
    }

    /// Output waits for parameter sets and a random-access picture with a PTS; then its leading pictures go.
    @Test func startsAtARandomAccessPictureAndDropsItsLeadingPictures() {
        var options = NALFx.H264Options()
        options.frameMBsOnly = true
        let orphan = NALFx.h264AUD + NALFx.h264Slice(refIdc: 2, sliceType: 5, frameMBsOnly: true)
        let intra = NALFx.h264AUD + NALFx.h264SPS(options) + NALFx.h264PPS()
            + NALFx.sei([(6, [0x84])]) + NALFx.h264Slice(refIdc: 3, sliceType: 7, frameNum: 3, frameMBsOnly: true)
        let leading = NALFx.h264AUD + NALFx.h264Slice(refIdc: 0, sliceType: 6, frameNum: 4, frameMBsOnly: true)
        let trailing = NALFx.h264AUD + NALFx.h264Slice(refIdc: 2, sliceType: 5, frameNum: 4, frameMBsOnly: true)
        var framer = NALVideoFramer(codec: .h264)
        var units = framer.append(NALFx.pes(orphan, pts: 100_000))
        units += framer.append(NALFx.pes(intra, pts: 200_000, dts: 194_000))
        units += framer.append(NALFx.pes(leading, pts: 197_000, dts: 197_000))
        units += framer.append(NALFx.pes(trailing, pts: 209_000, dts: 200_000))
        units += framer.flush()
        #expect(units.map(\.pts) == [200_000, 209_000])
        #expect(units.first?.isRandomAccess == true)
    }

    /// Pictures without their own PES timestamp are interpolated from the last one.
    @Test func interpolatesMissingTimestamps() {
        var options = NALFx.H264Options()
        options.frameMBsOnly = true
        var stream = Self.header(options) + NALFx.h264Slice(type: 5, refIdc: 3, sliceType: 7, frameMBsOnly: true)
        for index in 1...3 {
            stream += NALFx.h264AUD + NALFx.h264Slice(refIdc: 2, sliceType: 5, frameNum: index, frameMBsOnly: true)
        }
        var framer = NALVideoFramer(codec: .h264)
        let units = Self.frame(&framer, [(stream, 900_000)])
        #expect(units.map(\.dts) == [900_000, 903_003, 906_006, 909_009])
    }

    /// HEVC: VPS/SPS/PPS kept apart, IRAP pictures are keyframes, RASL after a starting CRA is dropped, and only
    /// sub-layer non-reference pictures in the highest sub-layer count as non-reference.
    @Test(arguments: [1, 2])
    func framesHEVC(subLayers: Int) throws {
        let parameters = NALFx.hevcVPS() + NALFx.hevcSPS(subLayers: subLayers) + NALFx.hevcPPS()
        let aud = NALFx.nal(NALFx.hevcHeader(35), [0x50])
        let captions = NALFx.sei([NALFx.captions()], header: NALFx.hevcHeader(39))
        let cra = aud + parameters + captions + NALFx.hevcSlice(type: 21)
        let rasl = aud + NALFx.hevcSlice(type: 8)
        let trailN = aud + NALFx.hevcSlice(type: 0, temporalID: subLayers - 1)
        let trailNLow = aud + NALFx.hevcSlice(type: 0)
        let trailR = aud + NALFx.hevcSlice(type: 1) + NALFx.hevcSlice(type: 1, first: false)
        var framer = NALVideoFramer(codec: .hevc)
        var units = framer.append(NALFx.pes(cra, pts: 900_000, dts: 897_000))
        units += framer.append(NALFx.pes(rasl, pts: 898_500, dts: 898_500))
        units += framer.append(NALFx.pes(trailR, pts: 906_000, dts: 900_000))
        units += framer.append(NALFx.pes(trailN, pts: 901_500, dts: 901_500))
        units += framer.append(NALFx.pes(trailNLow, pts: 903_000, dts: 903_000))
        units += framer.flush()
        #expect(units.map(\.pts) == [900_000, 906_000, 901_500, 903_000])
        #expect(units.map(\.isRandomAccess) == [true, false, false, false])
        #expect(units.map(\.isReference) == [true, true, false, subLayers > 1])
        #expect(units[0].parameterSets.count == 3)
        #expect(units[0].format.width == 1920 && units[0].format.height == 1080)
        #expect(units[0].captionData == Data(NALFx.captionTriplets))
        #expect(NALFx.sampleTypes(units[0].data, hevc: true) == [39, 21])
        #expect(NALFx.sampleTypes(units[1].data, hevc: true) == [1, 1])
    }

    /// Random bytes, truncated streams and garbage in the middle never trap, and output stays bounded.
    @Test(arguments: [NALVideoCodec.h264, .hevc])
    func survivesHostileInput(codec: NALVideoCodec) {
        var generator = SeededGenerator(seed: codec == .h264 ? 0x264 : 0x265)
        let valid = codec == .h264
            ? Self.header() + NALFx.h264Slice(type: 5, refIdc: 3, sliceType: 7)
            : NALFx.hevcVPS() + NALFx.hevcSPS() + NALFx.hevcPPS() + NALFx.hevcSlice(type: 19)
        var framer = NALVideoFramer(codec: codec)
        var emitted = 0
        for round in 0..<200 {
            var bytes = generator.bytes(Int.random(in: 0...600, using: &generator))
            if round % 3 == 0 { bytes = valid + bytes }
            if round % 7 == 0 { bytes = Array(valid.prefix(Int.random(in: 0...valid.count, using: &generator))) }
            if round % 11 == 0 { bytes = NALFx.startCode + bytes }
            emitted += framer.append(NALFx.pes(bytes, pts: Int64(round) * 3_003)).count
            #expect(framer.buffer.count <= NALVideoFramer.maximumAccessUnitSize + 1_000)
        }
        emitted += framer.flush().count
        #expect(emitted <= 1_000)
        // A NAL unit that never ends is capped.
        var endless = NALVideoFramer(codec: codec)
        let chunk = Data(repeating: 0x5A, count: 1 << 20)
        _ = endless.append(PESPacket(pid: 0x31, streamID: 0xE0, pts: 0, payload: Data(valid) + chunk))
        for _ in 0..<6 { _ = endless.append(PESPacket(pid: 0x31, streamID: 0xE0, payload: chunk)) }
        #expect(endless.buffer.count <= NALVideoFramer.maximumAccessUnitSize + chunk.count)
    }
}
