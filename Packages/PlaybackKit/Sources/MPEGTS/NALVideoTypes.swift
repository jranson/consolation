//
//  NALVideoTypes.swift
//  MPEGTS
//
//  What `NALVideoFramer` produces for H.264 (ISO/IEC 14496-10) and HEVC (ISO/IEC 23008-2) video: access units as
//  4-byte length-prefixed samples, with the parameter sets they need and the facts the decode tiers and the
//  deinterlacer use.
//

import Foundation

nonisolated public enum NALVideoCodec: Sendable, Hashable {
    /// stream_type 0x1B.
    case h264
    /// stream_type 0x24.
    case hevc

    /// The name shown in stream info.
    public var displayName: String {
        switch self {
        case .h264: "H.264"
        case .hevc: "HEVC"
        }
    }
}

/// Sequence-level facts from the active SPS.
nonisolated public struct NALVideoFormat: Sendable, Hashable {
    /// Displayed size: the coded size minus the SPS cropping (conformance window).
    public var width: Int
    public var height: Int
    /// From the VUI (H.264); 1:1 when absent or unknown.
    public var sampleAspectRatio: MPEG2Rational
    public var bitDepth: Int
    /// Pictures a decoder may hold before output in display order: max_num_reorder_frames (H.264 VUI, else a
    /// default) or sps_max_num_reorder_pics (HEVC).
    public var reorderDepth: Int
    /// The SPS allows field pictures or MBAFF (H.264 frame_mbs_only_flag 0). Always false for HEVC.
    public var allowsInterlace: Bool
    /// Frames per second from the VUI timing info (H.264), when present.
    public var frameRate: MPEG2Rational?

    public init(width: Int, height: Int, sampleAspectRatio: MPEG2Rational = MPEG2Rational(1, 1), bitDepth: Int = 8,
                reorderDepth: Int = 0, allowsInterlace: Bool = false, frameRate: MPEG2Rational? = nil) {
        self.width = width
        self.height = height
        self.sampleAspectRatio = sampleAspectRatio
        self.bitDepth = bitDepth
        self.reorderDepth = reorderDepth
        self.allowsInterlace = allowsInterlace
        self.frameRate = frameRate
    }
}

/// One coded picture in decode order (for interlaced H.264, a frame or a complementary field pair).
nonisolated public struct NALAccessUnit: Sendable, Equatable {
    public var codec: NALVideoCodec
    /// The picture's NAL units, each preceded by its length as a 4-byte big-endian integer (the `avcC`/`hvcC`
    /// sample layout). Access unit delimiters, parameter sets and filler data are left out: parameter sets travel
    /// in `parameterSets`.
    public var data: Data
    /// The parameter sets the picture uses, without start codes: H.264 SPS then PPSs; HEVC VPS, SPS then PPSs.
    public var parameterSets: [Data]
    /// 90 kHz on the demuxer's unwrapped timeline; from the PES header, or interpolated like `MPEG2AccessUnit`.
    public var pts: Int64
    public var dts: Int64
    /// Display duration in 90 kHz ticks.
    public var duration: Int64
    public var format: NALVideoFormat
    /// A decoder can start here: an IDR or IRAP picture, or (H.264) an intra picture or a recovery point.
    public var isRandomAccess: Bool
    /// Other pictures may reference this one. False only when provably not: H.264 nal_ref_idc 0 on every slice;
    /// HEVC sub-layer non-reference pictures in the highest sub-layer.
    public var isReference: Bool
    /// The picture is two fields (field pair, MBAFF or an interlaced frame): deinterlace it.
    public var isInterlaced: Bool
    public var topFieldFirst: Bool
    /// ATSC A/53 `cc_data` triplets from SEI user_data_registered_itu_t_t35 (`GA94`), in coded order.
    public var captionData: Data?
    /// The picture follows lost data or a discontinuity_indicator.
    public var isDiscontinuity: Bool

    public init(codec: NALVideoCodec, data: Data, parameterSets: [Data], pts: Int64, dts: Int64, duration: Int64,
                format: NALVideoFormat, isRandomAccess: Bool, isReference: Bool = true, isInterlaced: Bool = false,
                topFieldFirst: Bool = true, captionData: Data? = nil, isDiscontinuity: Bool = false) {
        self.codec = codec
        self.data = data
        self.parameterSets = parameterSets
        self.pts = pts
        self.dts = dts
        self.duration = duration
        self.format = format
        self.isRandomAccess = isRandomAccess
        self.isReference = isReference
        self.isInterlaced = isInterlaced
        self.topFieldFirst = topFieldFirst
        self.captionData = captionData
        self.isDiscontinuity = isDiscontinuity
    }
}

/// Receives an access unit from `NALVideoFramer.append(_:of:_:)` or `flush(_:)`: the unit (its `data` empty) and its
/// length-prefixed sample, lent for the call.
public typealias NALUnitHandler = (NALAccessUnit, UnsafeBufferPointer<UInt8>) -> Void

extension NALAccessUnit {
    /// The unit holding a copy of `sample`, for units from `NALVideoFramer.append(_:of:_:)`.
    func copying(_ sample: UnsafeBufferPointer<UInt8>) -> NALAccessUnit {
        var unit = self
        unit.data = Data(buffer: sample)
        return unit
    }
}
