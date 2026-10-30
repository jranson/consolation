//
//  H264Headers.swift
//  MPEGTS
//
//  The parts of H.264 (ISO/IEC 14496-10 / ITU-T H.264) headers the framer needs: the sequence parameter set with its
//  VUI (size, cropping, frame_mbs_only, aspect, timing, HRD delay lengths, pic_struct, reorder depth), the picture
//  parameter set's ids, the slice header up to bottom_field_flag, and the picture timing SEI's pic_struct.
//  Everything is read from the RBSP through `BitReader`; a header that overruns is rejected.
//

nonisolated struct H264SPS: Equatable, Sendable {
    var id: Int
    var profileIdc: Int
    var chromaFormatIdc = 1
    var separateColourPlane = false
    var bitDepthLuma = 8
    var log2MaxFrameNum = 4
    var frameMBsOnly = true
    var width = 0
    var height = 0
    var sampleAspectRatio = MPEG2Rational(1, 1)
    /// num_units_in_tick and time_scale from the VUI.
    var timing: (unitsInTick: Int, timeScale: Int)?
    /// CpbDpbDelaysPresentFlag: picture timing SEI carries cpb_removal_delay and dpb_output_delay.
    var hrdDelays: (cpbRemovalDelayBits: Int, dpbOutputDelayBits: Int)?
    var picStructPresent = false
    var maxNumReorderFrames: Int?

    static func == (lhs: H264SPS, rhs: H264SPS) -> Bool {
        lhs.id == rhs.id && lhs.width == rhs.width && lhs.height == rhs.height
            && lhs.frameMBsOnly == rhs.frameMBsOnly && lhs.log2MaxFrameNum == rhs.log2MaxFrameNum
    }

    /// Without VUI bitstream_restriction a stream may reorder up to its DPB size; broadcast encoders use at most a
    /// B-pyramid, so this covers them without holding 16 pictures.
    static let defaultReorderDepth = 4
    static let maximumReorderDepth = 16

    /// Frames per second: time_scale / (2 × num_units_in_tick) (H.264 counts ticks per field).
    var frameRate: MPEG2Rational? {
        guard let timing, timing.unitsInTick > 0, timing.timeScale > 0 else { return nil }
        let rate = MPEG2Rational(timing.timeScale, 2 * timing.unitsInTick).reduced
        return (1.0...300.0).contains(rate.doubleValue) ? rate : nil
    }

    var format: NALVideoFormat {
        NALVideoFormat(width: width, height: height, sampleAspectRatio: sampleAspectRatio, bitDepth: bitDepthLuma,
                       reorderDepth: min(maxNumReorderFrames ?? Self.defaultReorderDepth, Self.maximumReorderDepth),
                       allowsInterlace: !frameMBsOnly, frameRate: frameRate)
    }
}

nonisolated struct H264Slice: Equatable, Sendable {
    var firstMB: Int
    var sliceType: Int
    var ppsID: Int
    var frameNum: Int
    var fieldPic = false
    var bottomField = false

    /// slice_type 2/7 (I) or 4/9 (SI).
    var isIntra: Bool { sliceType % 5 == 2 || sliceType % 5 == 4 }
}

nonisolated enum H264Headers {
    static let highProfiles: Set<Int> = [100, 110, 122, 244, 44, 83, 86, 118, 128, 138, 139, 134, 135]

    /// Table E-1, aspect_ratio_idc 1…16.
    static let sampleAspectRatios: [(Int, Int)] = [
        (1, 1), (12, 11), (10, 11), (16, 11), (40, 33), (24, 11), (20, 11), (32, 11), (80, 33), (18, 11),
        (15, 11), (64, 33), (160, 99), (4, 3), (3, 2), (2, 1)
    ]

    /// seq_parameter_set_rbsp() (§7.3.2.1.1) from the RBSP after the NAL header byte.
    static func sps(_ rbsp: UnsafeBufferPointer<UInt8>) -> H264SPS? {
        var reader = BitReader(rbsp)
        let profile = reader.int(8)
        reader.skip(16)  // constraint flags, level_idc
        let id = reader.golomb()
        guard id < 32 else { return nil }
        var sps = H264SPS(id: id, profileIdc: profile)
        if highProfiles.contains(profile) {
            sps.chromaFormatIdc = reader.golomb()
            if sps.chromaFormatIdc == 3 { sps.separateColourPlane = reader.flag() }
            sps.bitDepthLuma = reader.golomb() + 8
            _ = reader.golomb()  // bit_depth_chroma_minus8
            reader.skip(1)  // qpprime_y_zero_transform_bypass_flag
            if reader.flag() { skipScalingMatrix(&reader, lists: sps.chromaFormatIdc == 3 ? 12 : 8) }
        }
        guard sps.chromaFormatIdc <= 3, (8...14).contains(sps.bitDepthLuma) else { return nil }
        sps.log2MaxFrameNum = reader.golomb() + 4
        guard sps.log2MaxFrameNum <= 16, skipPictureOrderCount(&reader) else { return nil }
        _ = reader.golomb()  // max_num_ref_frames
        reader.skip(1)  // gaps_in_frame_num_value_allowed_flag
        let widthMBs = reader.golomb() + 1
        let heightMapUnits = reader.golomb() + 1
        sps.frameMBsOnly = reader.flag()
        if !sps.frameMBsOnly { reader.skip(1) }  // mb_adaptive_frame_field_flag
        reader.skip(1)  // direct_8x8_inference_flag
        guard widthMBs <= 1024, heightMapUnits <= 1024 else { return nil }
        let frameHeightMBs = (sps.frameMBsOnly ? 1 : 2) * heightMapUnits
        var crop = (left: 0, right: 0, top: 0, bottom: 0)
        if reader.flag() {
            crop = (reader.golomb(), reader.golomb(), reader.golomb(), reader.golomb())
        }
        let (unitX, unitY) = cropUnits(sps)
        sps.width = widthMBs * 16 - unitX * (crop.left + crop.right)
        sps.height = frameHeightMBs * 16 - unitY * (crop.top + crop.bottom)
        if reader.flag() { parseVUI(&reader, into: &sps) }
        guard !reader.isOverrun, sps.width > 0, sps.height > 0 else { return nil }
        return sps
    }

    /// CropUnitX and CropUnitY (§7.4.2.1.1).
    private static func cropUnits(_ sps: H264SPS) -> (Int, Int) {
        let fieldFactor = sps.frameMBsOnly ? 1 : 2
        guard sps.chromaFormatIdc != 0, !sps.separateColourPlane else { return (1, fieldFactor) }
        let subWidth = sps.chromaFormatIdc == 3 ? 1 : 2
        let subHeight = sps.chromaFormatIdc == 1 ? 2 : 1
        return (subWidth, subHeight * fieldFactor)
    }

    private static func skipScalingMatrix(_ reader: inout BitReader, lists: Int) {
        for index in 0..<lists where reader.flag() {
            var last = 8
            var next = 8
            for _ in 0..<(index < 6 ? 16 : 64) where !reader.isOverrun {
                if next != 0 { next = (last + reader.signedGolomb() + 256) % 256 }
                last = next == 0 ? last : next
            }
        }
    }

    /// pic_order_cnt_type and its fields; false when a count is impossible.
    private static func skipPictureOrderCount(_ reader: inout BitReader) -> Bool {
        switch reader.golomb() {
        case 0:
            _ = reader.golomb()  // log2_max_pic_order_cnt_lsb_minus4
        case 1:
            reader.skip(1)  // delta_pic_order_always_zero_flag
            _ = reader.signedGolomb()
            _ = reader.signedGolomb()
            let cycle = reader.golomb()
            guard cycle <= 255 else { return false }
            for _ in 0..<cycle where !reader.isOverrun { _ = reader.signedGolomb() }
        case 2:
            break
        default:
            return false
        }
        return true
    }

    /// vui_parameters() (Annex E.1.1).
    private static func parseVUI(_ reader: inout BitReader, into sps: inout H264SPS) {
        if reader.flag() {
            let idc = reader.int(8)
            if idc == 255 {
                let width = reader.int(16)
                let height = reader.int(16)
                if width > 0, height > 0 { sps.sampleAspectRatio = MPEG2Rational(width, height).reduced }
            } else if (1...16).contains(idc) {
                let ratio = sampleAspectRatios[idc - 1]
                sps.sampleAspectRatio = MPEG2Rational(ratio.0, ratio.1)
            }
        }
        if reader.flag() { reader.skip(1) }  // overscan_appropriate_flag
        if reader.flag() {  // video_signal_type_present_flag
            reader.skip(4)  // video_format, video_full_range_flag
            if reader.flag() { reader.skip(24) }  // colour description
        }
        if reader.flag() {  // chroma_loc_info_present_flag
            _ = reader.golomb()
            _ = reader.golomb()
        }
        if reader.flag() {
            let unitsInTick = reader.int(32)
            let timeScale = reader.int(32)
            reader.skip(1)  // fixed_frame_rate_flag
            sps.timing = (unitsInTick, timeScale)
        }
        let nal = reader.flag() ? parseHRD(&reader) : nil
        let vcl = reader.flag() ? parseHRD(&reader) : nil
        if let delays = nal ?? vcl {
            sps.hrdDelays = delays
            reader.skip(1)  // low_delay_hrd_flag
        }
        sps.picStructPresent = reader.flag()
        if reader.flag() {  // bitstream_restriction_flag
            reader.skip(1)
            for _ in 0..<4 { _ = reader.golomb() }
            let reorder = reader.golomb()
            _ = reader.golomb()  // max_dec_frame_buffering
            if !reader.isOverrun { sps.maxNumReorderFrames = min(reorder, H264SPS.maximumReorderDepth) }
        }
    }

    /// hrd_parameters() (Annex E.1.2): the bit lengths of cpb_removal_delay and dpb_output_delay.
    private static func parseHRD(_ reader: inout BitReader) -> (cpbRemovalDelayBits: Int, dpbOutputDelayBits: Int)? {
        let count = reader.golomb() + 1
        guard count <= 32 else {
            reader.skip(reader.remainingBits + 1)
            return nil
        }
        reader.skip(8)  // bit_rate_scale, cpb_size_scale
        for _ in 0..<count where !reader.isOverrun {
            _ = reader.golomb()
            _ = reader.golomb()
            reader.skip(1)
        }
        reader.skip(5)  // initial_cpb_removal_delay_length_minus1
        let cpb = reader.int(5) + 1
        let dpb = reader.int(5) + 1
        reader.skip(5)  // time_offset_length
        return (cpb, dpb)
    }

    /// pic_parameter_set_rbsp(): pic_parameter_set_id and seq_parameter_set_id.
    static func ppsIDs(_ rbsp: UnsafeBufferPointer<UInt8>) -> (pps: Int, sps: Int)? {
        var reader = BitReader(rbsp)
        let pps = reader.golomb()
        let sps = reader.golomb()
        guard !reader.isOverrun, pps < 256, sps < 32 else { return nil }
        return (pps, sps)
    }

    /// The pps id at the start of a slice header (needed to find its SPS before the rest can be read).
    static func slicePPSID(_ rbsp: UnsafeBufferPointer<UInt8>) -> Int? {
        var reader = BitReader(rbsp)
        _ = reader.golomb()
        _ = reader.golomb()
        let pps = reader.golomb()
        return reader.isOverrun || pps >= 256 ? nil : pps
    }

    /// slice_header() (§7.3.3) up to bottom_field_flag.
    static func slice(_ rbsp: UnsafeBufferPointer<UInt8>, sps: H264SPS) -> H264Slice? {
        var reader = BitReader(rbsp)
        let firstMB = reader.golomb()
        let sliceType = reader.golomb()
        let pps = reader.golomb()
        if sps.separateColourPlane { reader.skip(2) }
        var slice = H264Slice(firstMB: firstMB, sliceType: sliceType, ppsID: pps,
                              frameNum: reader.int(sps.log2MaxFrameNum))
        if !sps.frameMBsOnly {
            slice.fieldPic = reader.flag()
            if slice.fieldPic { slice.bottomField = reader.flag() }
        }
        guard !reader.isOverrun, sliceType <= 9 else { return nil }
        return slice
    }

    /// pic_struct from a picture timing SEI payload (§D.1.3), when the SPS says it is present.
    static func picStruct(_ payload: UnsafeBufferPointer<UInt8>, sps: H264SPS) -> Int? {
        guard sps.picStructPresent else { return nil }
        var reader = BitReader(payload)
        if let delays = sps.hrdDelays { reader.skip(delays.cpbRemovalDelayBits + delays.dpbOutputDelayBits) }
        let value = reader.int(4)
        return reader.isOverrun || value > 8 ? nil : value
    }
}
