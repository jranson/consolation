//
//  BitFieldTests.swift
//  MPEGTSTests
//
//  The bit-field tests that catch the bugs a transport stream parser most easily gets wrong (operator precedence and
//  masking), plus CRCs and timestamps.
//

import Foundation
import Testing
@testable import MPEGTS

struct BitFieldTests {
    @Test func patSectionLengthIs13Not45069() {
        // On-air PAT bytes start `00 b0 0d`: `(b1 << 8) | b2 & 0x0FFF`, which masks only the low byte, gives 45069.
        #expect(ByteField.u12(0xB0, 0x0D) == 13)
        #expect(ByteField.u12(0xB0, 0x0D) != 45_069)
    }

    @Test func pmtPIDIs0x30Not0xE030() {
        #expect(ByteField.u13(0xE0, 0x30) == 0x0030)
        #expect(ByteField.u13(0xFF, 0xFF) == 0x1FFF)
    }

    @Test func timestampDecodesExactly() {
        for value: Int64 in [0, 1, 90_000, 0x1_2345_6789, (1 << 33) - 1, 8_078_709_674] {
            let bytes = PSIFixtures.timestamp(prefix: 0x2, value)
            let decoded = bytes.withUnsafeBufferPointer { ByteField.timestamp($0, at: 0) }
            #expect(decoded == value)
        }
        let short: [UInt8] = [0x21, 0x00, 0x01, 0x00]
        #expect(short.withUnsafeBufferPointer { ByteField.timestamp($0, at: 0) } == nil)
    }

    @Test func pcrDecodes() {
        var writer = TSWriter()
        let pcr: Int64 = 2_423_612_345_678
        writer.packetize(pid: 0x31, payload: [1, 2, 3], flags: AdaptationFlags(pcr: pcr))
        let decoded = writer.bytes.withUnsafeBufferPointer { ByteField.pcr($0, at: 6) }
        #expect(decoded == pcr)
    }

    @Test func bitReaderReadsFieldsAndFlagsOverrun() {
        let bytes: [UInt8] = [0b1010_1100, 0b0101_0011, 0xFF]
        bytes.withUnsafeBufferPointer { pointer in
            var reader = BitReader(pointer)
            #expect(reader.int(3) == 0b101)
            #expect(reader.int(7) == 0b0110001)
            #expect(reader.flag() == false)
            #expect(reader.int(5) == 0b10011)
            #expect(!reader.isOverrun)
            #expect(reader.int(9) == 0)
            #expect(reader.isOverrun)
            #expect(reader.int(1) == 0)
        }
        bytes.withUnsafeBufferPointer { pointer in
            var reader = BitReader(pointer, offset: 2, count: 50)
            #expect(reader.byte() == 0xFF)
            #expect(reader.remainingBits == 0)
            var outside = BitReader(pointer, offset: 9)
            #expect(outside.int(1) == 0)
            #expect(outside.isOverrun)
        }
    }

    @Test func crc32MPEG2CheckValue() {
        let check = Array("123456789".utf8)
        #expect(CRC32MPEG2.checksum(check) == 0x0376_E6E7)
        #expect(ReferenceCRC.crc32MPEG2(check) == 0x0376_E6E7)
        let section = PSIFixtures.pat(programs: [(1, 0x30)])
        #expect(CRC32MPEG2.checksum(section) == 0)
    }

    @Test func crc16CheckValueAndSlicingMatchesBitwise() {
        let check = Array("123456789".utf8)
        #expect(CRC16AC3.checksum(check) == 0xFEE8)
        var random = SeededGenerator(seed: 16)
        for length in [0, 1, 7, 8, 9, 15, 16, 17, 100, 1535] {
            let bytes = random.bytes(length)
            #expect(CRC16AC3.checksum(bytes) == ReferenceCRC.crc16(bytes))
        }
    }

    @Test func unwrapCrossesThe33BitWrap() {
        let period = Timestamp33.period
        #expect(Timestamp33.unwrap(100, near: period - 1000) == period + 100)
        #expect(Timestamp33.unwrap(period - 1000, near: period + 100) == period - 1000)
        #expect(Timestamp33.unwrap(5000, near: 2 * period + 3000) == 2 * period + 5000)
        #expect(Timestamp33.unwrap(3000, near: 9009) == 3000)
    }

    @Test func sampleAspectRatio() {
        let standard = MPEG2SequenceInfo(width: 704, height: 480, aspectRatioCode: 3,
                                         frameRate: MPEG2Rational(30000, 1001), progressiveSequence: false,
                                         chromaFormat: 1, profileAndLevel: 0x48, bitRate: 0)
        #expect(standard.sampleAspectRatio == MPEG2Rational(40, 33))
        var wide = standard
        wide.width = 1920
        wide.height = 1080
        #expect(wide.sampleAspectRatio == MPEG2Rational(1, 1))
        wide.aspectRatioCode = 1
        #expect(wide.sampleAspectRatio == MPEG2Rational(1, 1))
    }
}
