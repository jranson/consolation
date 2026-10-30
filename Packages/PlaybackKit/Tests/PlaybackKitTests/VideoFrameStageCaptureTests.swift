import CoreMedia
import Foundation
import MPEGTS
import Testing
@testable import PlaybackKit

#if os(macOS)
/// Opt-in: runs only when a local (gitignored) HDHomeRun capture exists, so CI skips it.
struct VideoFrameStageCaptureTests {
    private nonisolated static let capture = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("localdata/captures/hdhr-9.1.ts")

    @Test(.enabled(if: FileManager.default.fileExists(atPath: capture.path)))
    func interlacedCaptureBecomesFieldRateProgressive() throws {
        let data = try Data(contentsOf: Self.capture)
        var demuxer = TSDemuxer()
        var processor = ElementaryProcessor()
        let stage = VideoFrameStage()
        var pictures = 0
        var outputs: [CMSampleBuffer] = []
        for event in demuxer.feed(data) {
            switch event {
            case .programs(let programs):
                if let program = programs.first {
                    processor.select(video: TrackSelection.video(in: program), audio: nil)
                }
            case .pes(let pes) where pes.pid == processor.videoPID:
                for picture in processor.videoSamples(from: pes) {
                    pictures += 1
                    outputs += try stage.process(picture.sample, info: picture.info)
                }
            default:
                break
            }
        }
        outputs += try stage.drain()
        #expect(pictures > 300)
        // Two progressive pictures per interlaced one.
        #expect(outputs.count == pictures * 2)
        let times = outputs.map { CMSampleBufferGetPresentationTimeStamp($0).value }
        let steps = zip(times, times.dropFirst()).map { $1 - $0 }
        #expect(steps.allSatisfy { $0 > 0 })
        // 1080i at 29.97 becomes 59.94 pictures per second: 1501 or 1502 ticks of 90 kHz apart.
        let typical = steps.sorted()[steps.count / 2]
        #expect((1_500...1_502).contains(typical))
        if let image = outputs.first.flatMap(CMSampleBufferGetImageBuffer) {
            #expect(CVPixelBufferGetWidth(image) == 1_920)
            #expect(CVPixelBufferGetHeight(image) == 1_080)
        }
    }
}
#endif
