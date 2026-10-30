//
//  VideoFrameStageTierTests.swift
//  PlaybackKitTests
//
//  The video stage at each decode tier, on the synthetic 480i fixture: picture types reach the stage, grid tiles get
//  one bob picture per frame, I-only decoding hands each picture out at once, and tier changes mid-stream keep the
//  output in order.
//

import CoreMedia
import CoreVideo
import Foundation
import Metal
import MPEGTS
import Testing
@testable import PlaybackKit

#if !os(tvOS)
struct VideoFrameStageTierTests {
    private let pictures: [CompressedPicture]

    init() throws {
        pictures = SyntheticVideoFixture.pictures(in: try SyntheticVideoFixture.data("testsrc-480i"))
    }

    private static func times(_ samples: [CMSampleBuffer]) -> [Int64] {
        samples.map { CMSampleBufferGetPresentationTimeStamp($0).value }
    }

    /// The framer's picture_coding_type travels with each compressed picture, as its role.
    @Test func picturesCarryTheirCodingType() {
        let roles = pictures.map(\.info.role)
        #expect(roles.first == .keyframe)
        #expect(roles.contains(.reference))
        #expect(roles.contains(.nonReference))
        #expect(pictures.filter { $0.sample.isKeyframe }.allSatisfy { $0.info.role == .keyframe })
    }

    /// Runs every picture the gate admits at `tier` through a stage set to it.
    private func run(_ tier: DecodeTier) throws -> (outputs: [CMSampleBuffer], admitted: [CompressedPicture]) {
        let stage = VideoFrameStage(decoder: LibavVideoDecoder())
        stage.apply(tier)
        var gate = DecodeTierGate()
        gate.set(tier)
        let admitted = pictures.filter { gate.admit($0.info.role, pts: $0.info.pts) }
        var outputs: [CMSampleBuffer] = []
        for picture in admitted { outputs += try stage.process(picture.sample, info: picture.info) }
        outputs += try stage.drain()
        return (outputs, admitted)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func gridTilesShowOneFullSizePicturePerFrame() throws {
        let (outputs, admitted) = try run(.full(fieldRate: false))
        #expect(Self.times(outputs) == admitted.map(\.info.pts).sorted())
        for sample in outputs {
            let image = try #require(CMSampleBufferGetImageBuffer(sample))
            #expect(CVPixelBufferGetWidth(image) == 720 && CVPixelBufferGetHeight(image) == 480)
            #expect(CVBufferCopyAttachment(image, kCVImageBufferFieldCountKey, nil) as? Int == 1)
        }
        // The single-stream tier shows two pictures per frame from the same input.
        #expect(try run(.single).outputs.count == 2 * admitted.count)
    }

    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func reducedTierShowsOnlyIntraAndPredictedPictures() throws {
        let (outputs, admitted) = try run(.reduced)
        #expect(admitted.allSatisfy { $0.info.role != .nonReference })
        #expect(Self.times(outputs) == admitted.map(\.info.pts).sorted())
    }

    /// An I picture needs nothing else, so it goes out with the call that decoded it, not a GOP later.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func keyframesOnlyHandsEachPictureOutAtOnce() throws {
        let stage = VideoFrameStage(decoder: LibavVideoDecoder())
        stage.apply(.keyframesOnly)
        let intra = pictures.filter { $0.info.role == .keyframe }
        #expect(!intra.isEmpty)
        for picture in intra {
            let ready = try stage.process(picture.sample, info: picture.info) + stage.collectReadyAfterGPU()
            #expect(Self.times(ready) == [picture.info.pts])
        }
    }

    /// Tier changes between pictures (as the pipeline makes them) keep the output strictly in order.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func tierChangesMidStreamKeepTheOutputInOrder() throws {
        let stage = VideoFrameStage(decoder: LibavVideoDecoder())
        var gate = DecodeTierGate()
        let plan: [Int: DecodeTier] = [2: .full(fieldRate: false), 4: .reduced, 6: .single,
                                       8: .full(fieldRate: false)]
        var outputs: [CMSampleBuffer] = []
        for (index, picture) in pictures.enumerated() {
            if let tier = plan[index] {
                gate.set(tier)
                stage.apply(tier)
            }
            guard gate.admit(picture.info.role, pts: picture.info.pts) else { continue }
            outputs += try stage.process(picture.sample, info: picture.info)
        }
        outputs += try stage.drain()
        let times = Self.times(outputs)
        #expect(!times.isEmpty)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
    }
}

extension VideoFrameStage {
    /// What `collectReady()` hands out once the GPU passes in flight have finished (tests).
    func collectReadyAfterGPU() -> [CMSampleBuffer] {
        Thread.sleep(forTimeInterval: 0.05)
        return collectReady()
    }
}

extension CMSampleBuffer {
    /// Not marked NotSync: a sequence header and an I picture.
    var isKeyframe: Bool {
        let array = CMSampleBufferGetSampleAttachmentsArray(self, createIfNecessary: false)
        guard let attachments = array as? [[CFString: Any]], let first = attachments.first else { return true }
        return first[kCMSampleAttachmentKey_NotSync] as? Bool != true
    }
}
#endif
