//
//  PlanarPicture.swift
//  PlaybackKit
//
//  A decoded picture still in libavcodec's own memory: planar Y'CbCr (I420, or 4:2:2 read as 4:2:0 by every other
//  chroma row) in one page-aligned block, wrapped as a Metal buffer without a copy. The GPU stage reads it in place:
//  the deinterlacer through linear textures over the planes, the converter through the buffer. Holding one keeps
//  libavcodec from reusing its block.
//

import CoreVideo
import Foundation
import LibavMPEG2
import Metal

nonisolated final class PlanarPicture: @unchecked Sendable {
    // @unchecked: immutable apart from the texture cache, which only the owning stage's thread touches.

    /// Where the planes are in `buffer`, in bytes.
    struct Layout: Sendable {
        let width: Int
        let height: Int
        let lumaOffset: Int
        let blueOffset: Int
        let redOffset: Int
        let lumaStride: Int
        /// Shared by the Cb and Cr planes.
        let chromaStride: Int
        /// 1 for 4:2:0; 2 for 4:2:2, whose every other chroma row makes 4:2:0.
        let chromaRowStep: Int

        var chromaWidth: Int { (width + 1) / 2 }
        var chromaHeight: Int { (height + 1) / 2 }
    }

    /// R8 textures over the three planes; Cb and Cr at 4:2:0 size.
    struct Planes {
        let luma: MTLTexture
        let blue: MTLTexture
        let red: MTLTexture
    }

    let buffer: MTLBuffer
    let layout: Layout
    /// Colour, field and aspect attachments for the pixel buffers made from this picture.
    let attachments: [CFString: Any]
    /// Keeps the decoder's picture (and so its block) until the last holder lets go.
    private let owner: AnyObject?
    private var planes: Planes??

    init(buffer: MTLBuffer, layout: Layout, attachments: [CFString: Any], owner: AnyObject?) {
        self.buffer = buffer
        self.layout = layout
        self.attachments = attachments
        self.owner = owner
    }

    /// Linear textures over the planes, made on first use. Nil when the device can't place linear textures at
    /// these offsets and strides (its alignment is larger than the decoder's), and in the iOS and tvOS simulators,
    /// whose Metal aborts on linear textures over shared buffers; the caller converts instead.
    func textures() -> Planes? {
        #if targetEnvironment(simulator)
        return nil
        #else
        if let planes { return planes }
        let made = makeTextures()
        planes = .some(made)
        return made
        #endif
    }

    private func makeTextures() -> Planes? {
        let alignment = buffer.device.minimumLinearTextureAlignment(for: .r8Unorm)
        let chromaRowBytes = layout.chromaStride * layout.chromaRowStep
        let aligned = [layout.lumaOffset, layout.blueOffset, layout.redOffset, layout.lumaStride, chromaRowBytes]
            .allSatisfy { $0 % alignment == 0 }
        guard aligned,
              let luma = texture(width: layout.width, height: layout.height, offset: layout.lumaOffset,
                                 rowBytes: layout.lumaStride),
              let blue = texture(width: layout.chromaWidth, height: layout.chromaHeight, offset: layout.blueOffset,
                                 rowBytes: chromaRowBytes),
              let red = texture(width: layout.chromaWidth, height: layout.chromaHeight, offset: layout.redOffset,
                                rowBytes: chromaRowBytes) else { return nil }
        return Planes(luma: luma, blue: blue, red: red)
    }

    private func texture(width: Int, height: Int, offset: Int, rowBytes: Int) -> MTLTexture? {
        let descriptor = MTLTextureDescriptor.texture2DDescriptor(pixelFormat: .r8Unorm, width: width, height: height,
                                                                  mipmapped: false)
        descriptor.usage = .shaderRead
        descriptor.storageMode = buffer.storageMode
        descriptor.cpuCacheMode = buffer.cpuCacheMode
        return buffer.makeTexture(descriptor: descriptor, offset: offset, bytesPerRow: rowBytes)
    }
}

/// Wraps the pictures a LibavMPEG2 decoder holds as `PlanarPicture`s, making one Metal buffer per pool block and
/// reusing it for every picture decoded into that block.
nonisolated final class LibavPlanarWrapper {
    /// Keeps a block's memory alive while a Metal buffer wraps it; the wrapper's deallocator holds the only
    /// reference, so the block is released exactly once whether or not the wrapper was ever created.
    private final class BlockHold: Sendable {
        let handle: UInt

        init(_ block: UnsafeRawPointer) {
            handle = UInt(bitPattern: block)
            libav_mpeg2_block_retain(block)
        }

        deinit {
            if let block = UnsafeRawPointer(bitPattern: handle) { libav_mpeg2_block_release(block) }
        }
    }

    /// A libavcodec picture reference, released once (on whichever thread drops the last hold).
    private final class HeldPicture: Sendable {
        let handle: UInt

        init(_ picture: UnsafeRawPointer) {
            handle = UInt(bitPattern: picture)
        }

        deinit {
            if let picture = UnsafeRawPointer(bitPattern: handle) { libav_mpeg2_picture_release(picture) }
        }
    }

    /// Wrapped blocks kept; the decoder's pool holds at most 24, so this only trims after size changes.
    private static let wrapperLimit = 32

    let device: MTLDevice
    private var wrappers: [UInt64: MTLBuffer] = [:]

    init(device: MTLDevice) {
        self.device = device
    }

    /// The picture `decoder` holds, kept alive past the next receive. Nil when it isn't in the pool (or isn't a
    /// layout the GPU path reads); the caller then copies it on the CPU.
    func picture(from decoder: OpaquePointer, width: Int, height: Int,
                 attachments: [CFString: Any]) -> PlanarPicture? {
        var planes = LibavMPEG2Planes()
        guard libav_mpeg2_planes(decoder, &planes) == .success, let buffer = wrapper(for: planes),
              let held = libav_mpeg2_picture_retain(decoder) else { return nil }
        let layout = PlanarPicture.Layout(
            width: width, height: height, lumaOffset: planes.lumaOffset,
            blueOffset: planes.blueOffset, redOffset: planes.redOffset, lumaStride: Int(planes.lumaStride),
            chromaStride: Int(planes.chromaStride), chromaRowStep: Int(max(planes.chromaRowStep, 1)))
        return PlanarPicture(buffer: buffer, layout: layout, attachments: attachments, owner: HeldPicture(held))
    }

    /// Drops the wrapped blocks, e.g. when the decoder closes.
    func forget() {
        wrappers.removeAll()
    }

    private func wrapper(for planes: LibavMPEG2Planes) -> MTLBuffer? {
        if let cached = wrappers[planes.serial] { return cached }
        guard let block = planes.block, let base = planes.base, planes.length > 0 else { return nil }
        if wrappers.count >= Self.wrapperLimit { wrappers.removeAll() }
        let hold = BlockHold(block)
        // Default CPU cache mode: libavcodec reads its reference pictures back from these blocks.
        let buffer = device.makeBuffer(bytesNoCopy: UnsafeMutableRawPointer(mutating: base), length: planes.length,
                                       options: .storageModeShared) { _, _ in
            withExtendedLifetime(hold) {}
        }
        if let buffer { wrappers[planes.serial] = buffer }
        return buffer
    }
}
