//
//  LibavInputTests.swift
//  PlaybackKitTests
//
//  How compressed pictures reach libavcodec: padded sample buffers are decoded in place (libavcodec holds a reference
//  until its buffer's free callback), anything else is copied. Run under the address sanitizer to check lifetimes:
//
//      swift test --sanitize=address --filter "LibavInputTests|LibavVideoDecoderTests"
//

import CoreMedia
import CoreVideo
import Foundation
import Testing
@testable import PlaybackKit

#if !os(tvOS)
struct LibavInputTests {
    private let pictures: [CompressedPicture]

    init() throws {
        pictures = SyntheticVideoFixture.pictures(in: try SyntheticVideoFixture.data("testsrc-480i"))
    }

    /// The same pictures in sample buffers without padding, which the decoder has to copy.
    private func unpadded() throws -> [CompressedPicture] {
        try pictures.map { picture in
            let sample = picture.sample
            let size = CMSampleBufferGetTotalSampleSize(sample)
            let block = try #require(CMSampleBufferGetDataBuffer(sample))
            var data = Data(count: size)
            let copied = data.withUnsafeMutableBytes { raw in
                CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: raw.baseAddress!)
            }
            #expect(copied == kCMBlockBufferNoErr)
            let timing = SampleFormats.Timing(
                pts: CMSampleBufferGetPresentationTimeStamp(sample).value,
                dts: CMSampleBufferGetDecodeTimeStamp(sample).value,
                duration: CMSampleBufferGetDuration(sample).value)
            let format = try #require(CMSampleBufferGetFormatDescription(sample))
            let copy = try #require(SampleFormats.videoSample(data: data, format: format, timing: timing,
                                                              isKeyframe: picture.info.role == .keyframe))
            return CompressedPicture(sample: copy, info: picture.info)
        }
    }

    @Test func framedPicturesCarryZeroedPadding() throws {
        #expect(pictures.count == 10)
        for picture in pictures {
            let block = try #require(CMSampleBufferGetDataBuffer(picture.sample))
            let size = CMSampleBufferGetTotalSampleSize(picture.sample)
            #expect(CMBlockBufferGetDataLength(block) == size + LibavVideoDecoder.inputPadding)
            #expect(LibavVideoDecoder.paddedBytes(of: block, size: size) != nil)
        }
        for picture in try unpadded() {
            let block = try #require(CMSampleBufferGetDataBuffer(picture.sample))
            let size = CMSampleBufferGetTotalSampleSize(picture.sample)
            #expect(LibavVideoDecoder.paddedBytes(of: block, size: size) == nil)
        }
    }

    @Test func nonZeroPaddingIsNotSentInPlace() throws {
        let bytes: [UInt8] = [0, 0, 1, 0xB3] + [UInt8](repeating: 0, count: LibavVideoDecoder.inputPadding)
        var dirty = bytes
        dirty[dirty.count - 1] = 1
        let clean = try #require(bytes.withUnsafeBytes { SampleFormats.blockBuffer(copying: $0) })
        let damaged = try #require(dirty.withUnsafeBytes { SampleFormats.blockBuffer(copying: $0) })
        #expect(LibavVideoDecoder.paddedBytes(of: clean, size: 4) != nil)
        #expect(LibavVideoDecoder.paddedBytes(of: damaged, size: 4) == nil)
    }

    /// Sending in place gives exactly the pictures a copied send does.
    @Test func inPlaceSendMatchesCopiedSend() throws {
        let inPlace = try SyntheticVideoFixture.decode(pictures, with: LibavVideoDecoder(output: .cpuPixelBuffers))
        let copied = try SyntheticVideoFixture.decode(try unpadded(),
                                                      with: LibavVideoDecoder(output: .cpuPixelBuffers))
        #expect(inPlace.count == pictures.count)
        #expect(inPlace.map(\.pts) == copied.map(\.pts))
        for (lhs, rhs) in zip(inPlace, copied) {
            #expect(SyntheticVideoFixture.meanDifference(lhs.pixelBuffer, rhs.pixelBuffer, plane: 0) == 0)
            #expect(SyntheticVideoFixture.meanDifference(lhs.pixelBuffer, rhs.pixelBuffer, plane: 1) == 0)
        }
    }

    /// libavcodec lets go of every sample buffer it referenced: by the time the decoder closes, each is held only
    /// by its sample again.
    @Test func referencesAreReleased() throws {
        let blocks = try pictures.map { try #require(CMSampleBufferGetDataBuffer($0.sample)) }
        let before = blocks.map(CFGetRetainCount)
        let decoder = LibavVideoDecoder(output: .cpuPixelBuffers)
        _ = try SyntheticVideoFixture.decode(pictures, with: decoder)
        decoder.invalidate()
        #expect(blocks.map(CFGetRetainCount) == before)
    }
}
#endif
