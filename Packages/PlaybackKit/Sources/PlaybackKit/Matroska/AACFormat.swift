//
//  AACFormat.swift
//  PlaybackKit
//
//  AAC for the audio renderer: a format description whose magic cookie is the stream's AudioSpecificConfig wrapped
//  in an MPEG-4 ES_Descriptor (ISO/IEC 14496-1 §7.2.6.5), the form an `esds` box carries and AudioToolbox's AAC
//  decoder reads; and raw access units (Matroska's AAC frames) batched into sample buffers.
//

import AudioToolbox
import CoreMedia
import Foundation
import MPEGTS

nonisolated enum AACFormat {
    /// An AAC format description for `config`; `channels` stands in when the config leaves the layout to a program
    /// config element (channelConfiguration 0).
    static func description(_ config: AudioSpecificConfig, channels: Int) -> CMAudioFormatDescription? {
        let parametricStereo = config.extensionObjectType == AudioSpecificConfig.objectTypePS
        let formatID: AudioFormatID = parametricStereo ? kAudioFormatMPEG4AAC_HE_V2
            : config.extensionSampleRate != nil ? kAudioFormatMPEG4AAC_HE : kAudioFormatMPEG4AAC
        let count = parametricStereo ? 2 : (config.channelCount > 0 ? config.channelCount : max(channels, 1))
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(config.outputSampleRate), mFormatID: formatID, mFormatFlags: 0, mBytesPerPacket: 0,
            mFramesPerPacket: UInt32(config.samplesPerFrame), mBytesPerFrame: 0, mChannelsPerFrame: UInt32(count),
            mBitsPerChannel: 0, mReserved: 0)
        let cookie = esDescriptor(config.bytes)
        var description: CMAudioFormatDescription?
        let status = cookie.withUnsafeBytes { raw in
            CMAudioFormatDescriptionCreate(
                allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: raw.count,
                magicCookie: raw.baseAddress, extensions: nil, formatDescriptionOut: &description)
        }
        return status == noErr ? description : nil
    }

    /// ES_Descriptor (tag 3) holding a DecoderConfigDescriptor (tag 4: MPEG-4 Audio, an audio stream) with the
    /// config as its DecoderSpecificInfo (tag 5), and an SLConfigDescriptor (tag 6, predefined 2, as in MP4).
    static func esDescriptor(_ config: Data) -> Data {
        let specificInfo = descriptor(tag: 0x05, Array(config))
        // objectTypeIndication 0x40 (MPEG-4 Audio); streamType 5 (audio) << 2 | reserved 1; bufferSizeDB (24 bits),
        // maxBitrate and avgBitrate (32 bits each) unknown.
        let decoderConfig = descriptor(tag: 0x04, [0x40, 0x15] + [UInt8](repeating: 0, count: 11) + specificInfo)
        let slConfig = descriptor(tag: 0x06, [0x02])
        // ES_ID 0 and no flags (no dependence, URL or OCR stream).
        return Data(descriptor(tag: 0x03, [0, 0, 0] + decoderConfig + slConfig))
    }

    /// A descriptor: its tag, its length in four 7-bit groups (each but the last with the continuation bit), then
    /// its body.
    private static func descriptor(tag: UInt8, _ body: [UInt8]) -> [UInt8] {
        let size = body.count
        let length: [UInt8] = [
            0x80 | UInt8((size >> 21) & 0x7F), 0x80 | UInt8((size >> 14) & 0x7F), 0x80 | UInt8((size >> 7) & 0x7F),
            UInt8(size & 0x7F)
        ]
        return [tag] + length + body
    }
}

/// Batches AAC access units into audio sample buffers with packet descriptions, as `ElementaryProcessor` batches
/// AC-3 frames: a few per buffer, and a new buffer wherever the timestamps don't run on.
nonisolated struct AACSampleBatcher {
    /// Access units per sample buffer (about 85 ms at 48 kHz).
    static let framesPerSample = 4

    let format: CMAudioFormatDescription
    /// 90 kHz ticks per access unit.
    let frameTicks: Int64
    let pool: SampleMemoryPool
    private var frames: [Data] = []
    private var firstPTS: Int64 = 0

    init?(config: AudioSpecificConfig, channels: Int, pool: SampleMemoryPool) {
        guard let format = AACFormat.description(config, channels: channels) else { return nil }
        self.format = format
        frameTicks = Int64(config.samplesPerFrame) * 90_000 / Int64(max(config.outputSampleRate, 1))
        self.pool = pool
    }

    /// Adds one access unit presented at `pts` and returns any buffers completed.
    mutating func append(_ frame: UnsafeBufferPointer<UInt8>, pts: Int64) -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        if !frames.isEmpty, abs(pts - (firstPTS + Int64(frames.count) * frameTicks)) > frameTicks / 2,
           let sample = flush() {
            output.append(sample)
        }
        if frames.isEmpty { firstPTS = pts }
        frames.append(Data(buffer: frame))
        if frames.count >= Self.framesPerSample, let sample = flush() { output.append(sample) }
        return output
    }

    /// The units batched so far, as one buffer (the end of a stream, or before a gap).
    mutating func flush() -> CMSampleBuffer? {
        defer { frames.removeAll(keepingCapacity: true) }
        guard !frames.isEmpty else { return nil }
        return SampleFormats.audioSample(frames: frames, format: format, pts: firstPTS, pool: pool)
    }

    mutating func reset() {
        frames.removeAll(keepingCapacity: true)
    }
}
