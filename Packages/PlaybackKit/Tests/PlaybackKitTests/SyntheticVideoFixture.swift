//
//  SyntheticVideoFixture.swift
//  PlaybackKitTests
//
//  Loads the synthetic MPEG-2 transport streams made by scripts/make-test-fixtures.sh (FFmpeg test sources only;
//  no broadcast content) and runs them through the demuxer, the framer and a decoder.
//

import CoreMedia
import CoreVideo
import Foundation
import MPEGTS
@testable import PlaybackKit

#if !os(tvOS)
extension DecodedFrame {
    /// The picture once its GPU pass (if any) has finished, so its pixels can be read.
    nonisolated func finished() -> DecodedFrame {
        gpuWork?.waitUntilCompleted()
        return self
    }
}

nonisolated enum SyntheticVideoFixture {
    enum FixtureError: Error {
        case missing(String)
    }

    static func data(_ name: String) throws -> Data {
        guard let url = Bundle.module.url(forResource: name, withExtension: "ts", subdirectory: "Fixtures") else {
            throw FixtureError.missing(name)
        }
        return try Data(contentsOf: url)
    }

    /// The compressed pictures of the first program's video, in decode order, framed from lent payloads as the
    /// pipeline does.
    static func pictures(in data: Data) -> [CompressedPicture] {
        var demuxer = TSDemuxer()
        var processor = ElementaryProcessor()
        var pictures: [CompressedPicture] = []
        func handle(_ event: TSDemuxBorrowedEvent) {
            switch event {
            case .programs(let programs, _):
                if let program = programs.first {
                    processor.select(video: TrackSelection.video(in: program), audio: nil)
                }
            case .pes(let pes, let payload) where pes.pid == processor.videoPID:
                pictures += processor.videoSamples(from: pes, payload: payload)
            default:
                break
            }
        }
        demuxer.feed(data, handle)
        demuxer.flush(handle)
        return pictures + processor.flushVideo()
    }

    /// Every picture the decoder emits for `pictures`, including those it holds until the end of the stream.
    static func decode(_ pictures: [CompressedPicture], with decoder: any VideoDecoding) throws -> [DecodedFrame] {
        var frames: [DecodedFrame] = []
        for picture in pictures {
            frames += try decoder.decode(picture.sample, info: picture.info)
        }
        frames += try decoder.drain()
        return frames.map { $0.finished() }
    }

    /// Mean absolute difference between the same plane of two NV12 buffers of equal size.
    static func meanDifference(_ lhs: CVPixelBuffer?, _ rhs: CVPixelBuffer?, plane: Int) -> Double {
        guard let lhs, let rhs else { return .infinity }
        CVPixelBufferLockBaseAddress(lhs, .readOnly)
        CVPixelBufferLockBaseAddress(rhs, .readOnly)
        defer {
            CVPixelBufferUnlockBaseAddress(lhs, .readOnly)
            CVPixelBufferUnlockBaseAddress(rhs, .readOnly)
        }
        guard let left = CVPixelBufferGetBaseAddressOfPlane(lhs, plane),
              let right = CVPixelBufferGetBaseAddressOfPlane(rhs, plane) else { return .infinity }
        let rowBytes = CVPixelBufferGetWidthOfPlane(lhs, plane) * (plane == 0 ? 1 : 2)
        let rows = CVPixelBufferGetHeightOfPlane(lhs, plane)
        let leftStride = CVPixelBufferGetBytesPerRowOfPlane(lhs, plane)
        let rightStride = CVPixelBufferGetBytesPerRowOfPlane(rhs, plane)
        var total = 0
        for row in 0..<rows {
            let leftRow = left.advanced(by: row * leftStride).assumingMemoryBound(to: UInt8.self)
            let rightRow = right.advanced(by: row * rightStride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<rowBytes {
                total += abs(Int(leftRow[column]) - Int(rightRow[column]))
            }
        }
        return Double(total) / Double(max(rowBytes * rows, 1))
    }
}
#endif
