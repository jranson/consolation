import Foundation
import Testing
@testable import PlaybackKit

struct ISOBMFFTests {
    @Test func readsSampleVideoInitSegment() throws {
        let tracks = ISOInitSegment.tracks(in: SampleInitSegmentFixtures.video)
        let track = try #require(tracks.first)
        #expect(tracks.count == 1)
        #expect(track.kind == .video)
        #expect(track.sampleEntry == "hvc1")
        #expect(track.codecs == "hvc1.2.4.L150.90")
        #expect(track.width == 3_832 && track.height == 1_600)
        #expect(track.transferCharacteristics == 16)
        #expect(track.videoRange == .perceptualQuantizer)
        #expect(track.timescale == 24_000)
        #expect(track.trackID == 1)
    }

    @Test func readsSampleAudioInitSegment() throws {
        let track = try #require(ISOInitSegment.tracks(in: SampleInitSegmentFixtures.audio).first)
        #expect(track.kind == .audio)
        #expect(track.codecs == "mp4a.40.2")
        #expect(track.audioChannels == 6)
        #expect(track.sampleRate == 48_000)
        #expect(track.videoRange == nil)
    }

    @Test func derivesHEVCCodecStrings() {
        #expect(ISOCodecStrings.hevc(hvcC: Box.sampleHvcC[...], sampleEntry: "hvc1") == "hvc1.2.4.L150.90")
        let main: [UInt8] = [1, 0x01, 0x60, 0, 0, 0, 0xB0, 0, 0, 0, 0, 0, 93]
        #expect(ISOCodecStrings.hevc(hvcC: main[...], sampleEntry: "hvc1") == "hvc1.1.6.L93.B0")
        let highTier: [UInt8] = [1, 0x62, 0x20, 0, 0, 0, 0x90, 0, 0, 0, 0, 0x01, 120]
        #expect(ISOCodecStrings.hevc(hvcC: highTier[...], sampleEntry: "hev1") == "hev1.A2.4.H120.90.00.00.00.00.01")
        let noConstraints: [UInt8] = [1, 0x01, 0x60, 0, 0, 0, 0, 0, 0, 0, 0, 0, 90]
        #expect(ISOCodecStrings.hevc(hvcC: noConstraints[...], sampleEntry: "hvc1") == "hvc1.1.6.L90")
        #expect(ISOCodecStrings.hevc(hvcC: [1, 2, 3][...], sampleEntry: "hvc1") == nil)
    }

    @Test func derivesAVCCodecStrings() {
        #expect(ISOCodecStrings.avc(avcC: [1, 0x64, 0x00, 0x28, 0xFF][...], sampleEntry: "avc1") == "avc1.640028")
        #expect(ISOCodecStrings.avc(avcC: [1, 0x4D, 0x40, 0x1F][...], sampleEntry: "avc3") == "avc3.4D401F")
        #expect(ISOCodecStrings.avc(avcC: [0, 0x64, 0x00, 0x28][...], sampleEntry: "avc1") == nil)
        #expect(ISOCodecStrings.avc(avcC: [1, 0x64][...], sampleEntry: "avc1") == nil)
    }

    @Test func derivesAACFromESDS() throws {
        let esds = { (specific: [UInt8], objectType: UInt8) -> ISOAudioConfig? in
            let box = Box.esds(objectType: objectType, specific: specific)
            return ISOCodecStrings.mpeg4Audio(esds: box[8...])
        }
        #expect(esds([0x12, 0x10], 0x40) == ISOAudioConfig(codecs: "mp4a.40.2", channels: 2, sampleRate: 44_100))
        #expect(esds([0x29, 0x90], 0x40) == ISOAudioConfig(codecs: "mp4a.40.5", channels: 2, sampleRate: 48_000))
        #expect(esds([0xF9, 0x46, 0x40], 0x40)?.codecs == "mp4a.40.42")
        #expect(esds([0x11, 0xB0], 0x40)?.channels == 6)
        #expect(esds([0x11, 0xB8], 0x40)?.channels == 8)
        #expect(esds([], 0x6B)?.codecs == "mp4a.6B")
        #expect(ISOCodecStrings.mpeg4Audio(esds: [0, 0, 0, 0, 0x03][...]) == nil)
        #expect(ISOCodecStrings.mpeg4Audio(esds: [][...]) == nil)
    }

    @Test func mapsColourTransferToVideoRange() {
        let colr = { (transfer: UInt16) in
            ISOCodecStrings.transferCharacteristics(colr: Box.colr(transfer: transfer)[8...])
        }
        #expect(colr(16) == 16)
        #expect(HLSVideoRange(transferCharacteristics: 16) == .perceptualQuantizer)
        #expect(HLSVideoRange(transferCharacteristics: 18) == .hlg)
        #expect(HLSVideoRange(transferCharacteristics: 1) == .sdr)
        #expect(HLSVideoRange(transferCharacteristics: 14) == .sdr)
        let nclc: [UInt8] = Array("nclc".utf8) + [0, 9, 0, 18, 0, 9]
        #expect(ISOCodecStrings.transferCharacteristics(colr: nclc[...]) == 18)
        let profile: [UInt8] = Array("prof".utf8) + [0, 9, 0, 18, 0, 9]
        #expect(ISOCodecStrings.transferCharacteristics(colr: profile[...]) == nil)
        #expect(ISOCodecStrings.transferCharacteristics(colr: [0x6E][...]) == nil)
    }

    @Test func countsDolbyChannels() {
        #expect(ISOCodecStrings.ac3Channels(dac3: [0x10, 0x3D, 0xE0][...]) == 6)
        #expect(ISOCodecStrings.eac3Channels(dec3: [0x03, 0x00, 0x20, 0x0F, 0x02, 0x80][...]) == 8)
        #expect(ISOCodecStrings.ac3Channels(dac3: [0x10][...]) == nil)
        #expect(ISOCodecStrings.eac3Channels(dec3: [0x03, 0x00, 0x20][...]) == nil)
    }

    @Test func readsSyntheticInitSegments() throws {
        let avcC = Box.make("avcC", [1, 0x64, 0x00, 0x28, 0xFF])
        let videoEntry = Box.visualEntry("avc1", width: 1_920, height: 1_080, children: avcC + Box.colr(transfer: 1))
        let video = Box.initSegment(handler: "vide", timescale: 30_000, trackID: 3, entry: videoEntry,
                                    trexDuration: 1_001)
        let videoTrack = try #require(ISOInitSegment.tracks(in: Data(video)).first)
        #expect(videoTrack.codecs == "avc1.640028")
        #expect(videoTrack.videoRange == .sdr)
        #expect(videoTrack.width == 1_920 && videoTrack.height == 1_080)
        #expect(videoTrack.trackID == 3)
        #expect(videoTrack.timescale == 30_000)
        #expect(videoTrack.defaultSampleDuration == 1_001)

        let dec3 = Box.make("dec3", [0x03, 0x00, 0x20, 0x0F, 0x02, 0x80])
        let audioEntry = Box.audioEntry("ec-3", channels: 2, sampleRate: 48_000, children: dec3)
        let audio = Box.initSegment(handler: "soun", timescale: 48_000, entry: audioEntry)
        let audioTrack = try #require(ISOInitSegment.tracks(in: Data(audio)).first)
        #expect(audioTrack.codecs == "ec-3")
        #expect(audioTrack.audioChannels == 8)
        #expect(audioTrack.sampleRate == 48_000)

        let hevcEntry = Box.visualEntry("hvc1", width: 3_840, height: 2_160,
                                        children: Box.make("hvcC", Box.sampleHvcC) + Box.colr(transfer: 18))
        let hevc = Box.initSegment(handler: "vide", timescale: 60_000, entry: hevcEntry)
        let hevcTrack = try #require(ISOInitSegment.tracks(in: Data(hevc)).first)
        #expect(hevcTrack.codecs == "hvc1.2.4.L150.90")
        #expect(hevcTrack.videoRange == .hlg)
    }

    @Test func measuresFrameRateFromFragments() {
        let steady = Box.fragment(durations: Array(repeating: 1_001, count: 24))
        #expect(ISOFragment.frameRate(in: Data(steady), trackID: 1, timescale: 24_000, defaultDuration: nil)
                == 24_000.0 / 1_001.0)
        let pal = Box.fragment(durations: Array(repeating: 3_600, count: 50))
        #expect(ISOFragment.frameRate(in: Data(pal), trackID: 1, timescale: 90_000, defaultDuration: nil) == 25)
        let jittered = Box.fragment(durations: [984, 1_018, 1_008, 994, 1_001, 1_001])
        #expect(ISOFragment.frameRate(in: Data(jittered), trackID: nil, timescale: 24_000, defaultDuration: nil)
                == 24_000.0 / 1_001.0)
        #expect(ISOFragment.frameRate(in: Data(steady), trackID: 2, timescale: 24_000, defaultDuration: nil) == nil)
        let odd = Box.fragment(durations: Array(repeating: 1_000, count: 10))
        #expect(ISOFragment.frameRate(in: Data(odd), trackID: 1, timescale: 17_000, defaultDuration: nil) == 17)
        let truncated = Array(steady.prefix(steady.count - 60))
        #expect(ISOFragment.frameRate(in: Data(truncated), trackID: 1, timescale: 24_000, defaultDuration: nil)
                == 24_000.0 / 1_001.0)
        let tfhd = Box.full("tfhd", flags: 0x02_0000, Box.be32(1))
        let trun = Box.full("trun", flags: 0x0001, Box.be32(30) + Box.be32(0))
        let defaults = Box.make("moof", Box.make("traf", tfhd + trun))
        #expect(ISOFragment.frameRate(in: Data(defaults), trackID: 1, timescale: 30_000, defaultDuration: 1_001)
                == 30_000.0 / 1_001.0)
        #expect(ISOFragment.frameRate(in: Data(defaults), trackID: 1, timescale: 30_000, defaultDuration: nil) == nil)
        #expect(ISOFragment.frameRate(in: Data(steady), trackID: 1, timescale: 0, defaultDuration: nil) == nil)
    }

    @Test func readerHandlesOddBoxSizes() {
        let toEnd = Box.be32(0) + Array("mdat".utf8) + [1, 2, 3]
        let toEndBoxes = ISOBMFFReader(bytes: toEnd).boxes(in: 0..<toEnd.count)
        #expect(toEndBoxes == [ISOBox(type: "mdat", payload: 8..<11, isTruncated: false)])
        let large = Box.be32(1) + Array("free".utf8) + [0, 0, 0, 0, 0, 0, 0, 20] + [9, 9, 9, 9]
        let largeBoxes = ISOBMFFReader(bytes: large).boxes(in: 0..<large.count)
        #expect(largeBoxes == [ISOBox(type: "free", payload: 16..<20, isTruncated: false)])
        let tooSmall = Box.be32(4) + Array("free".utf8)
        #expect(ISOBMFFReader(bytes: tooSmall).boxes(in: 0..<tooSmall.count).isEmpty)
        let overlong = Box.be32(1_000) + Array("moof".utf8) + [1, 2]
        #expect(ISOBMFFReader(bytes: overlong).boxes(in: 0..<overlong.count).first?.isTruncated == true)
        let huge = Box.be32(1) + Array("free".utf8) + [0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF, 0xFF]
        #expect(ISOBMFFReader(bytes: huge).boxes(in: 0..<huge.count).isEmpty)
        let reader = ISOBMFFReader(bytes: [1, 2, 3])
        #expect(reader.boxes(in: 0..<10).isEmpty)
        #expect(reader.uint32(at: 0) == nil)
        #expect(reader.uint16(at: 2) == nil)
        #expect(reader.uint8(at: -1) == nil)
        #expect(reader.fourCC(at: 0) == nil)
        #expect(ISOBMFFReader(bytes: [0x41, 0x00, 0x7F, 0x42]).fourCC(at: 0) == "A??B")
    }
}
