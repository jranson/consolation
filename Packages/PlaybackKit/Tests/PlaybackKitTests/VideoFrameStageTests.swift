import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
@testable import PlaybackKit

#if !os(tvOS)
/// The stage hands pictures out without waiting for the GPU: what is still rendering stays in flight and goes out
/// later, in order, and nothing is lost or duplicated.
struct VideoFrameStageTests {
    private let pictures: [CompressedPicture]

    init() throws {
        pictures = SyntheticVideoFixture.pictures(in: try SyntheticVideoFixture.data("testsrc-480i"))
    }

    private static func times(_ samples: [CMSampleBuffer]) -> [Int64] {
        samples.map { CMSampleBufferGetPresentationTimeStamp($0).value }
    }

    @Test func inFlightPicturesComeOutInOrderExactlyOnce() throws {
        let stage = VideoFrameStage(decoder: LibavVideoDecoder())
        var outputs: [CMSampleBuffer] = []
        for picture in pictures {
            outputs += try stage.process(picture.sample, info: picture.info)
        }
        outputs += try stage.drain()
        let times = Self.times(outputs)
        #expect(times.count == pictures.count * 2 || times.count == pictures.count)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
        // Every picture handed out is finished: its pixels are final.
        for sample in outputs {
            let image = try #require(CMSampleBufferGetImageBuffer(sample))
            #expect(CVBufferCopyAttachment(image, kCVImageBufferFieldCountKey, nil) as? Int == 1)
            #expect(!CVBufferHasAttachment(image, kCVImageBufferFieldDetailKey))
        }
    }

    @Test func collectReadyReleasesFinishedPicturesWithoutDecoding() async throws {
        let stage = VideoFrameStage(decoder: LibavVideoDecoder())
        var outputs: [CMSampleBuffer] = []
        for picture in pictures {
            outputs += try stage.process(picture.sample, info: picture.info)
        }
        // Give the GPU time to finish the last picture, then collect it without another decode.
        try await Task.sleep(for: .milliseconds(200))
        let collected = stage.collectReady()
        #expect(stage.collectReady().isEmpty)
        let drained = try stage.drain()
        let times = Self.times(outputs + collected + drained)
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
        #expect(times.count == pictures.count * 2 || times.count == pictures.count)
    }

    @Test func resetDropsInFlightPictures() throws {
        let stage = VideoFrameStage(decoder: LibavVideoDecoder())
        for picture in pictures.prefix(6) {
            _ = try stage.process(picture.sample, info: picture.info)
        }
        stage.reset()
        #expect(stage.collectReady().isEmpty)
        #expect(try stage.drain().isEmpty)
    }

    @Test func timingsCountPicturesAndReset() throws {
        let stage = VideoFrameStage(decoder: LibavVideoDecoder())
        for picture in pictures {
            _ = try stage.process(picture.sample, info: picture.info)
        }
        let timings = stage.takeTimings()
        #expect(timings.pictures == pictures.count)
        #expect(timings.total > 0)
        #expect(timings.decode > 0)
        #expect(timings.total >= timings.decode)
        #expect(!timings.summary.isEmpty)
        #expect(stage.takeTimings().pictures == 0)
    }
}
#endif
