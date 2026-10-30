//
//  NALFixtures.swift
//  MPEGTSTests
//
//  Hand-built H.264 and HEVC NAL units (parameter sets, slice headers, SEI) for the framer tests, written from the
//  specs' syntax tables with `BitWriter`. Slice data after the header is filler: the framer never decodes it.
//

import Foundation
@testable import MPEGTS

extension BitWriter {
    /// ue(v).
    mutating func golomb(_ value: Int) {
        let code = value + 1
        let length = Int.bitWidth - code.leadingZeroBitCount
        write(0, bits: length - 1)
        write(code, bits: length)
    }

    /// se(v).
    mutating func signedGolomb(_ value: Int) {
        golomb(value > 0 ? 2 * value - 1 : -2 * value)
    }

    /// rbsp_trailing_bits().
    mutating func trailing() -> [UInt8] {
        write(1, bits: 1)
        return finish()
    }
}

enum NALFixtures {
    static let startCode: [UInt8] = [0, 0, 0, 1]

    /// Inserts emulation_prevention_three_byte where the RBSP would form a start code.
    static func escape(_ rbsp: [UInt8]) -> [UInt8] {
        var output: [UInt8] = []
        var zeros = 0
        for byte in rbsp {
            if zeros >= 2, byte <= 3 {
                output.append(3)
                zeros = 0
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    static func nal(_ header: [UInt8], _ rbsp: [UInt8]) -> [UInt8] {
        startCode + header + escape(rbsp)
    }

    // MARK: - H.264

    struct H264Options {
        var widthMBs = 120
        var heightMapUnits = 34
        var frameMBsOnly = false
        /// frame_crop_bottom_offset (CropUnitY is 4 with fields, 2 without).
        var cropBottom = 2
        var picStruct = true
        var reorder: Int? = 2
    }

    /// A High-profile SPS with a VUI: 1:1 samples, 60000/1001 ticks (29.97 frames), NAL HRD with 24-bit delays.
    static func h264SPS(_ options: H264Options = H264Options()) -> [UInt8] {
        var bits = BitWriter()
        bits.write(100, bits: 8)
        bits.write(0, bits: 8)
        bits.write(40, bits: 8)
        bits.golomb(0)  // seq_parameter_set_id
        bits.golomb(1)  // chroma_format_idc
        bits.golomb(0)
        bits.golomb(0)
        bits.write(0, bits: 1)
        bits.write(0, bits: 1)  // seq_scaling_matrix_present_flag
        bits.golomb(0)  // log2_max_frame_num_minus4: 4-bit frame_num
        bits.golomb(0)  // pic_order_cnt_type
        bits.golomb(2)
        bits.golomb(4)  // max_num_ref_frames
        bits.write(0, bits: 1)
        bits.golomb(options.widthMBs - 1)
        bits.golomb(options.heightMapUnits - 1)
        bits.write(options.frameMBsOnly ? 1 : 0, bits: 1)
        if !options.frameMBsOnly { bits.write(1, bits: 1) }
        bits.write(1, bits: 1)  // direct_8x8_inference_flag
        bits.write(1, bits: 1)  // frame_cropping_flag
        for offset in [0, 0, 0, options.cropBottom] { bits.golomb(offset) }
        bits.write(1, bits: 1)  // vui_parameters_present_flag
        writeVUI(&bits, options)
        return nal([0x67], bits.trailing())
    }

    private static func writeVUI(_ bits: inout BitWriter, _ options: H264Options) {
        bits.write(1, bits: 1)
        bits.write(1, bits: 8)  // aspect_ratio_idc 1:1
        bits.write(0, bits: 1)  // overscan
        bits.write(0, bits: 1)  // video signal type
        bits.write(0, bits: 1)  // chroma location
        bits.write(1, bits: 1)  // timing_info_present_flag
        bits.write(1001, bits: 32)
        bits.write(60000, bits: 32)
        bits.write(1, bits: 1)
        bits.write(1, bits: 1)  // nal_hrd_parameters_present_flag
        bits.golomb(0)  // cpb_cnt_minus1
        bits.write(4, bits: 4)
        bits.write(6, bits: 4)
        bits.golomb(1000)
        bits.golomb(2000)
        bits.write(0, bits: 1)
        for length in [23, 23, 23, 24] { bits.write(length, bits: 5) }
        bits.write(0, bits: 1)  // vcl_hrd_parameters_present_flag
        bits.write(0, bits: 1)  // low_delay_hrd_flag
        bits.write(options.picStruct ? 1 : 0, bits: 1)
        bits.write(options.reorder == nil ? 0 : 1, bits: 1)
        if let reorder = options.reorder {
            bits.write(1, bits: 1)
            for value in [0, 0, 16, 16] { bits.golomb(value) }
            bits.golomb(reorder)
            bits.golomb(4)
        }
    }

    static func h264PPS() -> [UInt8] {
        var bits = BitWriter()
        bits.golomb(0)
        bits.golomb(0)
        bits.write(1, bits: 1)  // entropy_coding_mode_flag
        bits.write(0, bits: 1)
        bits.golomb(0)
        return nal([0x68], bits.trailing())
    }

    static let h264AUD: [UInt8] = startCode + [0x09, 0xF0]

    /// A slice: nal_ref_idc and type in the header, then the header fields up to bottom_field_flag and filler.
    static func h264Slice(type: Int = 1, refIdc: Int = 2, firstMB: Int = 0, sliceType: Int = 5, frameNum: Int = 0,
                          field: Bool? = nil, frameMBsOnly: Bool = false) -> [UInt8] {
        var bits = BitWriter()
        bits.golomb(firstMB)
        bits.golomb(sliceType)
        bits.golomb(0)
        bits.write(frameNum & 0x0F, bits: 4)
        if !frameMBsOnly {
            bits.write(field == nil ? 0 : 1, bits: 1)
            if let field { bits.write(field ? 1 : 0, bits: 1) }
        }
        bits.write(0x5A5A, bits: 16)
        return nal([UInt8((refIdc << 5) | type)], bits.trailing() + [0xA5, 0x5A, 0xC3, 0x81])
    }

    /// An SEI NAL unit with the given (payloadType, payload) messages.
    static func sei(_ messages: [(Int, [UInt8])], header: [UInt8] = [0x06]) -> [UInt8] {
        var rbsp: [UInt8] = []
        for (type, payload) in messages {
            rbsp += [UInt8(type), UInt8(payload.count)] + payload
        }
        return nal(header, rbsp + [0x80])
    }

    /// Picture timing with 24-bit delays and the given pic_struct (clock timestamps absent).
    static func picTiming(_ picStruct: Int) -> (Int, [UInt8]) {
        var bits = BitWriter()
        bits.write(2, bits: 24)
        bits.write(4, bits: 24)
        bits.write(picStruct, bits: 4)
        bits.write(0, bits: 4)
        return (1, bits.finish())
    }

    /// ATSC A/53 caption data in user_data_registered_itu_t_t35: two cc_data triplets.
    static let captionTriplets: [UInt8] = [0xFC, 0x94, 0x20, 0xFD, 0x80, 0x80]
    static func captions() -> (Int, [UInt8]) {
        (4, [0xB5, 0x00, 0x31] + Array("GA94".utf8) + [0x03, 0x40 | 2, 0xFF] + captionTriplets + [0xFF])
    }

    // MARK: - HEVC

    static func hevcHeader(_ type: Int, temporalID: Int = 0) -> [UInt8] {
        [UInt8(type << 1), UInt8(temporalID + 1)]
    }

    static func hevcVPS() -> [UInt8] {
        nal(hevcHeader(32), [0x0C, 0x01, 0xFF, 0xFF, 0x01, 0x60, 0x80])
    }

    /// A Main 10 SPS: 1920x1088 coded, cropped to 1080 by the conformance window, `subLayers` temporal sub-layers.
    static func hevcSPS(subLayers: Int = 1, reorder: Int = 2) -> [UInt8] {
        var bits = BitWriter()
        bits.write(0, bits: 4)
        bits.write(subLayers - 1, bits: 3)
        bits.write(1, bits: 1)
        bits.write(2, bits: 8)  // profile space, tier, general_profile_idc 2 (Main 10)
        bits.write(0x2000_0000, bits: 32)
        bits.write(0b1001, bits: 4)  // progressive, not interlaced, packed, frame only
        bits.write(0, bits: 32)
        bits.write(0, bits: 12)
        bits.write(123, bits: 8)  // general_level_idc
        for _ in 0..<(subLayers - 1) { bits.write(0, bits: 2) }
        if subLayers > 1 { bits.write(0, bits: 2 * (9 - subLayers)) }
        bits.golomb(0)  // sps id
        bits.golomb(1)  // 4:2:0
        bits.golomb(1920)
        bits.golomb(1088)
        bits.write(1, bits: 1)
        for offset in [0, 0, 0, 4] { bits.golomb(offset) }
        bits.golomb(2)
        bits.golomb(2)
        bits.golomb(4)
        bits.write(1, bits: 1)  // sub_layer_ordering_info_present_flag
        for _ in 0..<subLayers {
            bits.golomb(4)
            bits.golomb(reorder)
            bits.golomb(0)
        }
        bits.write(0x1234, bits: 16)
        return nal(hevcHeader(33), bits.trailing())
    }

    static func hevcPPS() -> [UInt8] {
        var bits = BitWriter()
        bits.golomb(0)
        bits.golomb(0)
        bits.write(0x3C, bits: 8)
        return nal(hevcHeader(34), bits.trailing())
    }

    static func hevcSlice(type: Int, temporalID: Int = 0, first: Bool = true) -> [UInt8] {
        var bits = BitWriter()
        bits.write(first ? 1 : 0, bits: 1)
        if (16...23).contains(type) { bits.write(0, bits: 1) }
        bits.golomb(0)
        bits.write(0x5A5A, bits: 16)
        return nal(hevcHeader(type, temporalID: temporalID), bits.trailing() + [0xC3, 0x81])
    }

    static func pes(_ bytes: [UInt8], pts: Int64?, dts: Int64? = nil) -> PESPacket {
        PESPacket(pid: 0x31, streamID: 0xE0, pts: pts, dts: dts, payload: Data(bytes))
    }

    /// The NAL unit types inside a 4-byte length-prefixed sample, or nil if the lengths don't add up.
    static func sampleTypes(_ data: Data, hevc: Bool = false) -> [Int]? {
        let bytes = [UInt8](data)
        var types: [Int] = []
        var offset = 0
        while offset + 4 <= bytes.count {
            let length = bytes[offset..<(offset + 4)].reduce(0) { ($0 << 8) | Int($1) }
            offset += 4
            guard length > 0, offset + length <= bytes.count else { return nil }
            types.append(hevc ? Int(bytes[offset] >> 1) & 0x3F : Int(bytes[offset] & 0x1F))
            offset += length
        }
        return offset == bytes.count ? types : nil
    }
}
