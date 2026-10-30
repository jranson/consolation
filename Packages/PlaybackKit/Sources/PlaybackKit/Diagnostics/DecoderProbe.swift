//
//  DecoderProbe.swift
//  PlaybackKit
//
//  What this device can decode, for the Diagnostics screen: VideoToolbox's MPEG-2, H.264 and HEVC decoders, the
//  system's AC-3, E-AC-3 and AC-4 audio decoders, and the bundled software decoder library. Everything is asked
//  of the local system; nothing touches the network.
//

import AudioToolbox
import CoreMedia
import Foundation
import VideoToolbox

nonisolated public struct DecoderProbeResult: Identifiable, Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        /// Decoded in hardware.
        case hardware
        /// Decoded in software (by the system or by the bundled library).
        case software
        /// Not available on this device.
        case unavailable
    }

    public let id: String
    public let name: String
    public let status: Status
    public let detail: String

    public init(id: String, name: String, status: Status, detail: String = "") {
        self.id = id
        self.name = name
        self.status = status
        self.detail = detail
    }
}

nonisolated public enum DecoderProbe {
    /// 'ac-4': the SDK has no constant for AC-4.
    static let ac4Format: AudioFormatID = 0x6163_2D34
    /// 'aphw' (kAppleHardwareAudioCodecManufacturer, which Swift doesn't import on every platform).
    static let hardwareManufacturer: UInt32 = 0x6170_6877

    /// Runs every probe. Creating decoder sessions takes a few milliseconds, so this runs off the main actor.
    @concurrent
    public static func run() async -> [DecoderProbeResult] {
        var results = [
            video(id: "video.mpeg2", name: "MPEG-2 video (VideoToolbox)", codec: kCMVideoCodecType_MPEG2Video),
            video(id: "video.h264", name: "H.264 video (VideoToolbox)", codec: kCMVideoCodecType_H264),
            video(id: "video.hevc", name: "HEVC video (VideoToolbox)", codec: kCMVideoCodecType_HEVC)
        ]
        results.append(softwareVideo())
        results.append(audio(id: "audio.ac3", name: "AC-3 (Dolby Digital)", format: kAudioFormatAC3))
        results.append(audio(id: "audio.eac3", name: "E-AC-3 (Dolby Digital Plus)", format: kAudioFormatEnhancedAC3))
        results.append(audio(id: "audio.ac4", name: "AC-4 (ATSC 3.0)", format: ac4Format))
        results.append(audio(id: "audio.mp2", name: "MPEG-1 Layer II audio", format: kAudioFormatMPEGLayer2))
        return results
    }

    /// Opens a VideoToolbox session for a 1920 × 1080 stream of `codec`, which fails where there is no decoder.
    static func video(id: String, name: String, codec: CMVideoCodecType) -> DecoderProbeResult {
        var format: CMVideoFormatDescription?
        CMVideoFormatDescriptionCreate(allocator: nil, codecType: codec, width: 1920, height: 1080, extensions: nil,
                                       formatDescriptionOut: &format)
        let hardware = VTIsHardwareDecodeSupported(codec)
        guard let format else {
            return DecoderProbeResult(id: id, name: name, status: .unavailable, detail: "No format description")
        }
        var session: VTDecompressionSession?
        let status = VTDecompressionSessionCreate(allocator: nil, formatDescription: format,
                                                  decoderSpecification: nil, imageBufferAttributes: nil,
                                                  outputCallback: nil, decompressionSessionOut: &session)
        if let session { VTDecompressionSessionInvalidate(session) }
        guard status == noErr else {
            // H.264 and HEVC need parameter sets to open a session; the hardware flag still answers for them.
            if hardware { return DecoderProbeResult(id: id, name: name, status: .hardware) }
            return DecoderProbeResult(id: id, name: name, status: .unavailable, detail: "OSStatus \(status)")
        }
        return DecoderProbeResult(id: id, name: name, status: hardware ? .hardware : .software)
    }

    /// The bundled libavcodec's MPEG-2 decoder (used on iOS and tvOS).
    static func softwareVideo() -> DecoderProbeResult {
        let detail = "\(SoftwareDecoderLibrary.name), libavcodec \(SoftwareDecoderLibrary.codecVersion), "
            + SoftwareDecoderLibrary.license
        return DecoderProbeResult(id: "video.mpeg2.libavcodec", name: "MPEG-2 video (libavcodec)",
                                  status: .software, detail: detail)
    }

    /// Whether the system lists a decoder for `format`, and whether any of them is hardware.
    static func audio(id: String, name: String, format: AudioFormatID) -> DecoderProbeResult {
        var formatID = format
        var size: UInt32 = 0
        let specifierSize = UInt32(MemoryLayout<AudioFormatID>.size)
        let infoStatus = AudioFormatGetPropertyInfo(kAudioFormatProperty_Decoders, specifierSize, &formatID, &size)
        let count = Int(size) / MemoryLayout<AudioClassDescription>.size
        guard infoStatus == noErr, count > 0 else {
            return DecoderProbeResult(id: id, name: name, status: .unavailable)
        }
        var decoders = [AudioClassDescription](repeating: AudioClassDescription(), count: count)
        let status = AudioFormatGetProperty(kAudioFormatProperty_Decoders, specifierSize, &formatID, &size,
                                            &decoders)
        guard status == noErr else { return DecoderProbeResult(id: id, name: name, status: .unavailable) }
        let isHardware = decoders.contains { $0.mManufacturer == hardwareManufacturer }
        return DecoderProbeResult(id: id, name: name, status: isHardware ? .hardware : .software,
                                  detail: count == 1 ? "1 decoder" : "\(count) decoders")
    }
}
