//
//  MatroskaTrackFeed.swift
//  PlaybackKit
//
//  Turns the chosen tracks' Matroska blocks into what the transport stream path already decodes: every video frame
//  becomes one PES-like packet for the framers (`ElementaryProcessor`), H.264 and HEVC rewritten from length-prefixed
//  NAL units to Annex B with the CodecPrivate parameter sets in front of each keyframe; AC-3 and E-AC-3 frames go
//  through the AC-3 framer the same way; AAC access units are batched into sample buffers here. Timestamps become
//  90 kHz ticks. Runs on the pipeline's queue.
//

import CoreMedia
import Foundation
import Matroska
import MPEGTS

nonisolated struct MatroskaTrackFeed {
    /// Stream identifiers the framers see (any distinct values do).
    static let videoPID: UInt16 = 1
    static let audioPID: UInt16 = 2

    let segment: MatroskaSegment
    let video: MatroskaTrack
    let videoCodec: MatroskaVideoCodec
    private(set) var audio: MatroskaTrack?
    private(set) var audioCodec: MatroskaAudioCodec?
    private(set) var processor = ElementaryProcessor()
    private var aac: AACSampleBatcher?
    private let pool = SampleMemoryPool()
    /// A frame rewritten for the framers, reused for every frame.
    private var scratch: [UInt8] = []

    init(segment: MatroskaSegment, video: MatroskaTrack, codec: MatroskaVideoCodec) {
        self.segment = segment
        self.video = video
        videoCodec = codec
        processor.select(video: ElementaryStream(pid: Self.videoPID, streamType: 0, kind: codec.streamKind),
                         audio: nil)
        // DefaultDuration is in nanoseconds; 90 kHz ticks, rounded.
        processor.nominalFrameTicks = video.defaultDuration.flatMap { Int64(exactly: $0) }
            .map { ($0 * 9 + 50_000) / 100_000 }
    }

    /// Plays `track` (nil for none) from its next block on.
    mutating func selectAudio(_ track: MatroskaTrack?) {
        audio = track
        audioCodec = track.flatMap(MatroskaTrackSelection.audioCodec(for:))
        aac = nil
        var dolby: ElementaryStream?
        switch audioCodec {
        case .dolby(let isEAC3):
            dolby = ElementaryStream(pid: Self.audioPID, streamType: 0, kind: isEAC3 ? .eac3 : .ac3)
        case .aac(let config):
            aac = AACSampleBatcher(config: config, channels: track?.channels ?? 2, pool: pool)
        case nil:
            break
        }
        processor.select(video: ElementaryStream(pid: Self.videoPID, streamType: 0, kind: videoCodec.streamKind),
                         audio: dolby)
    }

    /// Facts for the stream info: the audio codec and channels.
    var audioName: String? { audioCodec?.displayName }
    var audioChannels: Int? {
        switch audioCodec {
        case .dolby: processor.audioChannels
        case .aac(let config): config.channelCount > 0 ? config.channelCount : audio?.channels
        case nil: nil
        }
    }

    /// Drops what the framers hold; video resumes at the next keyframe (a seek, or a jump in the stream).
    mutating func reset() {
        processor.reset()
        aac?.reset()
    }

    // MARK: - Video

    /// Appends the pictures this block of the video track completed (usually the previous frame's).
    mutating func appendVideo(_ block: MatroskaBlock, payload: UnsafeBufferPointer<UInt8>,
                              to output: inout [CompressedPicture]) {
        for (index, range) in block.frames.enumerated() {
            let frame = UnsafeBufferPointer(rebasing: payload[range])
            scratch.removeAll(keepingCapacity: true)
            let keyframe = block.isKeyframe && index == 0
            guard rewrite(frame, keyframe: keyframe) else { continue }
            let pes = PESPacket(pid: Self.videoPID, streamID: 0xE0, pts: ticks(block, frame: index, of: video),
                                payload: Data(), isRandomAccess: keyframe)
            scratch.withUnsafeBufferPointer { processor.appendVideoSamples(from: pes, payload: $0, to: &output) }
        }
    }

    /// Completes the picture the framer still holds, at the end of the stream.
    mutating func flushVideo() -> [CompressedPicture] {
        processor.flushVideo()
    }

    /// The frame as the framers read it, in `scratch`; false for a damaged frame.
    private mutating func rewrite(_ frame: UnsafeBufferPointer<UInt8>, keyframe: Bool) -> Bool {
        switch videoCodec {
        case .nal(let config):
            guard let stripped = video.strippedHeader else {
                return config.appendAnnexB(frame, parameterSets: keyframe, to: &scratch)
            }
            let whole = [UInt8](stripped) + frame
            return whole.withUnsafeBufferPointer { config.appendAnnexB($0, parameterSets: keyframe, to: &scratch) }
        case .mpeg2(let sequenceHeader):
            if let stripped = video.strippedHeader { scratch += stripped }
            scratch += frame
            let startsWithSequence = scratch.starts(with: [0, 0, 1, 0xB3])
            if keyframe, !startsWithSequence, !sequenceHeader.isEmpty {
                scratch.insert(contentsOf: sequenceHeader, at: 0)
            }
            return !scratch.isEmpty
        }
    }

    // MARK: - Audio

    /// Audio sample buffers for this block of the audio track.
    mutating func audioSamples(_ block: MatroskaBlock, payload: UnsafeBufferPointer<UInt8>) -> [CMSampleBuffer] {
        guard let audio else { return [] }
        switch audioCodec {
        case .dolby:
            // All of a block's syncframes at once: the framer times the frames after the first from their samples.
            scratch.removeAll(keepingCapacity: true)
            for range in block.frames {
                if let stripped = audio.strippedHeader { scratch += stripped }
                scratch += UnsafeBufferPointer(rebasing: payload[range])
            }
            let pes = PESPacket(pid: Self.audioPID, streamID: 0xBD, pts: ticks(block, frame: 0, of: audio),
                                payload: Data())
            return scratch.withUnsafeBufferPointer { processor.audioSamples(from: pes, payload: $0) }
        case .aac:
            guard var batcher = aac.take() else { return [] }
            defer { aac = batcher }
            var output: [CMSampleBuffer] = []
            let first = ticks(block, frame: 0, of: audio)
            for (index, range) in block.frames.enumerated() {
                let pts = first + Int64(index) * batcher.frameTicks
                if let stripped = audio.strippedHeader {
                    let whole = [UInt8](stripped) + UnsafeBufferPointer(rebasing: payload[range])
                    output += whole.withUnsafeBufferPointer { batcher.append($0, pts: pts) }
                } else {
                    output += batcher.append(UnsafeBufferPointer(rebasing: payload[range]), pts: pts)
                }
            }
            return output
        case nil:
            return []
        }
    }

    /// The audio still batched, at the end of the stream.
    mutating func flushAudio() -> CMSampleBuffer? {
        switch audioCodec {
        case .dolby: return processor.flushPendingAudio()
        case .aac: return aac?.flush()
        case nil: return nil
        }
    }

    // MARK: - Time

    /// The 90 kHz presentation time of frame `index` of a block: laced frames follow the first by the track's
    /// frame duration (or an even share of the block's).
    func ticks(_ block: MatroskaBlock, frame index: Int, of track: MatroskaTrack) -> Int64 {
        let start = segment.ticks(block.timestamp)
        guard index > 0 else { return start }
        if let duration = track.defaultDuration, let nanoseconds = Int64(exactly: duration) {
            return start + Int64(index) * nanoseconds * 9 / 100_000
        }
        if let duration = block.duration, !block.frames.isEmpty {
            return start + segment.ticks(duration) * Int64(index) / Int64(block.frames.count)
        }
        return start
    }
}
