//
//  LumaCopier.swift
//  PlaybackKit
//
//  Copies one field of luma from regions of a pixel buffer. Reads 8-bit bi-planar (420v/420f), 10-bit bi-planar
//  (x420/xf20, high byte) and 8-bit planar (y420) layouts; anything else yields no patches. Buffers are locked
//  read-only, so an IOSurface on unified memory is read in place.
//

import CoreGraphics
import CoreVideo
import Foundation

nonisolated enum LumaCopier {
    static func copyFieldRows(of buffer: CVPixelBuffer, regions: [CGRect], margin: Int) -> [LumaPatch] {
        let format = CVPixelBufferGetPixelFormatType(buffer)
        let bytesPerSample: Int
        switch format {
        case kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr8BiPlanarFullRange,
             kCVPixelFormatType_420YpCbCr8Planar, kCVPixelFormatType_420YpCbCr8PlanarFullRange:
            bytesPerSample = 1
        case kCVPixelFormatType_420YpCbCr10BiPlanarVideoRange, kCVPixelFormatType_420YpCbCr10BiPlanarFullRange:
            bytesPerSample = 2
        default:
            return []
        }
        guard CVPixelBufferLockBaseAddress(buffer, .readOnly) == kCVReturnSuccess else { return [] }
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        let planar = CVPixelBufferIsPlanar(buffer)
        guard let base = planar ? CVPixelBufferGetBaseAddressOfPlane(buffer, 0) : CVPixelBufferGetBaseAddress(buffer)
        else { return [] }
        let stride = planar ? CVPixelBufferGetBytesPerRowOfPlane(buffer, 0) : CVPixelBufferGetBytesPerRow(buffer)
        let frameWidth = planar ? CVPixelBufferGetWidthOfPlane(buffer, 0) : CVPixelBufferGetWidth(buffer)
        let frameHeight = planar ? CVPixelBufferGetHeightOfPlane(buffer, 0) : CVPixelBufferGetHeight(buffer)
        let plane = UnsafeRawBufferPointer(start: base, count: stride * frameHeight)
        return regions.compactMap { region in
            let rect = pixelRect(region, width: frameWidth, height: frameHeight, margin: margin)
            return copy(rect, from: plane, stride: stride, bytesPerSample: bytesPerSample)
        }
    }

    /// `region` (normalized, top-left origin) in pixels, grown by `margin`, clamped, starting on an even row.
    static func pixelRect(_ region: CGRect, width: Int, height: Int, margin: Int) -> CGRect {
        let minX = max(0, Int((region.minX * CGFloat(width)).rounded(.down)) - margin)
        let maxX = min(width, Int((region.maxX * CGFloat(width)).rounded(.up)) + margin)
        var minY = max(0, Int((region.minY * CGFloat(height)).rounded(.down)) - margin)
        minY -= minY % 2
        let maxY = min(height, Int((region.maxY * CGFloat(height)).rounded(.up)) + margin)
        return CGRect(x: minX, y: minY, width: max(0, maxX - minX), height: max(0, maxY - minY))
    }

    private static func copy(_ rect: CGRect, from plane: UnsafeRawBufferPointer, stride: Int,
                             bytesPerSample: Int) -> LumaPatch? {
        let width = Int(rect.width)
        let fieldRows = (Int(rect.height) + 1) / 2
        guard width > 0, fieldRows > 0 else { return nil }
        var bytes = Data(count: width * fieldRows)
        bytes.withUnsafeMutableBytes { output in
            for fieldRow in 0..<fieldRows {
                let row = Int(rect.minY) + fieldRow * 2
                let source = row * stride + Int(rect.minX) * bytesPerSample
                for column in 0..<width {
                    // 10-bit samples are little-endian 16-bit words with the value in the high bits.
                    let offset = source + column * bytesPerSample + (bytesPerSample - 1)
                    output[fieldRow * width + column] = plane[offset]
                }
            }
        }
        return LumaPatch(rect: rect, width: width, height: fieldRows, bytes: bytes)
    }
}
