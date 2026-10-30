//
//  FrameTapTests.swift
//  PlaybackKitTests
//

import CoreMedia
import CoreVideo
import Foundation
@testable import PlaybackKit
import Testing

struct FrameTapTests {
    /// A 64 × 32 NV12 buffer whose luma value is the row number.
    private func rowNumberedBuffer() throws -> CVPixelBuffer {
        var created: CVPixelBuffer?
        CVPixelBufferCreate(nil, 64, 32, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, nil, &created)
        let buffer = try #require(created)
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        let base = try #require(CVPixelBufferGetBaseAddressOfPlane(buffer, 0)).assumingMemoryBound(to: UInt8.self)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        for row in 0..<32 {
            for column in 0..<64 { base[row * stride + column] = UInt8(row) }
        }
        return buffer
    }

    @Test func copiesOneFieldOfEachRegion() throws {
        let buffer = try rowNumberedBuffer()
        let region = CGRect(x: 0.25, y: 0.25, width: 0.25, height: 0.5)
        let patches = LumaCopier.copyFieldRows(of: buffer, regions: [region], margin: 0)
        let patch = try #require(patches.first)
        #expect(patch.rect == CGRect(x: 16, y: 8, width: 16, height: 16))
        #expect(patch.width == 16)
        #expect(patch.height == 8)
        // Rows 8, 10, 12 … 22: one field.
        #expect(Array(patch.bytes.prefix(1)) == [8])
        #expect(patch.bytes[16] == 10)
        #expect(patch.bytes.last == 22)
    }

    @Test func marginsAreClampedToTheFrame() {
        let rect = LumaCopier.pixelRect(CGRect(x: 0, y: 0.9, width: 0.1, height: 0.1), width: 64, height: 32,
                                        margin: 4)
        #expect(rect.minX == 0)
        #expect(rect.maxY == 32)
        #expect(Int(rect.minY) % 2 == 0)
    }

    @Test func hubDeliversAtTheRequestedRate() async throws {
        let hub = FrameTapHub()
        let buffer = try rowNumberedBuffer()
        let stream = hub.add(FrameTapRequest(regions: [CGRect(x: 0, y: 0, width: 1, height: 1)], samplesPerSecond: 2))
        // Ten frames 0.1 s apart (1 s of video) at 2 samples per second: frames 0 and 5.
        for index in 0..<10 {
            hub.offer(buffer, at: CMTime(value: Int64(index) * 9_000, timescale: 90_000))
        }
        hub.finishAll()
        var times: [Double] = []
        for await sample in stream { times.append(sample.presentationTime.seconds) }
        #expect(times == [0, 0.5])
        #expect(!hub.isActive)
    }
}
