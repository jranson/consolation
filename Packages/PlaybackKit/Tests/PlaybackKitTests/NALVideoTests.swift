//
//  NALVideoTests.swift
//  PlaybackKitTests
//
//  H.264 and HEVC end to end on streams encoded here with VideoToolbox (SyntheticNALStream): transport stream to
//  compressed pictures (count, timestamps, keyframes, non-reference pictures, format descriptions from the parameter
//  sets), hardware decoding through the video stage, the decode tiers, and a pipeline playing an ATSC 3.0-style
//  program whose only audio is AC-4 (video only, the codec reported). HEVC cases return early when this Mac has no
//  HEVC encoder.
//

import AVFoundation
import CoreMedia
import Foundation
import MPEGTS
import Testing
import VideoToolbox
@testable import PlaybackKit

#if os(macOS)
@Suite(.serialized)
struct NALVideoTests {
    nonisolated struct Case: Sendable, CustomTestStringConvertible {
        let codec: CMVideoCodecType
        let streamType: UInt8
        let kind: CompressedVideoCodec
        var testDescription: String { kind == .h264 ? "H.264" : "HEVC" }
    }

    nonisolated static let cases = [
        Case(codec: kCMVideoCodecType_H264, streamType: 0x1B, kind: .h264),
        Case(codec: kCMVideoCodecType_HEVC, streamType: 0x24, kind: .hevc)
    ]

    /// The encoded pictures and their transport stream's compressed pictures; nil only for HEVC without an encoder.
    private static func stream(_ item: Case) -> (encoded: [SyntheticNALStream.Picture], framed: [CompressedPicture])? {
        guard let encoded = SyntheticNALStream.encode(item.codec) else {
            #expect(item.kind == .hevc, "VideoToolbox should always encode H.264")
            return nil
        }
        let data = SyntheticNALStream.transportStream(encoded, streamType: item.streamType)
        return (encoded, SyntheticVideoFixture.pictures(in: data))
    }

    private static func decode(_ pictures: [CompressedPicture], tier: DecodeTier,
                               resumeAt: Int? = nil) throws -> (outputs: [CMSampleBuffer], admitted: Int) {
        let stage = VideoFrameStage()
        stage.apply(tier)
        var gate = DecodeTierGate()
        gate.set(resumeAt == nil ? tier : .suspended)
        var outputs: [CMSampleBuffer] = []
        var admitted = 0
        for (index, picture) in pictures.enumerated() {
            if index == resumeAt { gate.set(tier) }
            guard gate.admit(picture.info.role, pts: picture.info.pts) else { continue }
            admitted += 1
            stage.prepare(codec: picture.codec, reorderDepth: picture.reorderDepth)
            outputs += try stage.process(picture.sample, info: picture.info)
        }
        return (outputs + (try stage.drain()), admitted)
    }

    /// The NAL unit type of the first VCL NAL unit in an Annex-B HEVC picture.
    private static func firstHEVCSliceType(_ bytes: [UInt8]) -> Int? {
        var index = 0
        while index + 4 < bytes.count {
            if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
                let type = Int(bytes[index + 3] >> 1) & 0x3F
                if type < 32 { return type }
                index += 3
            } else {
                index += 1
            }
        }
        return nil
    }

    private static func times(_ samples: [CMSampleBuffer]) -> [Int64] {
        samples.map { CMSampleBufferGetPresentationTimeStamp($0).value }
    }

    @Test(arguments: cases)
    func framesEveryPictureWithItsRole(_ item: Case) throws {
        guard let (encoded, pictures) = Self.stream(item) else { return }
        #expect(pictures.count == encoded.count)
        #expect(pictures.map(\.info.pts).sorted() == encoded.map(\.pts).sorted())
        #expect(pictures.filter { $0.info.role == .keyframe }.count == encoded.filter(\.isKeyframe).count)
        // H.264: nal_ref_idc 0 matches the encoder's own marking. HEVC: VideoToolbox's encoder labels unreferenced
        // B pictures TRAIL_R, so only its _N types (RASL_N here) are provably droppable.
        let expected = item.kind == .h264 ? encoded.filter { !$0.isDependedOn }.count
            : encoded.filter { Self.firstHEVCSliceType($0.annexB).map { $0 <= 14 && $0 % 2 == 0 } ?? false }.count
        #expect(pictures.filter { $0.info.role == .nonReference }.count == expected)
        #expect(pictures.allSatisfy { $0.codec == item.kind && !$0.info.isInterlaced })
        let format = try #require(pictures.first.flatMap { CMSampleBufferGetFormatDescription($0.sample) })
        let size = CMVideoFormatDescriptionGetDimensions(format)
        #expect(size.width == Int32(SyntheticNALStream.width) && size.height == Int32(SyntheticNALStream.height))
        #expect(CMFormatDescriptionGetMediaSubType(format) == (item.kind == .h264 ? kCMVideoCodecType_H264
            : kCMVideoCodecType_HEVC))
        #expect(pictures.first?.sample.isKeyframe == true)
    }

    /// VideoToolbox decodes every picture (hardware where the Mac has it) and the stage restores display order.
    @Test(arguments: cases)
    func decodesEveryPictureInDisplayOrder(_ item: Case) throws {
        guard let (_, pictures) = Self.stream(item) else { return }
        let (outputs, admitted) = try Self.decode(pictures, tier: .single)
        #expect(admitted == pictures.count)
        #expect(outputs.count == pictures.count)
        #expect(Self.times(outputs) == pictures.map(\.info.pts).sorted())
        let image = try #require(outputs.first.flatMap { CMSampleBufferGetImageBuffer($0) })
        #expect(CVPixelBufferGetWidth(image) == SyntheticNALStream.width)
        #expect(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
    }

    /// `.reduced` drops only non-reference pictures and `.keyframesOnly` keeps keyframes; everything admitted
    /// decodes, in order.
    @Test(arguments: cases)
    func decodeTiersFilterAndStillDecode(_ item: Case) throws {
        guard let (_, pictures) = Self.stream(item) else { return }
        let reduced = try Self.decode(pictures, tier: .reduced)
        #expect(reduced.admitted == pictures.filter { $0.info.role != .nonReference }.count)
        #expect(reduced.outputs.count == reduced.admitted)
        #expect(Self.times(reduced.outputs) == Self.times(reduced.outputs).sorted())
        let keyframes = try Self.decode(pictures, tier: .keyframesOnly)
        #expect(keyframes.admitted == pictures.filter { $0.info.role == .keyframe }.count)
        #expect(keyframes.outputs.count == keyframes.admitted)
        // Raised from suspended mid-GOP: nothing until the next keyframe, then every picture decodes.
        let resumed = try Self.decode(pictures, tier: .single, resumeAt: 3)
        let nextKey = try #require(pictures.indices.first { $0 >= 3 && pictures[$0].info.role == .keyframe })
        // Its leading pictures (HEVC RASL after a CRA) reference the GOP that wasn't decoded and are dropped too.
        let leading = pictures[(nextKey + 1)...].prefix { $0.info.pts < pictures[nextKey].info.pts }.count
        #expect(resumed.admitted == pictures.count - nextKey - leading)
        #expect(resumed.outputs.count == resumed.admitted)
    }

    /// An ATSC 3.0-style program: video plus AC-4 audio, which nothing can decode. The clock runs on video alone and
    /// the stream info says why there is no sound.
    @Test(arguments: cases)
    func playsVideoOnlyWhenTheAudioIsAC4(_ item: Case) async throws {
        guard let encoded = SyntheticNALStream.encode(item.codec) else { return }
        let data = SyntheticNALStream.transportStream(encoded, streamType: item.streamType, withAC4: true)
        let log = StreamInfoLog()
        let renderer = SampleRenderer(videoRenderer: AVSampleBufferDisplayLayer().sampleBufferRenderer)
        let ring = MemoryByteRing(capacity: 4 << 20)
        let pipeline = TransportStreamPipeline(source: FixtureSource(data: data), ring: ring, renderer: renderer,
                                               preferredLanguage: "eng", playsAudio: false) { log.add($0) }
        pipeline.start()
        defer { pipeline.stop() }
        #expect(try await eventually { log.started != nil })
        let info = try #require(log.started)
        #expect(info.videoCodec == item.testDescription)
        #expect(info.width == SyntheticNALStream.width && info.height == SyntheticNALStream.height)
        #expect(info.audioCodec == nil)
        #expect(info.unsupportedAudioCodec == "AC-4")
        #expect(try await eventually { pipeline.queue.sync { renderer.hasStartedClock } })
        #expect(log.failure == nil)
    }
}

/// Keeps a pipeline's start announcement and any failure.
nonisolated final class StreamInfoLog: @unchecked Sendable {
    // @unchecked: every property is only touched under `lock`.
    private let lock = NSLock()
    private var info: PlaybackStreamInfo?
    private var error: PlaybackError?
    private var kinds: [String] = []

    func add(_ event: TransportStreamPipeline.Event) {
        lock.withLock {
            switch event {
            case .started(let started): info = started
            case .failed(let failure): error = failure
            default: break
            }
            kinds.append(String(describing: event).prefix { $0 != "(" }.description)
        }
    }

    var started: PlaybackStreamInfo? { lock.withLock { info } }
    var failure: PlaybackError? { lock.withLock { error } }
    /// The events' names in order ("started", "finished", …).
    var events: [String] { lock.withLock { kinds } }
}
#endif
