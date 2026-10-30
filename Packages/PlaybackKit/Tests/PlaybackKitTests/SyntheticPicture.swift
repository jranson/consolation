//
//  SyntheticPicture.swift
//  PlaybackKitTests
//
//  Builds NV12 IOSurface pictures (and planar ones laid out like libavcodec's) from functions and reads their planes
//  back, for the deinterlacer tests.
//

import CoreVideo
import Foundation
import Metal
@testable import PlaybackKit

nonisolated struct SyntheticPicture {
    /// Luma at (x, y) and the Cb/Cr pair at chroma (x, y) of a progressive picture.
    let luma: (Int, Int) -> UInt8
    let chroma: (Int, Int) -> (UInt8, UInt8)

    /// One plane of an NV12 buffer as rows of bytes (luma: width bytes; chroma: width bytes of Cb/Cr pairs).
    struct Plane: Equatable {
        let rows: [[UInt8]]

        subscript(column: Int, row: Int) -> Int { Int(rows[row][column]) }
    }

    /// A picture whose lines of parity `parity` come from `first` and the others from `second` (two fields woven).
    static func woven(_ first: SyntheticPicture, _ second: SyntheticPicture, firstParity: Int) -> SyntheticPicture {
        SyntheticPicture(luma: { column, row in (row % 2 == firstParity ? first : second).luma(column, row) },
                         chroma: { column, row in (row % 2 == firstParity ? first : second).chroma(column, row) })
    }

    func pixelBuffer(width: Int, height: Int) -> CVPixelBuffer? {
        let attributes: [CFString: Any] = [
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            attributes as CFDictionary, &buffer)
        guard let buffer, CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return nil }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let lumaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chromaBase = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return nil }
        let lumaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 0)
        let chromaStride = CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)
        for row in 0..<height {
            let line = lumaBase.advanced(by: row * lumaStride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<width { line[column] = luma(column, row) }
        }
        for row in 0..<(height / 2) {
            let line = chromaBase.advanced(by: row * chromaStride).assumingMemoryBound(to: UInt8.self)
            for column in 0..<(width / 2) {
                let pair = chroma(column, row)
                line[2 * column] = pair.0
                line[2 * column + 1] = pair.1
            }
        }
        return buffer
    }

    /// The same picture as libavcodec's planar I420 in one Metal buffer: 256-byte plane offsets and 64-byte strides,
    /// as LibavMPEG2's pool lays them out.
    func planar(width: Int, height: Int, device: MTLDevice, interlaced: Bool) -> PlanarPicture? {
        let align = { (value: Int, multiple: Int) in (value + multiple - 1) / multiple * multiple }
        let lumaStride = align(width, 64)
        let chromaStride = align(width / 2, 64)
        let blueOffset = align(lumaStride * (height + 1), 256)
        let redOffset = align(blueOffset + chromaStride * (height / 2 + 1), 256)
        let length = align(redOffset + chromaStride * (height / 2 + 1), 16_384)
        guard let buffer = device.makeBuffer(length: length, options: .storageModeShared) else { return nil }
        let bytes = buffer.contents().assumingMemoryBound(to: UInt8.self)
        for row in 0..<height {
            for column in 0..<width { bytes[row * lumaStride + column] = luma(column, row) }
        }
        for row in 0..<(height / 2) {
            for column in 0..<(width / 2) {
                let pair = chroma(column, row)
                bytes[blueOffset + row * chromaStride + column] = pair.0
                bytes[redOffset + row * chromaStride + column] = pair.1
            }
        }
        let layout = PlanarPicture.Layout(width: width, height: height, lumaOffset: 0, blueOffset: blueOffset,
                                          redOffset: redOffset, lumaStride: lumaStride, chromaStride: chromaStride,
                                          chromaRowStep: 1)
        let attachments: [CFString: Any] = [kCVImageBufferFieldCountKey: interlaced ? 2 : 1]
        return PlanarPicture(buffer: buffer, layout: layout, attachments: attachments, owner: nil)
    }

    /// Plane `index` of `buffer`; no rows when there is no buffer.
    static func plane(_ buffer: CVPixelBuffer?, _ index: Int) -> Plane {
        guard let buffer else { return Plane(rows: []) }
        CVPixelBufferLockBaseAddress(buffer, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(buffer, .readOnly) }
        guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, index) else { return Plane(rows: []) }
        let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, index)
        let rowBytes = CVPixelBufferGetWidthOfPlane(buffer, index) * (index == 0 ? 1 : 2)
        let rows = (0..<CVPixelBufferGetHeightOfPlane(buffer, index)).map { row in
            Array(UnsafeBufferPointer(start: base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self),
                                      count: rowBytes))
        }
        return Plane(rows: rows)
    }

    /// Largest absolute difference between two planes of the same size.
    static func maxDifference(_ lhs: Plane, _ rhs: Plane) -> Int {
        zip(lhs.rows, rhs.rows).map { left, right in
            zip(left, right).map { abs(Int($0) - Int($1)) }.max() ?? 0
        }.max() ?? 0
    }

    /// Mean absolute difference between two planes of the same size.
    static func meanDifference(_ lhs: Plane, _ rhs: Plane) -> Double {
        let total = zip(lhs.rows, rhs.rows).reduce(0) { sum, pair in
            sum + zip(pair.0, pair.1).reduce(0) { $0 + abs(Int($1.0) - Int($1.1)) }
        }
        return Double(total) / Double(max(lhs.rows.count * (lhs.rows.first?.count ?? 0), 1))
    }

    /// Comb teeth: samples that differ from both vertical neighbours by more than `threshold` in the same direction.
    /// `step` is 1 for luma and 2 for the interleaved chroma plane (it walks one component).
    static func combTeeth(in plane: Plane, threshold: Int = 24, step: Int = 1) -> Int {
        var teeth = 0
        for row in 1..<max(plane.rows.count - 1, 1) {
            for column in Swift.stride(from: 0, to: plane.rows[row].count, by: step) {
                let above = plane[column, row] - plane[column, row - 1]
                let below = plane[column, row] - plane[column, row + 1]
                if (above > threshold && below > threshold) || (above < -threshold && below < -threshold) {
                    teeth += 1
                }
            }
        }
        return teeth
    }
}
