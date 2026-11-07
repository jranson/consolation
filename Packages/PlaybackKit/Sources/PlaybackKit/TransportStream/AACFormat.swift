//
//  AACFormat.swift
//  PlaybackKit
//
//  AAC for the audio renderer: a format description whose magic cookie is the stream's AudioSpecificConfig wrapped
//  in an MPEG-4 ES_Descriptor (ISO/IEC 14496-1 §7.2.6.5), the form an `esds` box carries and AudioToolbox's AAC
//  decoder reads; raw access units (Matroska's AAC frames, ADTS frames without their headers) batched into sample
//  buffers; and the SBR an ADTS stream shows only in its payload.
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
        append(Data(buffer: frame), pts: pts)
    }

    mutating func append(_ frame: Data, pts: Int64) -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        if !frames.isEmpty, abs(pts - (firstPTS + Int64(frames.count) * frameTicks)) > frameTicks / 2,
           let sample = flush() {
            output.append(sample)
        }
        if frames.isEmpty { firstPTS = pts }
        frames.append(frame)
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

/// Whether an ADTS stream is HE-AAC. Its header names only the AAC core (a 24 kHz LC core for 48 kHz HE-AAC); SBR
/// and PS show in the payload, which AudioToolbox's own ADTS parser reads, usually from the first frame (not from an
/// encoder's tiny priming frame). Decoding HE-AAC as its core loses everything above half the output rate.
nonisolated enum ADTSProfile {
    /// Frames to read for the profile before settling for the header's plain AAC.
    static let maximumFrames = 8

    /// The config to decode the stream of `frames` (its first, of one format) with: the header's, with SBR or PS
    /// signalled when the payload carries them. Nil while AudioToolbox can't tell yet and more frames may come
    /// (unless `final`), or when the header leaves the layout to a program config element.
    static func config(for frames: [ADTSFrame], final: Bool) -> AudioSpecificConfig? {
        guard let core = frames.first?.header.config else { return nil }
        var bytes = Data()
        for frame in frames { bytes.append(frame.frame) }
        guard let richest = formats(of: bytes).first else { return final ? core : nil }
        let rate = Int(richest.mSampleRate)
        switch richest.mFormatID {
        case kAudioFormatMPEG4AAC_HE_V2:
            return core.signallingSBR(outputSampleRate: rate, parametricStereo: true) ?? core
        case kAudioFormatMPEG4AAC_HE:
            return core.signallingSBR(outputSampleRate: rate) ?? core
        default:
            return core
        }
    }

    /// The formats AudioToolbox reads in whole ADTS frames, richest first (HE-AAC before its AAC core).
    static func formats(of frame: Data) -> [AudioStreamBasicDescription] {
        let list = FormatList()
        var stream: AudioFileStreamID?
        let opened = AudioFileStreamOpen(Unmanaged.passUnretained(list).toOpaque(), { context, stream, property, _ in
            guard property == kAudioFileStreamProperty_FormatList else { return }
            Unmanaged<FormatList>.fromOpaque(context).takeUnretainedValue().read(from: stream)
        }, { _, _, _, _, _ in }, kAudioFileAAC_ADTSType, &stream)
        guard opened == noErr, let stream else { return [] }
        defer { AudioFileStreamClose(stream) }
        // The listener runs during the parse, while `list` is alive.
        _ = frame.withUnsafeBytes { raw in
            AudioFileStreamParseBytes(stream, UInt32(raw.count), raw.baseAddress, [])
        }
        return list.formats
    }

    private final class FormatList {
        var formats: [AudioStreamBasicDescription] = []

        func read(from stream: AudioFileStreamID) {
            var size: UInt32 = 0
            guard AudioFileStreamGetPropertyInfo(stream, kAudioFileStreamProperty_FormatList, &size, nil) == noErr
            else { return }
            let count = Int(size) / MemoryLayout<AudioFormatListItem>.stride
            guard count > 0 else { return }
            var items = [AudioFormatListItem](repeating: AudioFormatListItem(), count: count)
            guard AudioFileStreamGetProperty(stream, kAudioFileStreamProperty_FormatList, &size, &items) == noErr
            else { return }
            formats = items.prefix(Int(size) / MemoryLayout<AudioFormatListItem>.stride).map(\.mASBD)
        }
    }
}
