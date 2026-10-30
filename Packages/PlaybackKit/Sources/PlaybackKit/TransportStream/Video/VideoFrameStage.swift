//
//  VideoFrameStage.swift
//  PlaybackKit
//
//  Compressed pictures in, presentable progressive pictures out: decode (libavcodec for MPEG-2, VideoToolbox in
//  hardware for H.264 and HEVC), restore display order, then the GPU stage (MetalDeinterlacer) deinterlaces
//  interlaced pictures to field rate and converts libavcodec's planar progressive ones to NV12, reading the decoder's
//  memory in place; VideoToolbox's progressive pictures pass through untouched. Each result is wrapped in a ready
//  sample buffer.
//
//  The decode thread never waits for the GPU while it keeps up: the GPU stage commits its passes and returns;
//  pictures whose pass is still running wait here and go out with the next call (one picture later, normally long
//  finished by then), or from `collectReady()`.
//
//  Multi-view (`apply(_:)`): below the single-stream tier interlaced pictures are bobbed, one per frame; without B
//  pictures nothing needs reordering; and with I pictures only, each is drained from the decoder at once (an I
//  picture needs nothing else, and the decoder would otherwise hold it until the next one, up to a second later).
//

import CoreMedia
import CoreVideo
import Metal

nonisolated final class VideoFrameStage {
    private var decoder: any VideoDecoding
    /// The codec the decoder was made for; nil for a decoder given at init, which is never replaced.
    private var decoderCodec: CompressedVideoCodec?
    private let mpeg2Preference: MPEG2DecoderPreference
    private let deinterlacer: MetalDeinterlacer?
    private var tier = DecodeTier.single
    /// The reorder depth of the stream's codec at full rate (MPEG-2: 3; H.264/HEVC: the SPS's).
    private var streamReorderDepth = FrameReorderBuffer.fullDepth
    private var streamCodec = CompressedVideoCodec.mpeg2
    private var reorder = FrameReorderBuffer()
    private var outputFormat: CMVideoFormatDescription?
    /// Pictures whose GPU pass was still running when they were made, oldest first.
    private var inFlight: [DecodedFrame] = []
    private let clock = VideoStageClock()
    private var lastGPUSeconds: Double = 0
    /// Every picture is drained from the decoder as soon as it is decoded (`.keyframesOnly`).
    private var drainsEachPicture = false

    /// Presents pictures for `tier` from the next one on. The deinterlacer bobs below `.single`, the reorder buffer
    /// holds nothing when B pictures are dropped, and I-only decoding drains the decoder after each picture.
    func apply(_ tier: DecodeTier) {
        self.tier = tier
        deinterlacer?.mode = tier == .single ? .fieldRate : .bob
        switch tier {
        case .full:
            reorder.depth = streamReorderDepth
        case .reduced where streamCodec != .mpeg2:
            // H.264 and HEVC keep reference B pictures (B-pyramids), so decode order still isn't display order.
            reorder.depth = streamReorderDepth
        default:
            reorder.depth = 0
        }
        drainsEachPicture = tier == .keyframesOnly
    }

    /// Makes the decoder fit `codec` (a new stream or a codec change replaces it) and sets the reorder depth.
    func prepare(codec: CompressedVideoCodec, reorderDepth: Int) {
        if decoderCodec != nil, decoderCodec != codec {
            decoder.invalidate()
            reorder.reset()
            deinterlacer?.reset()
            inFlight.removeAll()
            decoder = Self.makeDecoder(codec, preference: mpeg2Preference, device: deinterlacer?.device)
            (decoder as? LibavVideoDecoder)?.clock = clock
            decoderCodec = codec
        }
        let depth = codec == .mpeg2 ? FrameReorderBuffer.fullDepth : reorderDepth
        guard depth != streamReorderDepth || codec != streamCodec else { return }
        streamReorderDepth = depth
        streamCodec = codec
        apply(tier)
    }

    private static func makeDecoder(_ codec: CompressedVideoCodec, preference: MPEG2DecoderPreference,
                                    device: MTLDevice?) -> any VideoDecoding {
        switch codec {
        case .mpeg2: VideoDecoders.mpeg2(preference, device: device)
        case .h264, .hevc: VTVideoDecoder(prefersHardware: true)
        }
    }

    /// The playback path: the platform's MPEG-2 decoder handing its pictures to the GPU stage as they are.
    /// H.264 and HEVC streams switch it to VideoToolbox (`prepare`).
    convenience init(preference: MPEG2DecoderPreference = .libavcodec) {
        let deinterlacer = MetalDeinterlacer()
        self.init(decoder: VideoDecoders.mpeg2(preference, device: deinterlacer?.device), deinterlacer: deinterlacer,
                  codec: .mpeg2, preference: preference)
    }

    /// A given decoder (tests and measurements), never replaced; its output goes through the GPU stage when Metal
    /// is available.
    convenience init(decoder: any VideoDecoding) {
        self.init(decoder: decoder, deinterlacer: MetalDeinterlacer(), codec: nil, preference: .libavcodec)
    }

    private init(decoder: any VideoDecoding, deinterlacer: MetalDeinterlacer?, codec: CompressedVideoCodec?,
                 preference: MPEG2DecoderPreference) {
        self.decoder = decoder
        decoderCodec = codec
        mpeg2Preference = preference
        self.deinterlacer = deinterlacer
        (decoder as? LibavVideoDecoder)?.clock = clock
        deinterlacer?.clock = clock
    }

    /// Decodes one compressed picture; returns the sample buffers that became ready (zero, one or more).
    func process(_ sample: CMSampleBuffer, info: PictureInfo) throws -> [CMSampleBuffer] {
        let started = VideoStageClock.now()
        let startedCPU = VideoStageClock.threadCPU()
        defer {
            clock.add(Double(VideoStageClock.now() - started) / 1e9, to: \.total)
            clock.add(Double(VideoStageClock.threadCPU() - startedCPU) / 1e9, to: \.threadCPU)
            clock.notePicture()
        }
        var frames: [DecodedFrame] = []
        let decodedFrames = try clock.measure(\.decode, "Decode") {
            try decoder.decode(sample, info: info) + (drainsEachPicture ? try decoder.drain() : [])
        }
        for decoded in decodedFrames {
            for ordered in reorder.push(decoded) {
                frames.append(contentsOf: deinterlacer?.push(ordered) ?? [ordered])
            }
        }
        // Whatever was in flight from earlier calls goes out first, in order.
        let earlier = inFlight
        inFlight.removeAll(keepingCapacity: true)
        return output(earlier, waiting: true) + output(frames, waiting: false)
    }

    /// Sample buffers for in-flight pictures whose GPU pass has finished, without decoding anything. For a reader
    /// that has no picture to decode right now but wants the screen fed.
    func collectReady() -> [CMSampleBuffer] {
        let held = inFlight
        inFlight.removeAll(keepingCapacity: true)
        return output(held, waiting: false)
    }

    /// Emits everything still held by the decoder, the reorder buffer and the deinterlacer (end of stream).
    func drain() throws -> [CMSampleBuffer] {
        var frames: [DecodedFrame] = []
        for decoded in try decoder.drain() {
            frames.append(contentsOf: reorder.push(decoded))
        }
        frames.append(contentsOf: reorder.drain())
        var presented: [DecodedFrame] = inFlight
        inFlight.removeAll()
        for frame in frames { presented.append(contentsOf: deinterlacer?.push(frame) ?? [frame]) }
        presented.append(contentsOf: deinterlacer?.drain() ?? [])
        return output(presented, waiting: true)
    }

    /// Forgets all state, e.g. after a jump in the stream. GPU passes still running keep their own resources.
    func reset() {
        decoder.invalidate()
        reorder.reset()
        deinterlacer?.reset()
        inFlight.removeAll()
    }

    /// The decode thread's time per stage since the last call (e.g. once a second, for a health trace).
    func takeTimings() -> VideoStageTimings {
        var timings = clock.take()
        let gpuSeconds = ((decoder as? LibavVideoDecoder)?.gpuSeconds ?? 0) + (deinterlacer?.gpuSeconds ?? 0)
        timings.gpuBusy = max(0, gpuSeconds - lastGPUSeconds)
        lastGPUSeconds = gpuSeconds
        return timings
    }

    /// Sample buffers for `frames` in order. Without `waiting`, the first picture whose GPU pass is still running
    /// and everything after it stay in flight.
    private func output(_ frames: [DecodedFrame], waiting: Bool) -> [CMSampleBuffer] {
        var ready: [CMSampleBuffer] = []
        for (index, frame) in frames.enumerated() {
            if !waiting, let work = frame.gpuWork,
               work.status.rawValue < MTLCommandBufferStatus.completed.rawValue {
                inFlight.append(contentsOf: frames[index...])
                break
            }
            waitForGPU(frame.gpuWork, clock: clock)
            if let sample = clock.measure(\.output, "Output", { sampleBuffer(for: frame) }) { ready.append(sample) }
        }
        return ready
    }

    private func sampleBuffer(for frame: DecodedFrame) -> CMSampleBuffer? {
        // Every picture has a pixel buffer by now: planar ones only reach here through the GPU stage.
        guard let image = frame.pixelBuffer else { return nil }
        if !frame.isInterlaced {
            // Progressive output: make sure nothing downstream treats it as two fields. The deinterlacer and the
            // libavcodec decoder already set this; each write is a kernel round trip, so only fix what's wrong.
            if CVBufferCopyAttachment(image, kCVImageBufferFieldCountKey, nil) as? Int != 1 {
                CVBufferSetAttachment(image, kCVImageBufferFieldCountKey, 1 as CFNumber, .shouldPropagate)
            }
            if CVBufferHasAttachment(image, kCVImageBufferFieldDetailKey) {
                CVBufferRemoveAttachment(image, kCVImageBufferFieldDetailKey)
            }
        }
        if outputFormat.map({ !CMVideoFormatDescriptionMatchesImageBuffer($0, imageBuffer: image) }) ?? true {
            var format: CMVideoFormatDescription?
            CMVideoFormatDescriptionCreateForImageBuffer(allocator: nil, imageBuffer: image,
                                                         formatDescriptionOut: &format)
            outputFormat = format
        }
        guard let outputFormat else { return nil }
        var timing = CMSampleTimingInfo(duration: CMTime(value: frame.duration, timescale: SampleFormats.timescale),
                                        presentationTimeStamp: SampleFormats.time(frame.pts),
                                        decodeTimeStamp: .invalid)
        var sample: CMSampleBuffer?
        CMSampleBufferCreateReadyWithImageBuffer(allocator: nil, imageBuffer: image, formatDescription: outputFormat,
                                                 sampleTiming: &timing, sampleBufferOut: &sample)
        return sample
    }
}
