//
//  NV12BufferPool.swift
//  PlaybackKit
//
//  A CVPixelBufferPool of IOSurface-backed, Metal-compatible NV12 ('420v') buffers that follows the picture size.
//  Used by the libavcodec decoder's output and by the deinterlacer.
//

import CoreVideo

nonisolated struct NV12BufferPool {
    private var pool: CVPixelBufferPool?
    private var size: (width: Int, height: Int) = (0, 0)

    /// A buffer of `width` x `height`, recreating the pool when the size changes. Nil if CoreVideo fails.
    mutating func make(width: Int, height: Int) -> CVPixelBuffer? {
        if pool == nil || size != (width, height) {
            let attributes: [CFString: Any] = [
                kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                kCVPixelBufferWidthKey: width,
                kCVPixelBufferHeightKey: height,
                kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
                kCVPixelBufferMetalCompatibilityKey: true
            ]
            var newPool: CVPixelBufferPool?
            CVPixelBufferPoolCreate(nil, [kCVPixelBufferPoolMinimumBufferCountKey: 8] as CFDictionary,
                                    attributes as CFDictionary, &newPool)
            pool = newPool
            size = (width, height)
        }
        guard let pool else { return nil }
        var buffer: CVPixelBuffer?
        CVPixelBufferPoolCreatePixelBuffer(nil, pool, &buffer)
        return buffer
    }
}
