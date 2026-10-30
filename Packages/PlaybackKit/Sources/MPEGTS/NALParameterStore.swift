//
//  NALParameterStore.swift
//  MPEGTS
//
//  The H.264 and HEVC parameter sets seen so far, by id, as raw NAL units (for the format description) and parsed
//  (for the framer). Ids are bounded by the specs (SPS 0…31 / 0…15, PPS 0…255 / 0…63, VPS 0…15), so the store is
//  bounded too.
//

import Foundation

/// The parameter sets one picture uses and what they say.
nonisolated struct ActiveParameters: Sendable {
    var parameterSets: [Data]
    var format: NALVideoFormat
    var h264: H264SPS?
    var hevc: HEVCSPS?
}

nonisolated struct NALParameterStore: Sendable {
    /// Parameter sets longer than this are ignored (real ones are tens to a few hundred bytes).
    static let maximumSize = 16 * 1024

    private struct Entry<Info: Sendable>: Sendable {
        var raw: Data
        var info: Info
    }

    private var h264SPS: [Int: Entry<H264SPS>] = [:]
    private var hevcSPS: [Int: Entry<HEVCSPS>] = [:]
    private var vps: [Int: Data] = [:]
    /// PPS id to its raw bytes and the id of the SPS it refers to.
    private var pps: [Int: Entry<Int>] = [:]

    /// Stores an H.264 SPS (`nal` is the whole NAL unit, header included).
    mutating func storeH264SPS(_ nal: UnsafeBufferPointer<UInt8>) {
        guard nal.count <= Self.maximumSize else { return }
        let rbsp = NALSyntax.rbsp(nal, from: 1)
        guard let info = rbsp.withUnsafeBufferPointer({ H264Headers.sps($0) }) else { return }
        h264SPS[info.id] = Entry(raw: Data(buffer: nal), info: info)
    }

    mutating func storeHEVCSPS(_ nal: UnsafeBufferPointer<UInt8>) {
        guard nal.count <= Self.maximumSize else { return }
        let rbsp = NALSyntax.rbsp(nal, from: 2)
        guard let info = rbsp.withUnsafeBufferPointer({ HEVCHeaders.sps($0) }) else { return }
        hevcSPS[info.id] = Entry(raw: Data(buffer: nal), info: info)
    }

    mutating func storeVPS(_ nal: UnsafeBufferPointer<UInt8>) {
        guard nal.count <= Self.maximumSize else { return }
        let rbsp = NALSyntax.rbsp(nal, from: 2, limit: 4)
        guard let id = rbsp.withUnsafeBufferPointer({ HEVCHeaders.vpsID($0) }) else { return }
        vps[id] = Data(buffer: nal)
    }

    mutating func storePPS(_ nal: UnsafeBufferPointer<UInt8>, codec: NALVideoCodec) {
        guard nal.count <= Self.maximumSize else { return }
        let rbsp = NALSyntax.rbsp(nal, from: codec == .h264 ? 1 : 2, limit: 16)
        let ids = rbsp.withUnsafeBufferPointer { codec == .h264 ? H264Headers.ppsIDs($0) : HEVCHeaders.ppsIDs($0) }
        guard let ids else { return }
        pps[ids.pps] = Entry(raw: Data(buffer: nal), info: ids.sps)
    }

    /// The H.264 SPS a PPS refers to.
    func h264SPS(forPPS id: Int) -> H264SPS? {
        pps[id].flatMap { h264SPS[$0.info]?.info }
    }

    /// Everything a picture whose slices use PPS `id` needs, or nil while a parameter set is missing.
    func active(forPPS id: Int, codec: NALVideoCodec) -> ActiveParameters? {
        guard let picture = pps[id] else { return nil }
        let spsID = picture.info
        let siblings = pps.keys.sorted().compactMap { key in pps[key].flatMap { $0.info == spsID ? $0.raw : nil } }
        switch codec {
        case .h264:
            guard let sps = h264SPS[spsID] else { return nil }
            return ActiveParameters(parameterSets: [sps.raw] + siblings, format: sps.info.format, h264: sps.info)
        case .hevc:
            guard let sps = hevcSPS[spsID], let video = vps[sps.info.vpsID] else { return nil }
            return ActiveParameters(parameterSets: [video, sps.raw] + siblings, format: sps.info.format,
                                    hevc: sps.info)
        }
    }
}
