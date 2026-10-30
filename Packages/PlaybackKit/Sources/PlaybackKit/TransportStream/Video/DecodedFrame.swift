//
//  DecodedFrame.swift
//  PlaybackKit
//

import CoreVideo
import Metal
import MPEGTS

/// One decoded picture in display order, with the facts the deinterlacer needs.
nonisolated struct DecodedFrame: @unchecked Sendable {
    // @unchecked: the image is immutable once decoded and only read after this point.

    /// Where the picture's pixels are.
    enum Image {
        /// An IOSurface NV12 buffer (VideoToolbox, the CPU copy, the converter, the deinterlacer's output).
        case pixelBuffer(CVPixelBuffer)
        /// libavcodec's planar memory, read in place by the GPU stage, which turns it into a pixel buffer.
        case planar(PlanarPicture)
    }

    let image: Image
    /// Presentation time, 90 kHz.
    let pts: Int64
    /// How long the picture is shown, 90 kHz.
    let duration: Int64
    /// True for an interlaced picture (two fields); false for a progressive one.
    let isInterlaced: Bool
    let topFieldFirst: Bool
    /// The committed GPU pass still writing the pixel buffer, if any. Wait for it (`VideoStageClock.wait`) before
    /// the picture is read by the CPU, another command queue or the display.
    var gpuWork: (any MTLCommandBuffer)?

    init(pixelBuffer: CVPixelBuffer, pts: Int64, duration: Int64, isInterlaced: Bool, topFieldFirst: Bool,
         gpuWork: (any MTLCommandBuffer)? = nil) {
        image = .pixelBuffer(pixelBuffer)
        self.pts = pts
        self.duration = duration
        self.isInterlaced = isInterlaced
        self.topFieldFirst = topFieldFirst
        self.gpuWork = gpuWork
    }

    init(planar: PlanarPicture, pts: Int64, duration: Int64, isInterlaced: Bool, topFieldFirst: Bool) {
        image = .planar(planar)
        self.pts = pts
        self.duration = duration
        self.isInterlaced = isInterlaced
        self.topFieldFirst = topFieldFirst
    }

    /// The NV12 buffer, once the picture has one.
    var pixelBuffer: CVPixelBuffer? {
        if case .pixelBuffer(let buffer) = image { buffer } else { nil }
    }

    var planar: PlanarPicture? {
        if case .planar(let picture) = image { picture } else { nil }
    }

    /// The picture's size in pixels.
    var size: (width: Int, height: Int) {
        switch image {
        case .pixelBuffer(let buffer): (CVPixelBufferGetWidth(buffer), CVPixelBufferGetHeight(buffer))
        case .planar(let picture): (picture.layout.width, picture.layout.height)
        }
    }

    /// The object holding the pixels, to keep alive while a GPU pass reads them.
    var storage: AnyObject {
        switch image {
        case .pixelBuffer(let buffer): buffer
        case .planar(let picture): picture
        }
    }
}

/// Coded-picture facts carried from the framer to the decoder output, keyed by presentation time.
nonisolated struct PictureInfo: Sendable {
    let pts: Int64
    let duration: Int64
    let isInterlaced: Bool
    let topFieldFirst: Bool
    /// Keyframe, reference or non-reference, for the decode tiers (`DecodeTierGate`).
    let role: PictureRole
}

/// Puts decoded pictures back into presentation order (MPEG-2 decoders and VideoToolbox emit them in decode order).
nonisolated struct FrameReorderBuffer {
    /// Pictures held before the earliest is released; covers MPEG-2's usual two B-pictures between references.
    /// H.264 and HEVC use their SPS's reorder depth instead.
    static let fullDepth = 3

    /// The current depth. Without B pictures (the reduced decode tiers) decode order is display order, so nothing
    /// needs holding: 0. Lowering it releases the excess at the next push, in order.
    var depth = FrameReorderBuffer.fullDepth
    private var frames: [DecodedFrame] = []
    private var lastReleased: Int64?

    /// Adds a decoded picture and returns any pictures now safe to show, in order.
    mutating func push(_ frame: DecodedFrame) -> [DecodedFrame] {
        if let lastReleased, frame.pts <= lastReleased { return [] }
        let index = frames.firstIndex { $0.pts > frame.pts } ?? frames.endIndex
        frames.insert(frame, at: index)
        var released: [DecodedFrame] = []
        while frames.count > depth {
            let next = frames.removeFirst()
            lastReleased = next.pts
            released.append(next)
        }
        return released
    }

    /// Releases everything held (end of stream).
    mutating func drain() -> [DecodedFrame] {
        defer { frames.removeAll() }
        if let last = frames.last { lastReleased = last.pts }
        return frames
    }

    mutating func reset() {
        frames.removeAll()
        lastReleased = nil
    }
}
