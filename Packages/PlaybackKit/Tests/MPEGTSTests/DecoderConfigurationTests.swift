//
//  DecoderConfigurationTests.swift
//  MPEGTSTests
//
//  `avcC` and `hvcC` records (ISO/IEC 14496-15), length-prefixed samples to Annex B, and MPEG-4 Audio's
//  AudioSpecificConfig, as Matroska's CodecPrivate carries them.
//

import Foundation
@testable import MPEGTS
import Testing

struct DecoderConfigurationTests {
    static let sps: [UInt8] = [0x67, 0x64, 0x00, 0x1F]
    static let pps: [UInt8] = [0x68, 0xEE, 0x3C, 0x80]

    /// An avcC with one SPS and one PPS and `lengthSize`-byte NAL lengths.
    static func avcC(lengthSize: Int = 4) -> [UInt8] {
        [1, 0x64, 0x00, 0x1F, 0xFC | UInt8(lengthSize - 1), 0xE1, 0, UInt8(sps.count)] + sps
            + [1, 0, UInt8(pps.count)] + pps
    }

    @Test func avcRecords() throws {
        let config = try #require(NALDecoderConfiguration.avc(Data(Self.avcC())))
        #expect(config.codec == .h264)
        #expect(config.lengthSize == 4)
        #expect(config.parameterSets == [Data(Self.sps), Data(Self.pps)])
        #expect(NALDecoderConfiguration.avc(Data(Self.avcC(lengthSize: 2)))?.lengthSize == 2)
        // Version 0, a three-byte length (not allowed), a truncated set, no sets at all.
        #expect(NALDecoderConfiguration.avc(Data([0] + Self.avcC().dropFirst())) == nil)
        #expect(NALDecoderConfiguration.avc(Data(Self.avcC(lengthSize: 3))) == nil)
        #expect(NALDecoderConfiguration.avc(Data(Self.avcC().dropLast(2))) == nil)
        #expect(NALDecoderConfiguration.avc(Data([1, 0x64, 0, 0x1F, 0xFF, 0xE0, 0])) == nil)
    }

    @Test func hevcRecordsKeepTheParameterSetArrays() throws {
        var record: [UInt8] = [1] + [UInt8](repeating: 0, count: 20) + [0xF3, 4]
        let arrays: [(type: UInt8, unit: [UInt8])] = [
            (32, [0x40, 0x01]), (33, [0x42, 0x01]), (34, [0x44, 0x01]), (39, [0x4E, 0x01])
        ]
        for (type, unit) in arrays {
            record += [type, 0, 1, 0, UInt8(unit.count)] + unit
        }
        let config = try #require(NALDecoderConfiguration.hevc(Data(record)))
        #expect(config.codec == .hevc && config.lengthSize == 4)
        // The SEI array (type 39) isn't a parameter set.
        #expect(config.parameterSets == [Data([0x40, 0x01]), Data([0x42, 0x01]), Data([0x44, 0x01])])
        #expect(NALDecoderConfiguration.hevc(Data(record.prefix(30))) == nil)
    }

    @Test func samplesBecomeAnnexB() throws {
        let config = try #require(NALDecoderConfiguration.avc(Data(Self.avcC())))
        let sample: [UInt8] = [0, 0, 0, 2, 0x65, 0x88, 0, 0, 0, 1, 0x06]
        var output: [UInt8] = [9]
        #expect(sample.withUnsafeBufferPointer { config.appendAnnexB($0, parameterSets: false, to: &output) })
        #expect(output == [9, 0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x06])
        output = []
        #expect(sample.withUnsafeBufferPointer { config.appendAnnexB($0, parameterSets: true, to: &output) })
        let startCode: [UInt8] = [0, 0, 0, 1]
        #expect(output == startCode + Self.sps + startCode + Self.pps + [0, 0, 0, 1, 0x65, 0x88, 0, 0, 0, 1, 0x06])
        let short = try #require(NALDecoderConfiguration.avc(Data(Self.avcC(lengthSize: 2))))
        output = []
        let twoByteLengths: [UInt8] = [0, 1, 0x41, 0, 2, 0x41, 0x9A]
        #expect(twoByteLengths.withUnsafeBufferPointer {
            short.appendAnnexB($0, parameterSets: false, to: &output)
        })
        #expect(output == [0, 0, 0, 1, 0x41, 0, 0, 0, 1, 0x41, 0x9A])
        // A length past the end leaves the output as it was.
        output = [7]
        let truncated: [UInt8] = [0, 0, 0, 9, 0x65]
        #expect(!truncated.withUnsafeBufferPointer {
            config.appendAnnexB($0, parameterSets: true, to: &output)
        })
        #expect(output == [7])
    }

    @Test func audioSpecificConfigs() throws {
        let plain = try #require(AudioSpecificConfig(Data([0x11, 0x90])))
        #expect(plain.objectType == 2 && plain.sampleRate == 48_000 && plain.channelCount == 2)
        #expect(plain.samplesPerFrame == 1_024 && plain.outputSampleRate == 48_000)
        #expect(plain.extensionObjectType == nil)
        // HE-AAC with explicit SBR signalling: 24 kHz core, 48 kHz out.
        let sbr = try #require(AudioSpecificConfig(Data([0x2B, 0x11, 0x88, 0x00])))
        #expect(sbr.objectType == 2 && sbr.sampleRate == 24_000 && sbr.extensionSampleRate == 48_000)
        #expect(sbr.extensionObjectType == 5 && sbr.samplesPerFrame == 2_048 && sbr.outputSampleRate == 48_000)
        // HE-AAC v2 (parametric stereo) from a mono core.
        let stereo = try #require(AudioSpecificConfig(Data([0xEB, 0x09, 0x88, 0x00])))
        #expect(stereo.extensionObjectType == 29 && stereo.channelCount == 1)
        // A rate given explicitly (index 15, then 24 bits).
        let explicit = try #require(AudioSpecificConfig(Data([0x17, 0x80, 0x5D, 0xC0, 0x10])))
        #expect(explicit.sampleRate == 48_000 && explicit.channelConfiguration == 2)
        #expect(AudioSpecificConfig(Data()) == nil)
        #expect(AudioSpecificConfig(Data([0x16, 0x90])) == nil)
        #expect(AudioSpecificConfig(Data([0x11])) == nil)
    }

    @Test func audioSpecificConfigsWrittenFromFacts() throws {
        let written = try #require(AudioSpecificConfig(sampleRate: 44_100, channels: 2))
        #expect(written.bytes == Data([0x12, 0x10]))
        #expect(AudioSpecificConfig(written.bytes) == written)
        #expect(AudioSpecificConfig(sampleRate: 48_000, channels: 8)?.channelConfiguration == 7)
        #expect(AudioSpecificConfig(sampleRate: 44_000, channels: 2) == nil)
    }
}
