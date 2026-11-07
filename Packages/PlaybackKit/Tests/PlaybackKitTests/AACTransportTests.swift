//
//  AACTransportTests.swift
//  PlaybackKitTests
//
//  AAC in MPEG-TS, as IPTV streams carry it: ADTS frames whose header names only the AAC core, the SBR (HE-AAC) and
//  PS (HE-AAC v2) read from their payload, the sample buffers the renderer gets (decoded here to prove AudioToolbox
//  takes them), and AAC tracks in a program. Fixtures are synthetic (scripts/make-test-fixtures.sh).
//

import AudioToolbox
import AVFoundation
import Foundation
import MPEGTS
import Testing
@testable import PlaybackKit

struct AACTransportTests {
    private static func fixture(_ name: String) throws -> Data {
        let url = try #require(Bundle.module.url(forResource: name, withExtension: "adts", subdirectory: "Fixtures"))
        return try Data(contentsOf: url)
    }

    private static func frames(_ name: String) throws -> [ADTSFrame] {
        var framer = ADTSFramer()
        return framer.append(PESPacket(pid: 0x101, streamID: 0xC0, pts: 0, payload: try fixture(name)))
    }

    @Test(arguments: [("aac-lc-24k", "AAC", 24_000), ("aac-he-48k", "HE-AAC", 48_000),
                      ("aac-he-v2-48k", "HE-AAC v2", 48_000)])
    func theProfileComesFromThePayload(name: String, profile: String, rate: Int) throws {
        let frames = try Self.frames(name)
        #expect(frames.count >= 6)
        // Every header says a 24 kHz AAC LC core.
        #expect(frames.allSatisfy { $0.header.sampleRate == 24_000 && $0.header.objectType == 2 })
        let config = try #require(ADTSProfile.config(for: frames, final: false))
        #expect(config.profileName == profile && config.outputSampleRate == rate)
        // Out of frames to read: the header's plain AAC rather than nothing.
        #expect(ADTSProfile.config(for: Array(frames.prefix(1)), final: true) != nil)
    }

    @Test(arguments: [("aac-lc-24k", kAudioFormatMPEG4AAC, 24_000.0, 2),
                      ("aac-he-48k", kAudioFormatMPEG4AAC_HE, 48_000, 2),
                      ("aac-he-v2-48k", kAudioFormatMPEG4AAC_HE_V2, 48_000, 2)])
    func framesBatchedForTheRendererDecode(name: String, format: AudioFormatID, rate: Double, channels: Int) throws {
        let data = try Self.fixture(name)
        var processor = ElementaryProcessor()
        processor.select(video: nil, audio: ElementaryStream(pid: 0x101, streamType: 0x0F, kind: .aac))
        // One PES per 200 bytes, the first with a PTS: frames straddle PES boundaries.
        var samples: [CMSampleBuffer] = []
        for (index, start) in stride(from: 0, to: data.count, by: 200).enumerated() {
            let pes = PESPacket(pid: 0x101, streamID: 0xC0, pts: index == 0 ? 90_000 : nil,
                                payload: data.subdata(in: start..<min(start + 200, data.count)))
            samples += processor.audioSamples(from: pes)
        }
        if let last = processor.flushPendingAudio() { samples.append(last) }
        let description = try #require(samples.first?.formatDescription)
        let asbd = try #require(description.audioStreamBasicDescription)
        #expect(asbd.mFormatID == format && asbd.mSampleRate == rate && Int(asbd.mChannelsPerFrame) == channels)
        #expect(processor.audioChannels == channels)
        #expect(samples.first?.presentationTimeStamp == CMTime(value: 90_000, timescale: 90_000))
        let packets = samples.reduce(0) { $0 + $1.numSamples }
        #expect(packets == (try Self.frames(name)).count)
        // Every packet decodes (the decoder may hold back its last one or two).
        let decoded = try Self.decode(samples)
        #expect(decoded.rate == rate && decoded.frames >= AVAudioFrameCount(packets - 2) * asbd.mFramesPerPacket)
    }

    @Test func theStreamInfoNamesTheProfile() throws {
        let data = try Self.fixture("aac-he-48k")
        var processor = ElementaryProcessor()
        processor.select(video: nil, audio: ElementaryStream(pid: 0x101, streamType: 0x0F, kind: .aac))
        #expect(processor.audioCodecName == "AAC")
        _ = processor.audioSamples(from: PESPacket(pid: 0x101, streamID: 0xC0, pts: 0, payload: data))
        #expect(processor.audioCodecName == "HE-AAC")
        // Another track starts over: no channels until its first frame.
        processor.select(video: nil, audio: ElementaryStream(pid: 0x102, streamType: 0x87, kind: .eac3))
        #expect(processor.audioCodecName == "E-AC-3" && processor.audioChannels == nil)
    }

    @Test func programsPlayTheirAACTracks() {
        func program(_ streams: [ElementaryStream]) -> ProgramMap {
            ProgramMap(programNumber: 1, pmtPID: 0x1000, pcrPID: 0x100,
                       streams: [ElementaryStream(pid: 0x100, streamType: 0x1B, kind: .h264)] + streams)
        }
        let aac = ElementaryStream(pid: 0x101, streamType: 0x0F, kind: .aac, language: "eng")
        let spanishDolby = ElementaryStream(pid: 0x102, streamType: 0x81, kind: .ac3, language: "spa")
        let englishDolby = ElementaryStream(pid: 0x103, streamType: 0x81, kind: .ac3, language: "eng")
        let only = program([aac])
        #expect(TrackSelection.audio(in: only, preferredLanguage: "eng")?.pid == 0x101)
        #expect(TrackSelection.audioOptions(in: only).map(\.codec) == ["AAC"])
        #expect(TrackSelection.unsupportedAudioCodec(in: only) == nil)
        // The language first, then Dolby before AAC.
        #expect(TrackSelection.audio(in: program([aac, spanishDolby]), preferredLanguage: "eng")?.pid == 0x101)
        #expect(TrackSelection.audio(in: program([aac, englishDolby]), preferredLanguage: "eng")?.pid == 0x103)
        #expect(TrackSelection.audio(in: program([aac, spanishDolby]), preferredLanguage: "fre")?.pid == 0x102)
    }

    /// Decodes the buffers with AudioToolbox, as the audio renderer would: the output rate and frames.
    private static func decode(_ samples: [CMSampleBuffer]) throws -> (rate: Double, frames: AVAudioFrameCount) {
        let description = try #require(samples.first?.formatDescription)
        let input = AVAudioFormat(cmAudioFormatDescription: description)
        let output = try #require(AVAudioFormat(standardFormatWithSampleRate: input.sampleRate, channels: 2))
        let converter = try #require(AVAudioConverter(from: input, to: output))
        let pcm = try #require(AVAudioPCMBuffer(pcmFormat: output, frameCapacity: 48_000))
        var pending = samples
        var error: NSError?
        let status = converter.convert(to: pcm, error: &error) { _, inputStatus in
            guard !pending.isEmpty else {
                inputStatus.pointee = .endOfStream
                return nil
            }
            let sample = pending.removeFirst()
            inputStatus.pointee = .haveData
            return Self.compressedBuffer(sample, format: input)
        }
        #expect(status != .error, "\(String(describing: error))")
        return (output.sampleRate, pcm.frameLength)
    }

    private static func compressedBuffer(_ sample: CMSampleBuffer, format: AVAudioFormat) -> AVAudioCompressedBuffer? {
        guard let block = sample.dataBuffer, let packets = try? sample.audioStreamPacketDescriptions() else {
            return nil
        }
        let buffer = AVAudioCompressedBuffer(format: format, packetCapacity: AVAudioPacketCount(packets.count),
                                             maximumPacketSize: 8_192)
        let length = block.dataLength
        guard (try? block.copyDataBytes(to: UnsafeMutableRawBufferPointer(start: buffer.data, count: length))) != nil
        else { return nil }
        for (index, packet) in packets.enumerated() { buffer.packetDescriptions?[index] = packet }
        buffer.packetCount = AVAudioPacketCount(packets.count)
        buffer.byteLength = UInt32(length)
        return buffer
    }
}
