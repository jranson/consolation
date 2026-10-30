//
//  VideoDecoding.swift
//  PlaybackKit
//
//  The role every MPEG-2 decoder plays in VideoFrameStage: compressed pictures in, IOSurface-backed NV12 pixel
//  buffers out (in decode or display order; FrameReorderBuffer restores display order either way), each carrying
//  the PTS, duration and field facts of the picture it came from.
//

import CoreMedia
import Metal

nonisolated protocol VideoDecoding: AnyObject {
    /// Decodes one compressed picture and returns whatever pictures the decoder emitted.
    func decode(_ sample: CMSampleBuffer, info: PictureInfo) throws -> [DecodedFrame]

    /// Returns the pictures the decoder still holds at the end of a stream.
    func drain() throws -> [DecodedFrame]

    /// Forgets all state (pictures, references, session), e.g. after a jump in the stream.
    func invalidate()
}

/// Which MPEG-2 decoder `VideoDecoders.mpeg2` makes. Injected by the caller (the package reads no settings).
nonisolated enum MPEG2DecoderPreference: Sendable {
    /// libavcodec, the playback decoder on every platform.
    case libavcodec
    /// VideoToolbox's software MPEG-2 decoder (macOS only; libavcodec elsewhere), kept to compare against and measure.
    case videoToolbox
}

nonisolated enum VideoDecoders {
    /// Testing and measurement only: replaces the preference for decoders made inside a `withValue` scope (an
    /// engine's pipeline makes its decoder synchronously in `start()`), so the performance harness can measure
    /// VideoToolbox without touching other tests running in parallel.
    @TaskLocal static var preferenceOverride: MPEG2DecoderPreference?

    /// The MPEG-2 decoder. libavcodec everywhere: VideoToolbox has none on iOS, iPadOS and tvOS, and on macOS
    /// libavcodec costs a third less CPU for 1080i and half for 720p. With `device`, libavcodec hands over its pictures
    /// in place for a GPU stage on that device.
    static func mpeg2(_ preference: MPEG2DecoderPreference = .libavcodec,
                      device: MTLDevice? = nil) -> any VideoDecoding {
        #if os(macOS)
        if (preferenceOverride ?? preference) == .videoToolbox { return VTVideoDecoder() }
        #endif
        return LibavVideoDecoder(output: device.map { .planar($0) } ?? .pixelBuffers)
    }
}
