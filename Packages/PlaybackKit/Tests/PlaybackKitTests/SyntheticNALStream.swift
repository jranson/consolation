//
//  SyntheticNALStream.swift
//  PlaybackKitTests
//
//  Small H.264 and HEVC streams made in the test with VTCompressionSession (a moving gradient, so nothing from a
//  broadcast is involved), turned into Annex-B access units with delimiters and in-band parameter sets, and wrapped
//  in a minimal transport stream (PAT, PMT, one PES per picture with PTS and DTS).
//

import CoreMedia
import CoreVideo
import Foundation
@testable import MPEGTS
import VideoToolbox

#if os(macOS)
nonisolated enum SyntheticNALStream {
    struct Picture {
        var annexB: [UInt8]
        var pts: Int64
        var dts: Int64
        var isKeyframe: Bool
        /// The encoder's kCMSampleAttachmentKey_IsDependedOnByOthers (false for non-reference pictures).
        var isDependedOn: Bool
    }

    static let width = 320
    static let height = 240
    static let frameTicks: Int64 = 3_003
    static let firstPTS: Int64 = 900_000

    /// Encodes `frames` pictures, a keyframe every `keyframeInterval`, with B pictures. Nil when this machine has no
    /// encoder for `codec` (HEVC on some configurations).
    static func encode(_ codec: CMVideoCodecType, frames: Int = 48, keyframeInterval: Int = 12) -> [Picture]? {
        var created: VTCompressionSession?
        let status = VTCompressionSessionCreate(
            allocator: nil, width: Int32(width), height: Int32(height), codecType: codec, encoderSpecification: nil,
            imageBufferAttributes: nil, compressedDataAllocator: nil, outputCallback: nil, refcon: nil,
            compressionSessionOut: &created)
        guard status == noErr, let session = created else { return nil }
        defer { VTCompressionSessionInvalidate(session) }
        let profile = codec == kCMVideoCodecType_H264 ? kVTProfileLevel_H264_High_AutoLevel
            : kVTProfileLevel_HEVC_Main_AutoLevel
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_ProfileLevel, value: profile)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_RealTime, value: kCFBooleanFalse)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AllowFrameReordering, value: kCFBooleanTrue)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_MaxKeyFrameInterval,
                             value: keyframeInterval as CFNumber)
        VTSessionSetProperty(session, key: kVTCompressionPropertyKey_AverageBitRate, value: 1_000_000 as CFNumber)
        let collector = EncodedSamples()
        for index in 0..<frames {
            guard let image = gradient(index) else { return nil }
            let pts = CMTime(value: Int64(index) * frameTicks, timescale: 90_000)
            let encoded = VTCompressionSessionEncodeFrame(
                session, imageBuffer: image, presentationTimeStamp: pts,
                duration: CMTime(value: frameTicks, timescale: 90_000), frameProperties: nil, infoFlagsOut: nil
            ) { status, _, sample in
                if status == noErr, let sample { collector.add(sample) }
            }
            guard encoded == noErr else { return nil }
        }
        VTCompressionSessionCompleteFrames(session, untilPresentationTimeStamp: .invalid)
        let pictures = collector.samples.compactMap { picture(from: $0, hevc: codec == kCMVideoCodecType_HEVC) }
        return pictures.count == frames ? pictures : nil
    }

    /// A 420v picture whose gradient moves with `index`.
    private static func gradient(_ index: Int) -> CVPixelBuffer? {
        var buffer: CVPixelBuffer?
        CVPixelBufferCreate(nil, width, height, kCVPixelFormatType_420YpCbCr8BiPlanarVideoRange,
                            [kCVPixelBufferIOSurfacePropertiesKey: [String: Any]()] as CFDictionary, &buffer)
        guard let buffer else { return nil }
        CVPixelBufferLockBaseAddress(buffer, [])
        defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
        for plane in 0..<2 {
            guard let base = CVPixelBufferGetBaseAddressOfPlane(buffer, plane) else { return nil }
            let rows = CVPixelBufferGetHeightOfPlane(buffer, plane)
            let stride = CVPixelBufferGetBytesPerRowOfPlane(buffer, plane)
            for row in 0..<rows {
                let line = base.advanced(by: row * stride).assumingMemoryBound(to: UInt8.self)
                for column in 0..<stride {
                    line[column] = UInt8(truncatingIfNeeded: plane == 0 ? (column + row + index * 4) : 128 + row)
                }
            }
        }
        return buffer
    }

    private static func picture(from sample: CMSampleBuffer, hevc: Bool) -> Picture? {
        guard let format = CMSampleBufferGetFormatDescription(sample),
              let block = CMSampleBufferGetDataBuffer(sample) else { return nil }
        let length = CMBlockBufferGetDataLength(block)
        var avcc = [UInt8](repeating: 0, count: length)
        guard CMBlockBufferCopyDataBytes(block, atOffset: 0, dataLength: length, destination: &avcc) == noErr
        else { return nil }
        let attachments = CMSampleBufferGetSampleAttachmentsArray(sample, createIfNecessary: false)
            as? [[CFString: Any]]
        let isKeyframe = (attachments?.first?[kCMSampleAttachmentKey_NotSync] as? Bool) != true
        let dependedOn = (attachments?.first?[kCMSampleAttachmentKey_IsDependedOnByOthers] as? Bool) ?? true
        let start: [UInt8] = [0, 0, 0, 1]
        var annexB = start + (hevc ? [0x46, 0x01, 0x50] : [0x09, 0xF0])
        if isKeyframe {
            for set in parameterSets(format, hevc: hevc) { annexB += start + set }
        }
        var offset = 0
        while offset + 4 <= avcc.count {
            let size = avcc[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard size > 0, offset + size <= avcc.count else { return nil }
            annexB += start + avcc[offset..<(offset + size)]
            offset += size
        }
        let pts = CMSampleBufferGetPresentationTimeStamp(sample)
        let dts = CMSampleBufferGetDecodeTimeStamp(sample)
        let ticks = { (time: CMTime) in CMTimeConvertScale(time, timescale: 90_000, method: .default).value }
        return Picture(annexB: annexB, pts: firstPTS + ticks(pts), dts: firstPTS + ticks(dts.isValid ? dts : pts),
                       isKeyframe: isKeyframe, isDependedOn: dependedOn)
    }

    static func parameterSets(_ format: CMFormatDescription, hevc: Bool) -> [[UInt8]] {
        var count = 0
        _ = hevc
            ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
            : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                format, parameterSetIndex: 0, parameterSetPointerOut: nil, parameterSetSizeOut: nil,
                parameterSetCountOut: &count, nalUnitHeaderLengthOut: nil)
        return (0..<count).compactMap { index in
            var pointer: UnsafePointer<UInt8>?
            var size = 0
            let status = hevc
                ? CMVideoFormatDescriptionGetHEVCParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
                : CMVideoFormatDescriptionGetH264ParameterSetAtIndex(
                    format, parameterSetIndex: index, parameterSetPointerOut: &pointer, parameterSetSizeOut: &size,
                    parameterSetCountOut: nil, nalUnitHeaderLengthOut: nil)
            guard status == noErr, let pointer else { return nil }
            return Array(UnsafeBufferPointer(start: pointer, count: size))
        }
    }

    // MARK: - Transport stream

    static let videoPID: UInt16 = 0x31
    static let audioPID: UInt16 = 0x34

    /// The DVB AC-4 descriptor (extension descriptor 0x7F, tag extension 0x15) and an English language descriptor.
    static let ac4Descriptors: [UInt8] = [0x7F, 0x02, 0x15, 0x00, 0x0A, 0x04] + Array("eng".utf8) + [0x00]

    /// One program: the video (stream_type 0x1B or 0x24) and, optionally, an AC-4 audio stream that has no data.
    static func transportStream(_ pictures: [Picture], streamType: UInt8, withAC4: Bool = false) -> Data {
        var writer = MiniTSWriter()
        for (index, picture) in pictures.enumerated() {
            if index % 10 == 0 {
                writer.section(pid: 0, pat())
                writer.section(pid: 0x30, pmt(streamType: streamType, withAC4: withAC4))
            }
            let header: [UInt8] = [0x80, 0xC0, 10] + timestamp(prefix: 3, picture.pts)
                + timestamp(prefix: 1, picture.dts)
            writer.packetize(pid: videoPID, payload: [0, 0, 1, 0xE0, 0, 0] + header + picture.annexB)
        }
        return Data(writer.bytes)
    }

    private static func pat() -> [UInt8] {
        section(tableID: 0, idExtension: 1, body: [0, 1, 0xE0, 0x30])
    }

    private static func pmt(streamType: UInt8, withAC4: Bool) -> [UInt8] {
        var body: [UInt8] = [0xE0, UInt8(videoPID), 0xF0, 0]
        body += [streamType, 0xE0, UInt8(videoPID), 0xF0, 0]
        if withAC4 {
            body += [0x06, 0xE0, UInt8(audioPID), 0xF0, UInt8(ac4Descriptors.count)] + ac4Descriptors
        }
        return section(tableID: 2, idExtension: 1, body: body)
    }

    private static func section(tableID: UInt8, idExtension: UInt16, body: [UInt8]) -> [UInt8] {
        let length = 5 + body.count + 4
        var bytes: [UInt8] = [tableID, 0xB0 | UInt8(length >> 8), UInt8(length & 0xFF), UInt8(idExtension >> 8),
                              UInt8(idExtension & 0xFF), 0xC1, 0, 0] + body
        let crc = CRC32MPEG2.checksum(bytes)
        bytes += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return bytes
    }

    private static func timestamp(prefix: UInt8, _ value: Int64) -> [UInt8] {
        [(prefix << 4) | UInt8((value >> 29) & 0x0E) | 1, UInt8((value >> 22) & 0xFF),
         UInt8((value >> 14) & 0xFE) | 1, UInt8((value >> 7) & 0xFF), UInt8((value << 1) & 0xFE) | 1]
    }
}

/// Collects encoder output (the handler runs on the encoder's thread).
nonisolated private final class EncodedSamples: @unchecked Sendable {
    // @unchecked: `items` is only touched under `lock`.
    private let lock = NSLock()
    private var items: [CMSampleBuffer] = []

    func add(_ sample: CMSampleBuffer) { lock.withLock { items.append(sample) } }
    var samples: [CMSampleBuffer] { lock.withLock { items } }
}

/// Packetizes PSI sections and PES packets into 188-byte packets with continuity counters and stuffing.
nonisolated struct MiniTSWriter {
    private(set) var bytes: [UInt8] = []
    private var counters: [UInt16: UInt8] = [:]

    mutating func section(pid: UInt16, _ section: [UInt8]) {
        let payload = [0] + section
        packet(pid: pid, start: true, payload: payload + [UInt8](repeating: 0xFF, count: 184 - payload.count))
    }

    mutating func packetize(pid: UInt16, payload: [UInt8]) {
        var offset = 0
        while offset < payload.count {
            let chunk = Array(payload[offset..<min(offset + 184, payload.count)])
            packet(pid: pid, start: offset == 0, payload: chunk)
            offset += chunk.count
        }
    }

    private mutating func packet(pid: UInt16, start: Bool, payload: [UInt8]) {
        let counter = ((counters[pid] ?? 0x0F) &+ 1) & 0x0F
        counters[pid] = counter
        var adaptation: [UInt8] = []
        if payload.count < 184 {
            let stuffing = 184 - payload.count - 1
            let fill = stuffing > 0 ? [0x00] + [UInt8](repeating: 0xFF, count: stuffing - 1) : []
            adaptation = [UInt8(stuffing)] + fill
        }
        let control: UInt8 = adaptation.isEmpty ? 0x10 : 0x30
        bytes += [0x47, (start ? 0x40 : 0) | UInt8(pid >> 8), UInt8(pid & 0xFF), control | counter]
        bytes += adaptation + payload
    }
}
#endif
