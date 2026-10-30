//
//  LibavVideoDecoder.swift
//  PlaybackKit
//
//  Decodes MPEG-1/MPEG-2 pictures with FFmpeg's libavcodec (LGPL-2.1, embedded as a dynamic framework) on every
//  platform: VideoToolbox has no MPEG-2 decoder on iOS, iPadOS and tvOS, and on macOS libavcodec costs about a third
//  less CPU than VideoToolbox's software decoder. One decoding thread per stream.
//
//  Zero-copy path: the C wrapper's get_buffer2 decodes into page-aligned blocks that are wrapped once as Metal buffers.
//  With `.planar` output (the playback path) pictures leave as `PlanarPicture`s and the GPU stage reads them in place:
//  the deinterlacer directly, progressive pictures through one conversion pass. With `.pixelBuffers` the decoder
//  converts each picture to an IOSurface NV12 ('420v') buffer itself, on the GPU when Metal is available. A picture
//  that didn't come from the pool is copied to NV12 on the CPU. Every output carries the PTS, duration and field facts
//  of its picture. Compressed pictures go in without a copy too: libavcodec references the padded sample buffer.
//

import CoreMedia
import CoreVideo
import Foundation
import LibavMPEG2
import Metal

nonisolated final class LibavVideoDecoder: VideoDecoding {
    enum DecoderError: Error {
        case openFailed
        case decodeFailed(Int32)
    }

    /// Pictures the PTS lookup keeps before giving up on stragglers (damaged pictures never come out).
    private static let pendingLimit = 64
    /// Zeroed bytes a sample's block buffer holds after the picture (`SampleFormats.blockBuffer(copying:padding:)`)
    /// so libavcodec can decode it in place instead of copying it.
    static let inputPadding = Int(LIBAV_MPEG2_INPUT_PADDING)
    /// Registers, once per process, how libavcodec lets go of a block buffer it decoded in place.
    private static let registersOwnerRelease: Void = libav_mpeg2_set_owner_release { owner in
        guard let owner else { return }
        Unmanaged<CMBlockBuffer>.fromOpaque(owner).release()
    }

    /// What `decode` returns.
    enum Output {
        /// NV12 pixel buffers, converted on the GPU when Metal is available.
        case pixelBuffers
        /// NV12 pixel buffers copied on the CPU (tests and measurements).
        case cpuPixelBuffers
        /// `PlanarPicture`s on `device` for a GPU stage that reads them in place.
        case planar(MTLDevice)
    }

    private let threadCount: Int32
    private let wrapper: LibavPlanarWrapper?
    private let converter: MetalPlanarConverter?
    private var decoder: OpaquePointer?
    private var pending: [Int64: PictureInfo] = [:]
    private var lastFormat: CMVideoFormatDescription?
    private var outputPool = NV12BufferPool()

    /// Pictures converted on the GPU, and the GPU time they took (for tests and measurements).
    var gpuConversions: Int { converter?.conversions ?? 0 }
    var gpuSeconds: Double { converter?.gpuSeconds ?? 0 }
    /// Stage timings, when the owning `VideoFrameStage` collects them.
    var clock: VideoStageClock?

    /// `threadCount` 1 per tile; the MPEG-2 decoder only slice-threads, so 2 helps a single full-screen stream at most.
    init(threadCount: Int32 = 1, output: Output = .pixelBuffers) {
        Self.registersOwnerRelease
        self.threadCount = threadCount
        switch output {
        case .pixelBuffers:
            converter = MetalPlanarConverter()
            wrapper = converter.map { LibavPlanarWrapper(device: $0.device) }
        case .cpuPixelBuffers:
            converter = nil
            wrapper = nil
        case .planar(let device):
            converter = nil
            wrapper = LibavPlanarWrapper(device: device)
        }
    }

    deinit {
        libav_mpeg2_close(decoder)
    }

    func decode(_ sample: CMSampleBuffer, info: PictureInfo) throws -> [DecodedFrame] {
        guard let block = CMSampleBufferGetDataBuffer(sample) else { return [] }
        let decoder = try openDecoder()
        lastFormat = CMSampleBufferGetFormatDescription(sample)
        pending[info.pts] = info
        if pending.count > Self.pendingLimit { pending.removeAll() }
        let sent = Self.send(block, size: CMSampleBufferGetTotalSampleSize(sample), pts: info.pts, to: decoder)
        switch sent {
        case .success, .needMore, .badData, .unsupportedFormat:
            break
        case .failed:
            invalidate()
            throw DecoderError.decodeFailed(sent.rawValue)
        }
        return try receiveAll(from: decoder)
    }

    func drain() throws -> [DecodedFrame] {
        guard let decoder else { return [] }
        _ = libav_mpeg2_send_end(decoder)
        let frames = try receiveAll(from: decoder)
        libav_mpeg2_flush(decoder)
        return frames
    }

    func invalidate() {
        libav_mpeg2_close(decoder)
        decoder = nil
        pending.removeAll()
        wrapper?.forget()
    }

    private func openDecoder() throws -> OpaquePointer {
        if let decoder { return decoder }
        guard let opened = libav_mpeg2_open(threadCount) else { throw DecoderError.openFailed }
        decoder = opened
        return opened
    }

    private func receiveAll(from decoder: OpaquePointer) throws -> [DecodedFrame] {
        var frames: [DecodedFrame] = []
        var picture = LibavMPEG2Picture()
        while true {
            let received = libav_mpeg2_receive(decoder, &picture)
            switch received {
            case .success:
                if let frame = makeFrame(decoder: decoder, picture: picture) { frames.append(frame) }
            case .needMore, .badData, .unsupportedFormat:
                return frames
            case .failed:
                invalidate()
                throw DecoderError.decodeFailed(received.rawValue)
            }
        }
    }

    private func makeFrame(decoder: OpaquePointer, picture: LibavMPEG2Picture) -> DecodedFrame? {
        guard picture.pts != Int64.min, let info = pending.removeValue(forKey: picture.pts),
              picture.width > 1, picture.height > 1 else { return nil }
        let width = Int(picture.width)
        let height = Int(picture.height)
        let attachments = PixelBufferAttachments.make(picture: picture, info: info, format: lastFormat)
        let planar = wrapper?.picture(from: decoder, width: width, height: height, attachments: attachments)
        if let planar, converter == nil {
            return DecodedFrame(planar: planar, pts: info.pts, duration: info.duration,
                                isInterlaced: info.isInterlaced, topFieldFirst: info.topFieldFirst)
        }
        guard let buffer = outputPool.make(width: width, height: height) else { return nil }
        // The conversion runs on the GPU while decoding goes on; whoever reads the picture waits for `gpuWork`
        // (normally long done by then, since the reorder buffer holds pictures for a few more decodes).
        let gpuWork = planar.flatMap { planar in
            measureConversion { converter?.convert(planar, into: buffer) }
        }
        if gpuWork == nil {
            guard Self.copyOnCPU(decoder: decoder, into: buffer) else { return nil }
            PixelBufferAttachments.set(attachments, on: buffer)
        }
        return DecodedFrame(pixelBuffer: buffer, pts: info.pts, duration: info.duration,
                            isInterlaced: info.isInterlaced, topFieldFirst: info.topFieldFirst, gpuWork: gpuWork)
    }

    /// Times the conversion as its own stage, taking it back out of the decode time it runs inside.
    private func measureConversion<Result>(_ body: () -> Result) -> Result {
        guard let clock else { return body() }
        let started = VideoStageClock.now()
        let result = clock.measure(\.conversionSubmit, "Convert", body)
        clock.add(-Double(VideoStageClock.now() - started) / 1e9, to: \.decode)
        return result
    }

    /// The fallback: the C wrapper copies the held picture into the buffer's NV12 planes.
    private static func copyOnCPU(decoder: OpaquePointer, into buffer: CVPixelBuffer) -> Bool {
        guard CVPixelBufferLockBaseAddress(buffer, []) == kCVReturnSuccess else { return false }
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        guard let luma = CVPixelBufferGetBaseAddressOfPlane(buffer, 0),
              let chroma = CVPixelBufferGetBaseAddressOfPlane(buffer, 1) else { return false }
        return libav_mpeg2_copy_nv12(decoder, luma.assumingMemoryBound(to: UInt8.self),
                                     CVPixelBufferGetBytesPerRowOfPlane(buffer, 0),
                                     chroma.assumingMemoryBound(to: UInt8.self),
                                     CVPixelBufferGetBytesPerRowOfPlane(buffer, 1)) == .success
    }

    /// Sends the picture's first `size` bytes. In place when the block buffer holds them contiguously followed by
    /// `inputPadding` zeroed bytes (MPEG-2 samples from `ElementaryProcessor`): libavcodec keeps a reference to the
    /// block buffer, released from its buffer's free callback since it can outlive the send. Otherwise copied.
    private static func send(_ block: CMBlockBuffer, size: Int, pts: Int64,
                             to decoder: OpaquePointer) -> LibavMPEG2Result {
        guard size > 0, size <= CMBlockBufferGetDataLength(block) else { return .badData }
        if let bytes = paddedBytes(of: block, size: size) {
            let owner = Unmanaged.passRetained(block).toOpaque()
            return libav_mpeg2_send_owned(decoder, bytes, size, pts, owner)
        }
        var copy = Data(count: size)
        return copy.withUnsafeMutableBytes { raw -> LibavMPEG2Result in
            guard let base = raw.baseAddress,
                  CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: size, destination: base)
                    == kCMBlockBufferNoErr else { return .badData }
            return libav_mpeg2_send(decoder, base.assumingMemoryBound(to: UInt8.self), size, pts)
        }
    }

    /// The block buffer's bytes when the first `size` are contiguous and followed by `inputPadding` zeroed bytes.
    static func paddedBytes(of block: CMBlockBuffer, size: Int) -> UnsafePointer<UInt8>? {
        let padded = size + inputPadding
        guard CMBlockBufferGetDataLength(block) >= padded,
              CMBlockBufferIsRangeContiguous(block, atOffset: 0, length: padded) else { return nil }
        var pointer: UnsafeMutablePointer<CChar>?
        guard CMBlockBufferGetDataPointer(block, atOffset: 0, lengthAtOffsetOut: nil, totalLengthOut: nil,
                                          dataPointerOut: &pointer) == kCMBlockBufferNoErr,
              let raw = pointer.map(UnsafeRawPointer.init) else { return nil }
        let padding = UnsafeRawBufferPointer(start: raw + size, count: inputPadding)
        guard padding.allSatisfy({ $0 == 0 }) else { return nil }
        return raw.assumingMemoryBound(to: UInt8.self)
    }
}

/// Colour, field and aspect attachments for decoded pixel buffers, so they display like VideoToolbox's output.
nonisolated enum PixelBufferAttachments {
    static func make(picture: LibavMPEG2Picture, info: PictureInfo,
                     format: CMVideoFormatDescription?) -> [CFString: Any] {
        let extensions = format.flatMap { CMFormatDescriptionGetExtensions($0) as? [CFString: Any] } ?? [:]
        let standardDefinition = picture.height < 720
        let primaries = CVColorPrimariesGetStringForIntegerCodePoint(picture.colorPrimaries)?.takeUnretainedValue()
            ?? (standardDefinition ? kCVImageBufferColorPrimaries_SMPTE_C : kCVImageBufferColorPrimaries_ITU_R_709_2)
        let transfer = CVTransferFunctionGetStringForIntegerCodePoint(picture.transferCharacteristics)?
            .takeUnretainedValue() ?? kCVImageBufferTransferFunction_ITU_R_709_2
        let matrix = CVYCbCrMatrixGetStringForIntegerCodePoint(picture.matrixCoefficients)?.takeUnretainedValue()
            ?? (standardDefinition ? kCVImageBufferYCbCrMatrix_ITU_R_601_4 : kCVImageBufferYCbCrMatrix_ITU_R_709_2)
        var attachments: [CFString: Any] = [
            kCVImageBufferColorPrimariesKey: primaries,
            kCVImageBufferTransferFunctionKey: transfer,
            kCVImageBufferYCbCrMatrixKey: matrix,
            kCVImageBufferChromaLocationTopFieldKey: kCVImageBufferChromaLocation_Left,
            kCVImageBufferFieldCountKey: info.isInterlaced ? 2 : 1
        ]
        if let aspect = extensions[kCMFormatDescriptionExtension_PixelAspectRatio] {
            attachments[kCVImageBufferPixelAspectRatioKey] = aspect
        }
        if info.isInterlaced {
            attachments[kCVImageBufferFieldDetailKey] = info.topFieldFirst ? kCVImageBufferFieldDetailTemporalTopFirst
                : kCVImageBufferFieldDetailTemporalBottomFirst
        }
        return attachments
    }

    /// `attachments` as a progressive picture's: one field, no field order.
    static func progressive(_ attachments: [CFString: Any]) -> [CFString: Any] {
        var progressive = attachments
        progressive[kCVImageBufferFieldCountKey] = 1
        progressive[kCVImageBufferFieldDetailKey] = nil
        return progressive
    }

    /// Sets `attachments` on `buffer` in one call (each attachment write on an IOSurface-backed buffer is a round
    /// trip to the kernel), removing a field order a pool buffer may still carry from an interlaced picture it held.
    static func set(_ attachments: [CFString: Any], on buffer: CVPixelBuffer) {
        if attachments[kCVImageBufferFieldDetailKey] == nil,
           CVBufferHasAttachment(buffer, kCVImageBufferFieldDetailKey) {
            CVBufferRemoveAttachment(buffer, kCVImageBufferFieldDetailKey)
        }
        CVBufferSetAttachments(buffer, attachments as CFDictionary, .shouldPropagate)
    }
}
