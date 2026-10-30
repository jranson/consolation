//
//  VTVideoDecoder.swift
//  PlaybackKit
//
//  Decodes compressed video sample buffers with VideoToolbox into IOSurface-backed NV12 pixel buffers that Metal
//  can read: H.264 and HEVC in hardware on every platform (the transport stream engine's path for them), and on
//  macOS MPEG-2 in software (for comparison only; iOS and tvOS have no MPEG-2 decoder). Output is in decode order.
//
//  Output is always 8-bit NV12 ('420v'), also for 10-bit HEVC (VideoToolbox converts): the Metal deinterlacer and
//  frame taps read 8-bit planes, and the ATSC 3.0 channels it is for are SDR (BT.709).
//

import CoreMedia
import Foundation
import VideoToolbox

nonisolated final class VTVideoDecoder: VideoDecoding {
    enum DecoderError: Error {
        case unsupported(OSStatus)
        case decodeFailed(OSStatus)
    }

    private var session: VTDecompressionSession?
    private var format: CMVideoFormatDescription?
    private var pending: [Int64: PictureInfo] = [:]
    private let output = DecodeOutput()
    private var consecutiveFailures = 0
    /// Failed pictures in a row (about two seconds) before decoding counts as failed.
    static let failureLimit = 60
    /// Ask for the hardware decoder (H.264, HEVC). Without one (a simulator) VideoToolbox falls back to software.
    private let prefersHardware: Bool

    init(prefersHardware: Bool = false) {
        self.prefersHardware = prefersHardware
    }

    deinit {
        invalidate()
    }

    /// Decodes one picture synchronously and returns whatever the decoder emitted (in decode order).
    func decode(_ sample: CMSampleBuffer, info: PictureInfo) throws -> [DecodedFrame] {
        guard let sampleFormat = CMSampleBufferGetFormatDescription(sample) else { return [] }
        try ensureSession(for: sampleFormat)
        guard let session else { return [] }
        pending[info.pts] = info
        if pending.count > 64 { pending.removeAll() }
        let output = output
        var flags = VTDecodeInfoFlags()
        let status = VTDecompressionSessionDecodeFrame(session, sampleBuffer: sample, flags: [],
                                                       infoFlagsOut: &flags) { status, _, image, pts, _ in
            guard status == noErr, let image else { return }
            output.append(image: image, pts: pts)
        }
        try noteDecodeStatus(status)
        return collect()
    }

    /// Bad data in one picture is skipped (hostile or damaged input). A session the system invalidated (iOS
    /// background) or a decoder malfunction gets a new session at the next picture. Only a run of failures with no
    /// picture decoded in between fails the stream.
    private func noteDecodeStatus(_ status: OSStatus) throws {
        guard status != noErr else {
            consecutiveFailures = 0
            return
        }
        consecutiveFailures += 1
        if status == kVTInvalidSessionErr || status == kVTVideoDecoderMalfunctionErr { invalidate() }
        if consecutiveFailures > Self.failureLimit, status != kVTVideoDecoderBadDataErr {
            throw DecoderError.decodeFailed(status)
        }
    }

    private func collect() -> [DecodedFrame] {
        output.take().compactMap { item in
            guard let info = pending.removeValue(forKey: item.pts) else { return nil }
            return DecodedFrame(pixelBuffer: item.image, pts: info.pts, duration: info.duration,
                                isInterlaced: info.isInterlaced, topFieldFirst: info.topFieldFirst)
        }
    }

    /// Synchronous decoding emits every picture from `decode`; this only collects any stragglers.
    func drain() throws -> [DecodedFrame] {
        if let session { VTDecompressionSessionWaitForAsynchronousFrames(session) }
        return collect()
    }

    func invalidate() {
        if let session { VTDecompressionSessionInvalidate(session) }
        session = nil
        format = nil
        pending.removeAll()
    }

    private func ensureSession(for newFormat: CMVideoFormatDescription) throws {
        if let session, let format {
            if CMFormatDescriptionEqual(format, otherFormatDescription: newFormat) { return }
            if VTDecompressionSessionCanAcceptFormatDescription(session, formatDescription: newFormat) {
                self.format = newFormat
                return
            }
        }
        invalidate()
        let attributes: [CFString: Any] = [
            kCVPixelBufferPixelFormatTypeKey: kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
            kCVPixelBufferIOSurfacePropertiesKey: [String: Any](),
            kCVPixelBufferMetalCompatibilityKey: true
        ]
        var specification: [CFString: Any] = [:]
        #if os(macOS)
        if prefersHardware { specification[kVTVideoDecoderSpecification_EnableHardwareAcceleratedVideoDecoder] = true }
        #endif
        var created: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(
            allocator: nil, formatDescription: newFormat, decoderSpecification: specification as CFDictionary,
            imageBufferAttributes: attributes as CFDictionary, outputCallback: nil,
            decompressionSessionOut: &created)
        guard status == noErr, let created else { throw DecoderError.unsupported(status) }
        session = created
        format = newFormat
    }
}

/// Collects decoder output; the output handler may run on another thread.
nonisolated private final class DecodeOutput: @unchecked Sendable {
    // @unchecked: `items` is only touched under `lock`.
    struct Item {
        let image: CVImageBuffer
        let pts: Int64
    }

    private let lock = NSLock()
    private var items: [Item] = []

    func append(image: CVImageBuffer, pts: CMTime) {
        let ticks = CMTimeConvertScale(pts, timescale: 90_000, method: .roundHalfAwayFromZero).value
        lock.withLock { items.append(Item(image: image, pts: ticks)) }
    }

    func take() -> [Item] {
        lock.withLock {
            defer { items.removeAll() }
            return items
        }
    }
}
