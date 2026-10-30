//
//  FrameTapping.swift
//  PlaybackKit
//
//  One API for reading what an engine shows: one-field luma copies of chosen regions at a low rate (Logo Watch, the
//  freeze editor's auto-suggest), and the frame on screen now (freeze frame, thumbnails). A tap costs nothing while no
//  request is active.
//

import CoreGraphics
import CoreMedia
import CoreVideo
import Foundation

/// What to copy, and how often.
nonisolated public struct FrameTapRequest: Equatable, Sendable {
    /// Regions normalized to the video frame (0...1, origin top-left).
    public var regions: [CGRect]
    public var samplesPerSecond: Double
    /// Pixels added on each side of every region, for an edge kernel.
    public var margin: Int

    public init(regions: [CGRect], samplesPerSecond: Double = 2, margin: Int = 4) {
        self.regions = regions
        self.samplesPerSecond = samplesPerSecond
        self.margin = margin
    }
}

/// The luma of one region, one field: every other row starting with the frame's first row.
nonisolated public struct LumaPatch: Equatable, Sendable {
    /// The region in frame pixels after margins and clamping (full-frame rows).
    public let rect: CGRect
    public let width: Int
    /// Field rows: about half of `rect.height`.
    public let height: Int
    /// 8-bit luma, `width` bytes per row, no padding.
    public let bytes: Data

    public init(rect: CGRect, width: Int, height: Int, bytes: Data) {
        self.rect = rect
        self.width = width
        self.height = height
        self.bytes = bytes
    }
}

nonisolated public struct FrameTapSample: Sendable {
    public let presentationTime: CMTime
    /// The decoded frame's size in pixels.
    public let frameSize: CGSize
    /// One per requested region, in order.
    public let patches: [LumaPatch]

    public init(presentationTime: CMTime, frameSize: CGSize, patches: [LumaPatch]) {
        self.presentationTime = presentationTime
        self.frameSize = frameSize
        self.patches = patches
    }
}

/// Engines whose pictures can be read back.
public protocol FrameTapping: AnyObject {
    /// One-field luma copies of each region at the requested rate. Cancelling the consuming task, or the engine
    /// stopping, ends the stream.
    func frameTap(_ request: FrameTapRequest) -> AsyncStream<FrameTapSample>
    /// The frame on screen now, if any.
    func latestFrame() async -> CVPixelBuffer?
}
