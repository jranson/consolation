//
//  HEVCHeaders.swift
//  MPEGTS
//
//  The parts of HEVC (ISO/IEC 23008-2 / ITU-T H.265) headers the framer needs: the sequence parameter set up to the
//  sub-layer ordering info (size, conformance window, bit depth, sub-layers, reorder depth), the parameter set ids,
//  and the start of the slice segment header. NAL unit types are from Table 7-1.
//

nonisolated struct HEVCSPS: Equatable, Sendable {
    var id: Int
    var vpsID: Int
    var maxSubLayersMinus1: Int
    var width: Int
    var height: Int
    var bitDepthLuma: Int
    var maxNumReorderPics: Int
    /// general_interlaced_source_flag: the pictures may be fields (field_seq_flag), which VideoToolbox doesn't weave.
    var interlacedSource: Bool

    var format: NALVideoFormat {
        NALVideoFormat(width: width, height: height, bitDepth: bitDepthLuma,
                       reorderDepth: min(maxNumReorderPics, H264SPS.maximumReorderDepth))
    }
}

nonisolated enum HEVCNALType {
    static let rasl = 8...9
    static let irap = 16...23
    static let idr = 19...20
    static let vps = 32
    static let sps = 33
    static let pps = 34
    static let accessUnitDelimiter = 35
    static let fillerData = 38
    static let prefixSEI = 39

    static func isVCL(_ type: Int) -> Bool { type < 32 }

    /// A sub-layer non-reference picture (TRAIL_N, TSA_N, STSA_N, RADL_N, RASL_N, RSV_VCL_N10/12/14): no picture of
    /// the same sub-layer references it, though a higher sub-layer may.
    static func isSubLayerNonReference(_ type: Int) -> Bool { type <= 14 && type % 2 == 0 }

    /// Types that, after a picture's last VCL NAL unit, begin the next access unit (§7.4.2.4.4).
    static func startsAccessUnit(_ type: Int) -> Bool {
        (32...35).contains(type) || type == prefixSEI || (41...44).contains(type) || (48...55).contains(type)
    }
}

nonisolated enum HEVCHeaders {
    /// seq_parameter_set_rbsp() (§7.3.2.2.1) from the RBSP after the 2-byte NAL header.
    static func sps(_ rbsp: UnsafeBufferPointer<UInt8>) -> HEVCSPS? {
        var reader = BitReader(rbsp)
        let vpsID = reader.int(4)
        let maxSubLayersMinus1 = reader.int(3)
        reader.skip(1)  // sps_temporal_id_nesting_flag
        guard maxSubLayersMinus1 <= 6 else { return nil }
        let interlaced = profileTierLevel(&reader, maxSubLayersMinus1: maxSubLayersMinus1)
        let id = reader.golomb()
        let chroma = reader.golomb()
        var separatePlanes = false
        if chroma == 3 { separatePlanes = reader.flag() }
        let codedWidth = reader.golomb()
        let codedHeight = reader.golomb()
        var window = (left: 0, right: 0, top: 0, bottom: 0)
        if reader.flag() {
            window = (reader.golomb(), reader.golomb(), reader.golomb(), reader.golomb())
        }
        let bitDepth = reader.golomb() + 8
        _ = reader.golomb()  // bit_depth_chroma_minus8
        _ = reader.golomb()  // log2_max_pic_order_cnt_lsb_minus4
        let orderingForAll = reader.flag()
        var reorder = 0
        for _ in (orderingForAll ? 0 : maxSubLayersMinus1)...maxSubLayersMinus1 {
            _ = reader.golomb()  // sps_max_dec_pic_buffering_minus1
            reorder = reader.golomb()  // the highest sub-layer's value is kept
            _ = reader.golomb()  // sps_max_latency_increase_plus1
        }
        guard !reader.isOverrun, id < 16, chroma <= 3, (8...16).contains(bitDepth),
              (1...16_384).contains(codedWidth), (1...16_384).contains(codedHeight) else { return nil }
        let subWidth = chroma == 1 || chroma == 2 ? 2 : 1
        let subHeight = chroma == 1 ? 2 : 1
        let unitX = separatePlanes ? 1 : subWidth
        let unitY = separatePlanes ? 1 : subHeight
        let width = codedWidth - unitX * (window.left + window.right)
        let height = codedHeight - unitY * (window.top + window.bottom)
        guard width > 0, height > 0 else { return nil }
        return HEVCSPS(id: id, vpsID: vpsID, maxSubLayersMinus1: maxSubLayersMinus1, width: width, height: height,
                       bitDepthLuma: bitDepth, maxNumReorderPics: reorder, interlacedSource: interlaced)
    }

    /// profile_tier_level(1, maxSubLayersMinus1) (§7.3.3); returns general_interlaced_source_flag.
    private static func profileTierLevel(_ reader: inout BitReader, maxSubLayersMinus1: Int) -> Bool {
        reader.skip(2 + 1 + 5 + 32)  // profile space, tier, profile idc, compatibility flags
        reader.skip(1)  // general_progressive_source_flag
        let interlaced = reader.flag()
        reader.skip(2 + 43 + 1)  // non-packed, frame-only, reserved/constraint flags, inbld/reserved
        reader.skip(8)  // general_level_idc
        var profilePresent: [Bool] = []
        var levelPresent: [Bool] = []
        for _ in 0..<maxSubLayersMinus1 {
            profilePresent.append(reader.flag())
            levelPresent.append(reader.flag())
        }
        if maxSubLayersMinus1 > 0 { reader.skip(2 * (8 - maxSubLayersMinus1)) }
        for index in 0..<maxSubLayersMinus1 {
            if profilePresent[index] { reader.skip(88) }
            if levelPresent[index] { reader.skip(8) }
        }
        return interlaced
    }

    /// The VPS's id: the first four bits.
    static func vpsID(_ rbsp: UnsafeBufferPointer<UInt8>) -> Int? {
        var reader = BitReader(rbsp)
        let id = reader.int(4)
        return reader.isOverrun ? nil : id
    }

    /// pps_pic_parameter_set_id and pps_seq_parameter_set_id.
    static func ppsIDs(_ rbsp: UnsafeBufferPointer<UInt8>) -> (pps: Int, sps: Int)? {
        var reader = BitReader(rbsp)
        let pps = reader.golomb()
        let sps = reader.golomb()
        guard !reader.isOverrun, pps < 64, sps < 16 else { return nil }
        return (pps, sps)
    }

    /// first_slice_segment_in_pic_flag and slice_pic_parameter_set_id (§7.3.6.1).
    static func sliceStart(_ rbsp: UnsafeBufferPointer<UInt8>, nalType: Int) -> (first: Bool, ppsID: Int)? {
        var reader = BitReader(rbsp)
        let first = reader.flag()
        if HEVCNALType.irap.contains(nalType) { reader.skip(1) }  // no_output_of_prior_pics_flag
        let pps = reader.golomb()
        guard !reader.isOverrun, pps < 64 else { return nil }
        return (first, pps)
    }
}
