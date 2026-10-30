import CoreMedia
import CoreVideo
import Foundation
import Metal
import Testing
@testable import PlaybackKit

#if !os(tvOS)
/// libavcodec decoding of the synthetic 480i fixture (10 pictures of FFmpeg's testsrc, IBBPBBPBBP).
struct LibavVideoDecoderTests {
    private let pictures: [CompressedPicture]

    init() throws {
        pictures = SyntheticVideoFixture.pictures(in: try SyntheticVideoFixture.data("testsrc-480i"))
    }

    @Test func decodesToIOSurfaceNV12WithTimingPreserved() throws {
        #expect(pictures.count == 10)
        let frames = try SyntheticVideoFixture.decode(pictures, with: LibavVideoDecoder())
        #expect(frames.count == pictures.count)
        #expect(Set(frames.map(\.pts)) == Set(pictures.map(\.info.pts)))
        // libavcodec emits display order; the decode order of the fixture is not.
        #expect(frames.map(\.pts) == frames.map(\.pts).sorted())
        #expect(pictures.map(\.info.pts) != pictures.map(\.info.pts).sorted())
        let infos = Dictionary(uniqueKeysWithValues: pictures.map { ($0.info.pts, $0.info) })
        for frame in frames {
            let image = try #require(frame.pixelBuffer)
            #expect(CVPixelBufferGetWidth(image) == 720)
            #expect(CVPixelBufferGetHeight(image) == 480)
            #expect(CVPixelBufferGetPixelFormatType(image) == kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange)
            #expect(CVPixelBufferGetIOSurface(image) != nil)
            #expect(frame.duration == infos[frame.pts]?.duration)
            #expect(frame.duration == 3_003)
            #expect(frame.isInterlaced)
            #expect(frame.topFieldFirst)
            let fields = CVBufferCopyAttachment(image, kCVImageBufferFieldCountKey, nil) as? Int
            #expect(fields == 2)
        }
    }

    #if os(macOS)
    @Test func matchesVideoToolboxOutput() throws {
        let libav = try SyntheticVideoFixture.decode(pictures, with: LibavVideoDecoder()).sorted { $0.pts < $1.pts }
        let toolbox = try SyntheticVideoFixture.decode(pictures, with: VTVideoDecoder()).sorted { $0.pts < $1.pts }
        #expect(libav.count == toolbox.count)
        #expect(libav.map(\.pts) == toolbox.map(\.pts))
        for (ours, reference) in zip(libav, toolbox) {
            let image = try #require(ours.pixelBuffer)
            let referenceImage = try #require(reference.pixelBuffer)
            #expect(CVPixelBufferGetWidth(image) == CVPixelBufferGetWidth(referenceImage))
            #expect(CVPixelBufferGetHeight(image) == CVPixelBufferGetHeight(referenceImage))
            #expect(CVPixelBufferGetPixelFormatType(image) == CVPixelBufferGetPixelFormatType(referenceImage))
            // Both are conforming IDCT decoders, so the pictures agree to within rounding (luma, then Cb/Cr pairs).
            #expect(SyntheticVideoFixture.meanDifference(ours.pixelBuffer, reference.pixelBuffer, plane: 0) < 1.5)
            #expect(SyntheticVideoFixture.meanDifference(ours.pixelBuffer, reference.pixelBuffer, plane: 1) < 1.5)
        }
    }
    #endif

    @Test func frameStageTurnsLibavOutputIntoFieldRatePictures() throws {
        let stage = VideoFrameStage(decoder: LibavVideoDecoder())
        var outputs: [CMSampleBuffer] = []
        for picture in pictures {
            outputs += try stage.process(picture.sample, info: picture.info)
        }
        outputs += try stage.drain()
        // Two progressive pictures per interlaced one when Metal is available; one each without it.
        #expect(outputs.count == pictures.count * 2 || outputs.count == pictures.count)
        let times = outputs.map { CMSampleBufferGetPresentationTimeStamp($0).value }
        #expect(zip(times, times.dropFirst()).allSatisfy { $1 > $0 })
        if let image = outputs.first.flatMap(CMSampleBufferGetImageBuffer) {
            #expect(CVPixelBufferGetWidth(image) == 720)
            #expect(CVPixelBufferGetHeight(image) == 480)
        }
    }

    @Test func libavcodecIsTheMPEG2DecoderEverywhere() {
        #expect(VideoDecoders.mpeg2() is LibavVideoDecoder)
        #if os(macOS)
        #expect(VideoDecoders.mpeg2(.videoToolbox) is VTVideoDecoder)
        #else
        #expect(VideoDecoders.mpeg2(.videoToolbox) is LibavVideoDecoder)
        #endif
    }

    /// With a GPU stage's device the decoder hands its pictures over in place: no conversion, no NV12 buffers.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func planarOutputKeepsPicturesInPlace() throws {
        let device = try #require(MTLCreateSystemDefaultDevice())
        let decoder = LibavVideoDecoder(output: .planar(device))
        let frames = try SyntheticVideoFixture.decode(pictures, with: decoder)
        #expect(frames.count == pictures.count)
        #expect(decoder.gpuConversions == 0)
        for frame in frames {
            let planar = try #require(frame.planar)
            #expect(planar.layout.width == 720 && planar.layout.height == 480)
            #expect(planar.textures() != nil)
            #expect(planar.attachments[kCVImageBufferFieldCountKey] as? Int == 2)
        }
    }

    /// The playback stage (planar pictures deinterlaced in place) gives the same pictures as deinterlacing the
    /// decoder's NV12 conversion.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func stageReadingPlanesMatchesStageReadingNV12() throws {
        let inPlace = try Self.images(from: VideoFrameStage())
        let converted = try Self.images(from: VideoFrameStage(decoder: LibavVideoDecoder()))
        #expect(inPlace.count == converted.count)
        #expect(inPlace.count == pictures.count * 2)
        for (lhs, rhs) in zip(inPlace, converted) {
            #expect(SyntheticVideoFixture.meanDifference(lhs, rhs, plane: 0) == 0)
            #expect(SyntheticVideoFixture.meanDifference(lhs, rhs, plane: 1) == 0)
        }
    }

    private static func images(from stage: VideoFrameStage) throws -> [CVPixelBuffer] {
        let pictures = try SyntheticVideoFixture.pictures(in: SyntheticVideoFixture.data("testsrc-480i"))
        var samples: [CMSampleBuffer] = []
        for picture in pictures { samples += try stage.process(picture.sample, info: picture.info) }
        samples += try stage.drain()
        return samples.compactMap(CMSampleBufferGetImageBuffer)
    }

    /// The zero-copy path (page-aligned get_buffer2 pool, Metal I420-to-NV12) matches the CPU copy exactly.
    @Test(.enabled(if: MTLCreateSystemDefaultDevice() != nil))
    func gpuConversionMatchesCPUCopy() throws {
        let decoder = LibavVideoDecoder()
        let gpu = try SyntheticVideoFixture.decode(pictures, with: decoder)
        let cpu = try SyntheticVideoFixture.decode(pictures, with: LibavVideoDecoder(output: .cpuPixelBuffers))
        #expect(decoder.gpuConversions == pictures.count)
        #expect(gpu.map(\.pts) == cpu.map(\.pts))
        for (ours, reference) in zip(gpu, cpu) {
            #expect(SyntheticVideoFixture.meanDifference(ours.pixelBuffer, reference.pixelBuffer, plane: 0) == 0)
            #expect(SyntheticVideoFixture.meanDifference(ours.pixelBuffer, reference.pixelBuffer, plane: 1) == 0)
        }
    }

    @Test func invalidateRestartsCleanly() throws {
        let decoder = LibavVideoDecoder()
        _ = try SyntheticVideoFixture.decode(Array(pictures.prefix(4)), with: decoder)
        decoder.invalidate()
        let frames = try SyntheticVideoFixture.decode(pictures, with: decoder)
        #expect(frames.count == pictures.count)
    }
}

/// LGPL-2.1 compliance: the linked FFmpeg must stay LGPL-2.1-or-later.
struct SoftwareDecoderLibraryTests {
    @Test func licenceIsLGPL21OrLater() {
        #expect(SoftwareDecoderLibrary.license == "LGPL version 2.1 or later")
        #expect(SoftwareDecoderLibrary.utilityLicense == "LGPL version 2.1 or later")
    }

    @Test func configurationHasNoGPLNonfreeOrVersion3() {
        let configurations = [SoftwareDecoderLibrary.configuration, SoftwareDecoderLibrary.utilityConfiguration]
        for configuration in configurations {
            #expect(!configuration.isEmpty)
            for flag in ["--enable-gpl", "--enable-nonfree", "--enable-version3"] {
                #expect(!configuration.contains(flag))
            }
            #expect(configuration.contains("--disable-everything"))
        }
    }

    @Test func versionIsReported() {
        #expect(SoftwareDecoderLibrary.name.hasPrefix("FFmpeg 9."))
        #expect(SoftwareDecoderLibrary.codecVersion.hasPrefix("63."))
    }
}
#endif
