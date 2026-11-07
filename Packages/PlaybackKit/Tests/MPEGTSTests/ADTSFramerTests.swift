//
//  ADTSFramerTests.swift
//  MPEGTSTests
//
//  AAC in ADTS (stream_type 0x0F): headers, frames across PES boundaries and their timestamps, garbage that looks
//  like a syncword, and the explicit SBR config written for HE-AAC that only its payload shows.
//

import Foundation
@testable import MPEGTS
import Testing

struct ADTSFramerTests {
    /// An ADTS frame around `payload`: `objectType` 2 is AAC LC, `rateIndex` 6 is 24 kHz, `channels` the channel
    /// configuration; `crc` adds the two CRC bytes, `blocks` the raw data blocks.
    static func frame(_ payload: [UInt8], objectType: Int = 2, rateIndex: Int = 6, channels: Int = 2,
                      crc: Bool = false, blocks: Int = 1) -> [UInt8] {
        let length = (crc ? 9 : 7) + payload.count
        let header: [UInt8] = [
            0xFF, crc ? 0xF0 : 0xF1,
            UInt8(((objectType - 1) << 6) | (rateIndex << 2) | (channels >> 2)),
            UInt8(((channels & 0x03) << 6) | (length >> 11)),
            UInt8((length >> 3) & 0xFF),
            // The frame length's last three bits, then buffer fullness 0x7FF (variable rate) and the block count.
            UInt8(((length & 0x07) << 5) | 0x1F), UInt8(0xFC | (blocks - 1))
        ]
        return header + (crc ? [0x12, 0x34] : []) + payload
    }

    private static func pes(_ bytes: [UInt8], pts: Int64? = nil) -> PESPacket {
        PESPacket(pid: 0x101, streamID: 0xC0, pts: pts, payload: Data(bytes))
    }

    @Test func headers() throws {
        let bytes = Self.frame([UInt8](repeating: 0xAA, count: 20))
        let header = try #require(bytes.withUnsafeBufferPointer { ADTSHeader.parse($0, at: 0) })
        #expect(header.objectType == 2 && header.sampleRate == 24_000 && header.channelConfiguration == 2)
        #expect(header.frameLength == 27 && header.headerLength == 7 && header.rawDataBlocks == 1)
        // The plain config it names: LC, 24 kHz, stereo.
        #expect(header.config?.bytes == Data([0x13, 0x10]))
        let protected = Self.frame([1, 2, 3], crc: true)
        #expect(protected.withUnsafeBufferPointer { ADTSHeader.parse($0, at: 0) }?.headerLength == 9)
        #expect(Self.frame([1], channels: 0).withUnsafeBufferPointer { ADTSHeader.parse($0, at: 0) }?.config == nil)
        func rejects(_ bytes: [UInt8]) -> Bool { bytes.withUnsafeBufferPointer { ADTSHeader.parse($0, at: 0) } == nil }
        var layer = bytes
        layer[1] = 0xF3
        var rate = bytes
        rate[2] = (rate[2] & 0xC3) | (13 << 2)
        var sync = bytes
        sync[1] = 0xE1
        #expect(rejects(sync))
        #expect(rejects(layer))
        #expect(rejects(rate))
        // A frame no longer than its header, and too few bytes for a header.
        #expect(rejects(Self.frame([])))
        #expect(rejects(Array(bytes.prefix(6))))
    }

    @Test func framesAcrossPESBoundariesAndTheirTimestamps() {
        let first = Self.frame([UInt8](repeating: 1, count: 40))
        let second = Self.frame([UInt8](repeating: 2, count: 50))
        let third = Self.frame([UInt8](repeating: 3, count: 30), crc: true)
        var framer = ADTSFramer()
        let split = first.count + 20
        let stream = first + second + third
        let early = framer.append(Self.pes(Array(stream[..<split]), pts: 9_000))
        // The second frame started in the first PES, so the second PES's PTS is the third frame's.
        let late = framer.append(Self.pes(Array(stream[split...]), pts: 9_000 + 2 * 3_840))
        #expect(early.map(\.pts) == [9_000])
        let lateTimes: [Int64] = [12_840, 16_680]
        #expect(late.map(\.pts) == lateTimes)
        #expect(early.first?.accessUnit == Data(repeating: 1, count: 40))
        #expect(late.map(\.accessUnit) == [Data(repeating: 2, count: 50), Data(repeating: 3, count: 30)])
        #expect(late.last?.frame == Data(third))
    }

    @Test func aSyncwordInGarbageIsSkipped() {
        // A plausible header whose length points at no next frame, then the real frames.
        let fake: [UInt8] = [0x00, 0xFF, 0xF1, 0x58, 0x80, 0x02, 0x1F, 0xFC, 0x55, 0x66, 0x77]
        let frames = (1...3).map { Self.frame([UInt8](repeating: UInt8($0), count: 24)) }
        var framer = ADTSFramer()
        let output = framer.append(Self.pes(fake + frames.flatMap { $0 }, pts: 0))
        #expect(output.map(\.frame) == frames.map { Data($0) })
        let times: [Int64] = [0, 3_840, 7_680]
        #expect(output.map(\.pts) == times)
    }

    @Test func framesBeforeTheFirstTimestampAreDropped() {
        var framer = ADTSFramer()
        let untimed = framer.append(Self.pes(Self.frame([1, 1, 1]) + Self.frame([2, 2, 2])))
        let timed = framer.append(Self.pes(Self.frame([3, 3, 3]), pts: 45_000))
        #expect(untimed.isEmpty && framer.droppedFrames == 2)
        #expect(timed.map(\.pts) == [45_000])
    }

    /// A frame of two raw data blocks can't be one decoder packet: it is dropped, and its 2048 samples still pass.
    @Test func severalRawDataBlocksAreDroppedButKeepTheirTime() {
        var framer = ADTSFramer()
        let bytes = Self.frame([1, 1]) + Self.frame([2, 2], blocks: 2) + Self.frame([3, 3]) + Self.frame([4, 4])
        let output = framer.append(Self.pes(bytes, pts: 90_000))
        let times: [Int64] = [90_000, 101_520, 105_360]
        #expect(output.map(\.pts) == times)
        #expect(framer.droppedFrames == 1)
    }

    @Test func aRateChangeKeepsEarlierTimes() {
        var framer = ADTSFramer()
        // Two frames at 24 kHz, then two at 48 kHz (index 3) from the same PES.
        let bytes = Self.frame([1]) + Self.frame([2]) + Self.frame([3], rateIndex: 3) + Self.frame([4], rateIndex: 3)
        let output = framer.append(Self.pes(bytes, pts: 0))
        let times: [Int64] = [0, 3_840, 7_680, 9_600]
        #expect(output.map(\.pts) == times)
    }

    @Test func sbrIsSignalledExplicitly() throws {
        let core = try #require(AudioSpecificConfig(objectType: 2, sampleRate: 24_000, channels: 2))
        #expect(core.profileName == "AAC")
        let sbr = try #require(core.signallingSBR(outputSampleRate: 48_000))
        #expect(sbr.bytes == Data([0x2B, 0x11, 0x88, 0x00]))
        #expect(AudioSpecificConfig(sbr.bytes) == sbr)
        #expect(sbr.profileName == "HE-AAC" && sbr.samplesPerFrame == 2_048 && sbr.outputSampleRate == 48_000)
        let mono = try #require(AudioSpecificConfig(objectType: 2, sampleRate: 24_000, channels: 1))
        let parametric = try #require(mono.signallingSBR(outputSampleRate: 48_000, parametricStereo: true))
        #expect(parametric.bytes == Data([0xEB, 0x09, 0x88, 0x00]))
        #expect(parametric.profileName == "HE-AAC v2")
        #expect(core.signallingSBR(outputSampleRate: 50_000) == nil)
    }
}
