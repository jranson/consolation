//
//  SampleFormats.swift
//  PlaybackKit
//
//  Builds CoreMedia format descriptions and sample buffers from demuxed elementary-stream data. Every buffer is
//  CoreMedia-owned (copied in), never wrapping Swift memory with a freeing allocator, which would free memory that
//  Swift frees too.
//
//  MPEG-2 video samples hold libavcodec's zeroed input padding after the picture, inside the block buffer's data
//  (`LibavVideoDecoder.inputPadding`), and declare a sample size without it. Anything that reads a video sample's
//  bytes must use the sample size (`CMSampleBufferGetSampleSize`), never the block buffer's data length.
//

import CoreMedia
import Foundation
import MPEGTS

nonisolated enum SampleFormats {
    static let timescale: CMTimeScale = 90_000

    static func time(_ ticks: Int64?) -> CMTime {
        guard let ticks else { return .invalid }
        return CMTime(value: ticks, timescale: timescale)
    }

    /// An MPEG-2 video format description from the parsed sequence header. Never guess a size: VideoToolbox scales
    /// its output to whatever size the description claims.
    static func mpeg2Video(width: Int, height: Int, interlaced: Bool, topFieldFirst: Bool,
                           pixelAspect: (Int, Int)?) -> CMVideoFormatDescription? {
        var extensions: [CFString: Any] = [
            kCMFormatDescriptionExtension_ColorPrimaries: kCMFormatDescriptionColorPrimaries_ITU_R_709_2,
            kCMFormatDescriptionExtension_TransferFunction: kCMFormatDescriptionTransferFunction_ITU_R_709_2,
            kCMFormatDescriptionExtension_YCbCrMatrix: kCMFormatDescriptionYCbCrMatrix_ITU_R_709_2
        ]
        if interlaced {
            extensions[kCMFormatDescriptionExtension_FieldCount] = 2
            extensions[kCMFormatDescriptionExtension_FieldDetail] = topFieldFirst
                ? kCMFormatDescriptionFieldDetail_TemporalTopFirst
                : kCMFormatDescriptionFieldDetail_TemporalBottomFirst
        }
        if let pixelAspect, pixelAspect.0 > 0, pixelAspect.1 > 0 {
            extensions[kCMFormatDescriptionExtension_PixelAspectRatio] = [
                kCMFormatDescriptionKey_PixelAspectRatioHorizontalSpacing: pixelAspect.0,
                kCMFormatDescriptionKey_PixelAspectRatioVerticalSpacing: pixelAspect.1
            ]
        }
        var description: CMVideoFormatDescription?
        let status = CMVideoFormatDescriptionCreate(
            allocator: nil, codecType: kCMVideoCodecType_MPEG2Video, width: Int32(width), height: Int32(height),
            extensions: extensions as CFDictionary, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    /// An H.264 or HEVC format description from the stream's parameter sets (H.264 SPS and PPSs; HEVC VPS, SPS and
    /// PPSs), for 4-byte length-prefixed samples. CoreMedia reads the size, aspect ratio and colour from the SPS.
    static func parameterSetVideo(codec: NALVideoCodec, parameterSets: [Data]) -> CMVideoFormatDescription? {
        guard !parameterSets.isEmpty, parameterSets.allSatisfy({ !$0.isEmpty }) else { return nil }
        let sizes = parameterSets.map(\.count)
        let joined = parameterSets.reduce(into: [UInt8]()) { $0.append(contentsOf: $1) }
        return joined.withUnsafeBufferPointer { buffer -> CMVideoFormatDescription? in
            guard let base = buffer.baseAddress else { return nil }
            var pointers: [UnsafePointer<UInt8>] = []
            var offset = 0
            for size in sizes {
                pointers.append(base + offset)
                offset += size
            }
            var description: CMFormatDescription?
            let status = switch codec {
            case .h264:
                CMVideoFormatDescriptionCreateFromH264ParameterSets(
                    allocator: nil, parameterSetCount: sizes.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, formatDescriptionOut: &description)
            case .hevc:
                CMVideoFormatDescriptionCreateFromHEVCParameterSets(
                    allocator: nil, parameterSetCount: sizes.count, parameterSetPointers: pointers,
                    parameterSetSizes: sizes, nalUnitHeaderLength: 4, extensions: nil,
                    formatDescriptionOut: &description)
            }
            return status == noErr ? description : nil
        }
    }

    /// An AC-3 or E-AC-3 audio format description (no magic cookie needed; verified with AVSampleBufferAudioRenderer).
    static func dolbyAudio(sampleRate: Int, channels: Int, isEAC3: Bool,
                           samplesPerFrame: Int) -> CMAudioFormatDescription? {
        var asbd = AudioStreamBasicDescription(
            mSampleRate: Float64(sampleRate), mFormatID: isEAC3 ? kAudioFormatEnhancedAC3 : kAudioFormatAC3,
            mFormatFlags: 0, mBytesPerPacket: 0, mFramesPerPacket: UInt32(samplesPerFrame), mBytesPerFrame: 0,
            mChannelsPerFrame: UInt32(channels), mBitsPerChannel: 0, mReserved: 0)
        var description: CMAudioFormatDescription?
        let status = CMAudioFormatDescriptionCreate(
            allocator: nil, asbd: &asbd, layoutSize: 0, layout: nil, magicCookieSize: 0, magicCookie: nil,
            extensions: nil, formatDescriptionOut: &description)
        return status == noErr ? description : nil
    }

    /// A CoreMedia-owned block buffer holding a copy of `data`.
    static func blockBuffer(copying data: Data, pool: SampleMemoryPool? = nil) -> CMBlockBuffer? {
        data.withUnsafeBytes { blockBuffer(copying: $0, pool: pool) }
    }

    /// A CoreMedia-owned block buffer holding a copy of `bytes` followed by `padding` zeroed bytes, which count in its
    /// data length (a sample's size leaves them out). Its memory comes from `pool` when given.
    static func blockBuffer(copying bytes: UnsafeRawBufferPointer, padding: Int = 0,
                            pool: SampleMemoryPool? = nil) -> CMBlockBuffer? {
        guard let base = bytes.baseAddress, !bytes.isEmpty, padding >= 0 else { return nil }
        let length = bytes.count + padding
        var block: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length,
            blockAllocator: pool?.allocator,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard created == noErr, let block,
              CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: 0,
                                            dataLength: bytes.count) == noErr else { return nil }
        guard padding > 0 else { return block }
        let zeroed = CMBlockBufferFillDataBytes(with: 0, blockBuffer: block, offsetIntoDestination: bytes.count,
                                                dataLength: padding)
        return zeroed == noErr ? block : nil
    }

    /// 90 kHz timing for one sample.
    struct Timing {
        var pts: Int64?
        var dts: Int64?
        var duration: Int64
    }

    /// One compressed video picture with its timing.
    static func videoSample(data: Data, format: CMVideoFormatDescription, timing sampleTiming: Timing,
                            isKeyframe: Bool, pool: SampleMemoryPool? = nil) -> CMSampleBuffer? {
        guard let block = blockBuffer(copying: data, pool: pool) else { return nil }
        return videoSample(block: block, size: data.count, format: format, timing: sampleTiming,
                           isKeyframe: isKeyframe)
    }

    /// One compressed video picture: the first `size` bytes of `block`, which may hold padding after them. The
    /// sample's size is `size`; readers must not use the block buffer's data length.
    static func videoSample(block: CMBlockBuffer, size: Int, format: CMVideoFormatDescription,
                            timing sampleTiming: Timing, isKeyframe: Bool) -> CMSampleBuffer? {
        var timing = CMSampleTimingInfo(duration: CMTime(value: sampleTiming.duration, timescale: timescale),
                                        presentationTimeStamp: time(sampleTiming.pts),
                                        decodeTimeStamp: time(sampleTiming.dts))
        var size = size
        var sample: CMSampleBuffer?
        let status = CMSampleBufferCreateReady(
            allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: 1, sampleTimingEntryCount: 1,
            sampleTimingArray: &timing, sampleSizeEntryCount: 1, sampleSizeArray: &size, sampleBufferOut: &sample)
        guard status == noErr, let sample else { return nil }
        if !isKeyframe, let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: true),
           CFArrayGetCount(attachments) > 0 {
            let dict = unsafeBitCast(CFArrayGetValueAtIndex(attachments, 0), to: CFMutableDictionary.self)
            CFDictionarySetValue(dict, Unmanaged.passUnretained(kCMSampleAttachmentKey_NotSync).toOpaque(),
                                 Unmanaged.passUnretained(kCFBooleanTrue).toOpaque())
        }
        return sample
    }

    /// Several compressed audio frames in one buffer, with packet descriptions. Each frame is copied straight to its
    /// place in the buffer, whose memory comes from `pool` when given.
    static func audioSample(frames: some Collection<Data>, format: CMAudioFormatDescription, pts: Int64,
                            pool: SampleMemoryPool? = nil) -> CMSampleBuffer? {
        let length = frames.reduce(0) { $0 + $1.count }
        guard length > 0 else { return nil }
        var block: CMBlockBuffer?
        let created = CMBlockBufferCreateWithMemoryBlock(
            allocator: nil, memoryBlock: nil, blockLength: length, blockAllocator: pool?.allocator,
            customBlockSource: nil, offsetToData: 0, dataLength: length, flags: kCMBlockBufferAssureMemoryNowFlag,
            blockBufferOut: &block)
        guard created == noErr, let block else { return nil }
        return withUnsafeTemporaryAllocation(of: AudioStreamPacketDescription.self,
                                             capacity: frames.count) { packets -> CMSampleBuffer? in
            var offset = 0
            for (index, frame) in frames.enumerated() {
                let copied = frame.withUnsafeBytes { raw -> OSStatus in
                    guard let base = raw.baseAddress else { return noErr }
                    return CMBlockBufferReplaceDataBytes(with: base, blockBuffer: block, offsetIntoDestination: offset,
                                                         dataLength: raw.count)
                }
                guard copied == noErr else { return nil }
                packets.initializeElement(at: index, to: AudioStreamPacketDescription(
                    mStartOffset: Int64(offset), mVariableFramesInPacket: 0, mDataByteSize: UInt32(frame.count)))
                offset += frame.count
            }
            var sample: CMSampleBuffer?
            let status = CMAudioSampleBufferCreateReadyWithPacketDescriptions(
                allocator: nil, dataBuffer: block, formatDescription: format, sampleCount: frames.count,
                presentationTimeStamp: time(pts), packetDescriptions: packets.baseAddress, sampleBufferOut: &sample)
            return status == noErr ? sample : nil
        }
    }
}
