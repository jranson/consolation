//
//  ElementaryProcessor.swift
//  PlaybackKit
//
//  Turns demuxed PES packets into CoreMedia sample buffers: MPEG-2, H.264 and HEVC pictures (one per sample; H.264
//  and HEVC as 4-byte length-prefixed NAL units with a format description from their parameter sets) and batches of
//  AC-3/E-AC-3 frames or of AAC access units from ADTS. Runs on the pipeline's serial queue.
//

import CoreMedia
import Foundation
import MPEGTS
import os

/// The video codec of a compressed picture, which picks the decoder (`VideoFrameStage.prepare`).
nonisolated enum CompressedVideoCodec: Sendable, Hashable {
    /// libavcodec (or, for measurements on macOS, VideoToolbox's software decoder).
    case mpeg2
    /// VideoToolbox, in hardware.
    case h264
    case hevc
}

/// One compressed picture ready for the decoder.
nonisolated struct CompressedPicture: @unchecked Sendable {
    // @unchecked: the sample buffer is immutable once created.
    /// MPEG-2 samples carry padding after the picture: read their bytes by sample size, not block buffer length
    /// (`SampleFormats`).
    let sample: CMSampleBuffer
    let info: PictureInfo
    /// A/53 caption data carried with this picture (decode order).
    var captionData: Data?
    var codec = CompressedVideoCodec.mpeg2
    /// Pictures the decoder output may need holding to restore display order.
    var reorderDepth = FrameReorderBuffer.fullDepth
}

/// What the stream info reports about the video, from the first picture framed.
nonisolated struct VideoStreamFacts: Equatable, Sendable {
    var codec: String
    var width: Int
    var height: Int
    var frameRate: Double?
    var isInterlaced: Bool
}

nonisolated struct ElementaryProcessor {
    /// AC-3 frames per audio sample buffer (about 128 ms at 48 kHz; AAC batches its own, `AACSampleBatcher`).
    static let audioFramesPerSample = 4
    static let log = Logger(subsystem: "PlaybackKit", category: "TransportStream")

    private(set) var videoPID: UInt16?
    private(set) var audioPID: UInt16?
    private(set) var videoKind: StreamKind?
    /// `.aac` for AAC in ADTS; any other kind is AC-3 or E-AC-3.
    private(set) var audioKind: StreamKind?
    /// What the stream info reports about the video, from the latest format.
    var videoFacts: VideoStreamFacts? { sampleBuilder.facts }
    private(set) var audioChannels: Int?
    private(set) var audioIsEAC3 = false
    /// The AAC stream's config, with the SBR its payload showed, from its first frames.
    private(set) var aacConfig: AudioSpecificConfig?
    private var videoFramer = MPEG2Framer()
    /// H.264 and HEVC; nil for MPEG-2.
    private var nalFramer: NALVideoFramer?
    private var audioFramer = AC3Framer()
    /// Recycles compressed samples' memory for this pipeline.
    private let pool = SampleMemoryPool()
    private var sampleBuilder: VideoSampleBuilder
    private var audioFormat: CMAudioFormatDescription?
    private var pendingAudio: [AC3Frame] = []
    private var adtsFramer = ADTSFramer()
    private var aac: AACSampleBatcher?
    /// The ADTS format `aac` was made for; another starts a new batcher.
    private var aacFormat: ADTSHeader.Format?
    /// Frames held while AudioToolbox reads their profile (`ADTSProfile`), before `aac` exists.
    private var aacProbe: [ADTSFrame] = []
    /// A container's frame duration for H.264 and HEVC (`NALVideoFramer.nominalFrameTicks`); nil for MPEG-TS.
    var nominalFrameTicks: Int64? {
        didSet { nalFramer?.nominalFrameTicks = nominalFrameTicks }
    }

    init() {
        sampleBuilder = VideoSampleBuilder(pool: pool)
    }

    mutating func select(video: ElementaryStream?, audio: ElementaryStream?) {
        if video?.pid != videoPID || video?.kind != videoKind {
            videoKind = video?.kind
            restartFramer(video: true)
        }
        if audio?.pid != audioPID || audio?.kind != audioKind {
            audioKind = audio?.kind
            restartFramer(video: false)
            audioChannels = nil
            audioIsEAC3 = audio?.kind == .eac3
            audioFormat = nil
            aac = nil
            aacFormat = nil
            aacConfig = nil
        }
        videoPID = video?.pid
        audioPID = audio?.pid
    }

    mutating func reset() {
        restartFramer(video: true)
        restartFramer(video: false)
    }

    /// Restarts one stream's framer, e.g. when it rejoins after its packets were dropped (`TimelineGuard`). Video
    /// output resumes at the next sequence header and I picture (MPEG-2) or random-access picture (H.264, HEVC).
    mutating func restartFramer(video: Bool) {
        guard video else {
            audioFramer = AC3Framer()
            pendingAudio = []
            adtsFramer = ADTSFramer()
            aac?.reset()
            aacProbe = []
            return
        }
        videoFramer = MPEG2Framer()
        switch videoKind {
        case .h264: nalFramer = NALVideoFramer(codec: .h264)
        case .hevc: nalFramer = NALVideoFramer(codec: .hevc)
        default: nalFramer = nil
        }
        nalFramer?.nominalFrameTicks = nominalFrameTicks
    }

    /// Compressed video sample buffers (with their picture facts) for the pictures completed by this PES.
    mutating func videoSamples(from pes: PESPacket) -> [CompressedPicture] {
        pes.payload.withUnsafeBytes { raw in
            videoSamples(from: pes, payload: raw.bindMemory(to: UInt8.self))
        }
    }

    /// `videoSamples(from:)` for a PES whose payload is lent (`TSDemuxer.feed(_:_:)`).
    mutating func videoSamples(from pes: PESPacket, payload: UnsafeBufferPointer<UInt8>) -> [CompressedPicture] {
        var pictures: [CompressedPicture] = []
        appendVideoSamples(from: pes, payload: payload, to: &pictures)
        return pictures
    }

    /// Appends the pictures completed by a PES whose payload is lent (`TSDemuxer.feed(_:_:)`) to `output`, which the
    /// caller can reuse. An MPEG-2 picture is copied once, from the framer straight into its sample buffer.
    mutating func appendVideoSamples(from pes: PESPacket, payload: UnsafeBufferPointer<UInt8>,
                                     to output: inout [CompressedPicture]) {
        // A local builder, since the framer's callback can't reach `self` while the framer runs.
        var builder = sampleBuilder
        defer { sampleBuilder = builder }
        if nalFramer != nil {
            nalFramer?.append(payload, of: pes) { unit, sample in
                if let picture = builder.picture(for: unit, sample: sample) { output.append(picture) }
            }
            return
        }
        videoFramer.append(payload, of: pes) { unit, bytes in
            if let picture = builder.picture(for: unit, bytes: bytes) { output.append(picture) }
        }
    }

    /// Completes the picture the framer still holds, for the end of a finite stream.
    mutating func flushVideo() -> [CompressedPicture] {
        var output: [CompressedPicture] = []
        var builder = sampleBuilder
        defer { sampleBuilder = builder }
        if nalFramer != nil {
            nalFramer?.flush { unit, sample in
                if let picture = builder.picture(for: unit, sample: sample) { output.append(picture) }
            }
            return output
        }
        videoFramer.flush { unit, bytes in
            if let picture = builder.picture(for: unit, bytes: bytes) { output.append(picture) }
        }
        return output
    }

    /// Audio sample buffers for the frames completed by this PES, batched.
    mutating func audioSamples(from pes: PESPacket) -> [CMSampleBuffer] {
        pes.payload.withUnsafeBytes { raw in
            audioSamples(from: pes, payload: raw.bindMemory(to: UInt8.self))
        }
    }

    /// The audio codec as the stream info names it ("HE-AAC" once the first AAC frame showed SBR).
    var audioCodecName: String? {
        switch audioKind {
        case nil: nil
        case .aac: aacConfig?.profileName ?? "AAC"
        default: audioIsEAC3 ? "E-AC-3" : "AC-3"
        }
    }

    /// `audioSamples(from:)` for a PES whose payload is lent (`TSDemuxer.feed(_:_:)`).
    mutating func audioSamples(from pes: PESPacket, payload: UnsafeBufferPointer<UInt8>) -> [CMSampleBuffer] {
        if audioKind == .aac { return aacSamples(from: pes, payload: payload) }
        var output: [CMSampleBuffer] = []
        for frame in audioFramer.append(payload, of: pes) {
            if audioFormat == nil || audioChannels != frame.channelCount || audioIsEAC3 != frame.isEAC3 {
                if let sample = flushAudio() { output.append(sample) }
                audioChannels = frame.channelCount
                audioIsEAC3 = frame.isEAC3
                audioFormat = SampleFormats.dolbyAudio(sampleRate: frame.sampleRate, channels: frame.channelCount,
                                                       isEAC3: frame.isEAC3, samplesPerFrame: frame.samplesPerFrame)
            }
            pendingAudio.append(frame)
            if pendingAudio.count >= Self.audioFramesPerSample, let sample = flushAudio() { output.append(sample) }
        }
        return output
    }

    /// AAC access units from ADTS frames, batched. A new format (rate, channels or profile) is probed for SBR: its
    /// frames wait until AudioToolbox has read the profile from them.
    private mutating func aacSamples(from pes: PESPacket, payload: UnsafeBufferPointer<UInt8>) -> [CMSampleBuffer] {
        var output: [CMSampleBuffer] = []
        for frame in adtsFramer.append(payload, of: pes) {
            if frame.header.format != aacFormat {
                if let sample = aac?.flush() { output.append(sample) }
                aacFormat = frame.header.format
                aac = nil
                aacConfig = nil
                aacProbe = []
            }
            guard var batcher = aac.take() else {
                aacProbe.append(frame)
                output += startAAC(final: aacProbe.count >= ADTSProfile.maximumFrames)
                continue
            }
            output += batcher.append(frame.accessUnit, pts: frame.pts)
            aac = batcher
        }
        return output
    }

    /// Makes the batcher once the held frames show their profile (or, when `final`, with the header's plain AAC)
    /// and returns what the held frames fill.
    private mutating func startAAC(final: Bool) -> [CMSampleBuffer] {
        guard let config = ADTSProfile.config(for: aacProbe, final: final),
              var batcher = AACSampleBatcher(config: config, channels: config.channelCount, pool: pool) else {
            if final { aacProbe = [] }
            return []
        }
        aacConfig = config
        // Parametric stereo makes stereo from a mono core.
        audioChannels = config.extensionObjectType == AudioSpecificConfig.objectTypePS ? 2 : config.channelCount
        var output: [CMSampleBuffer] = []
        for frame in aacProbe { output += batcher.append(frame.accessUnit, pts: frame.pts) }
        aacProbe = []
        aac = batcher
        return output
    }

    /// The audio frames still batched, for the end of a finite stream.
    mutating func flushPendingAudio() -> CMSampleBuffer? {
        guard audioKind == .aac else { return flushAudio() }
        // Frames still held for their profile (a stream shorter than the probe) play as one buffer.
        if aac == nil, let first = aacProbe.first, let config = ADTSProfile.config(for: aacProbe, final: true),
           let format = AACFormat.description(config, channels: config.channelCount) {
            defer { aacProbe = [] }
            return SampleFormats.audioSample(frames: aacProbe.map(\.accessUnit), format: format, pts: first.pts,
                                             pool: pool)
        }
        return aac?.flush()
    }

    private mutating func flushAudio() -> CMSampleBuffer? {
        defer { pendingAudio.removeAll(keepingCapacity: true) }
        guard let format = audioFormat, let first = pendingAudio.first else { return nil }
        return SampleFormats.audioSample(frames: pendingAudio.lazy.map(\.data), format: format, pts: first.pts,
                                         pool: pool)
    }
}
