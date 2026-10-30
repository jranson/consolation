//
//  NALVideoFramer.swift
//  MPEGTS
//
//  Splits an H.264 or HEVC Annex-B elementary stream into access units: NAL units are split on start codes; an access
//  unit ends where the next one begins, at an access unit delimiter, parameter set, SEI or other prefix NAL unit after
//  a picture's slices, or at the first slice of a new picture (H.264 first_mb_in_slice 0, HEVC
//  first_slice_segment_in_pic_flag). Each unit becomes a 4-byte length-prefixed sample with its parameter sets held
//  separately, so a format description can be built from them (and rebuilt when they change).
//
//  H.264 field pictures arrive as one access unit per field; a complementary pair (opposite parity, same frame_num)
//  is joined into one sample, as for MPEG-2 field pairs, so the decoder outputs one woven frame for the deinterlacer.
//
//  Output starts at the first random-access picture with a PTS (IDR/IRAP, or an H.264 intra picture or recovery
//  point); the pictures that follow it in decode order but display before it (open-GOP leading pictures, HEVC RASL)
//  are dropped, since they may reference pictures that were never received.
//

import Foundation

nonisolated public struct NALVideoFramer: Sendable {
    /// Bytes of one NAL unit or access unit beyond which it is discarded as garbage.
    public static let maximumAccessUnitSize = 4 * 1024 * 1024

    public let codec: NALVideoCodec
    /// The format of the last picture emitted.
    public internal(set) var format: NALVideoFormat?

    var buffer: [UInt8] = []
    var scanPosition = 0
    /// Where the start code of the NAL unit being read is.
    var openNAL: Int?
    var stamps: [PendingStamp] = []
    var parameters = NALParameterStore()
    var unit: NALUnitBuilder?
    /// An H.264 first field waiting for its partner.
    var heldField: FramedPicture?
    /// A delivered sample's storage, reused by the next access unit so building one rarely allocates.
    var spareSample: [UInt8] = []
    var timing = NALTiming()
    var hasStarted = false
    /// After the start, pictures displayed before this PTS (leading pictures) are dropped.
    var leadingCutoff: Int64?

    public init(codec: NALVideoCodec) {
        self.codec = codec
    }

    /// Appends one video PES and returns the access units it completed, in decode order.
    public mutating func append(_ pes: PESPacket) -> [NALAccessUnit] {
        pes.payload.withUnsafeBytes { raw in append(raw.bindMemory(to: UInt8.self), of: pes) }
    }

    /// `append(_:)` for a payload lent by `TSDemuxer.feed(_:_:)` (`pes.payload` is ignored).
    public mutating func append(_ payload: UnsafeBufferPointer<UInt8>, of pes: PESPacket) -> [NALAccessUnit] {
        var output: [NALAccessUnit] = []
        append(payload, of: pes) { output.append($0.copying($1)) }
        return output
    }

    /// Appends one video PES's payload (`pes.payload` is ignored) and hands each access unit it completed to
    /// `body`, in decode order. The unit's `data` is empty: its sample is lent instead, valid only during the call.
    public mutating func append(_ payload: UnsafeBufferPointer<UInt8>, of pes: PESPacket, _ body: NALUnitHandler) {
        if pes.pts != nil || pes.isDiscontinuity {
            stamps.append(PendingStamp(offset: buffer.count, pts: pes.pts, dts: pes.dts,
                                       discontinuity: pes.isDiscontinuity))
            if stamps.count > MPEG2Framer.maximumPendingStamps {
                stamps.removeFirst(stamps.count - MPEG2Framer.maximumPendingStamps)
            }
        }
        buffer.append(contentsOf: payload)
        scan(deliver: body)
        compact()
    }

    /// Completes the unit in progress (and a held field), for the end of a finite stream.
    public mutating func flush() -> [NALAccessUnit] {
        var output: [NALAccessUnit] = []
        flush { output.append($0.copying($1)) }
        return output
    }

    /// `flush()`, lending each unit's sample as `append(_:of:_:)` does.
    public mutating func flush(_ deliver: NALUnitHandler) {
        var bytes: [UInt8] = []
        swap(&bytes, &buffer)
        bytes.withUnsafeBufferPointer { pointer in
            if let open = openNAL { closeNAL(pointer, startCode: open, end: pointer.count, deliver: deliver) }
        }
        openNAL = nil
        if let finished = unit.take() { complete(finished, deliver: deliver) }
        if var held = heldField.take() { emit(&held, deliver: deliver) }
        buffer.removeAll()
        scanPosition = 0
        stamps.removeAll()
    }

    /// Forgets everything, including parameter sets; output restarts at the next random-access picture.
    public mutating func reset() {
        self = NALVideoFramer(codec: codec)
    }

    // MARK: - Scanning

    private mutating func scan(deliver: NALUnitHandler) {
        var bytes: [UInt8] = []
        swap(&bytes, &buffer)
        bytes.withUnsafeBufferPointer { pointer in
            var position = scanPosition
            while let start = MPEG2StartCode.find(pointer, from: position) {
                if let open = openNAL { closeNAL(pointer, startCode: open, end: start, deliver: deliver) }
                openNAL = start
                position = start + 3
            }
            scanPosition = max(position, pointer.count - 3)
        }
        swap(&bytes, &buffer)
    }

    /// The NAL unit after the start code at `startCode` ends at `end` (less trailing zero bytes): handle it.
    private mutating func closeNAL(_ bytes: UnsafeBufferPointer<UInt8>, startCode: Int, end: Int,
                                   deliver: NALUnitHandler) {
        let begin = startCode + 3
        var last = min(end, bytes.count)
        while last > begin, bytes[last - 1] == 0 { last -= 1 }
        let headerBytes = codec == .h264 ? 1 : 2
        guard last - begin > headerBytes else { return }
        let nal = UnsafeBufferPointer(rebasing: bytes[begin..<last])
        switch codec {
        case .h264: handleH264(nal, at: startCode, deliver: deliver)
        case .hevc: handleHEVC(nal, at: startCode, deliver: deliver)
        }
    }

    /// Closes the unit in progress if it has a picture; returns the unit to add the NAL unit at `position` to.
    mutating func beginUnitIfNeeded(newPicture: Bool, at position: Int, deliver: NALUnitHandler) {
        if newPicture, unit?.hasVCL == true, let finished = unit.take() {
            complete(finished, deliver: deliver)
        }
        if unit == nil {
            var fresh = NALUnitBuilder(stamp: takeStamp(at: position))
            swap(&fresh.sample, &spareSample)
            unit = fresh
        }
    }

    /// The timestamps for an access unit starting at `position`: the latest PES timestamp at or before it, with
    /// discontinuity flags merged. Consumes those entries.
    private mutating func takeStamp(at position: Int) -> PendingStamp? {
        var consumed = 0
        var result: PendingStamp?
        var discontinuity = false
        for entry in stamps {
            guard entry.offset <= position else { break }
            consumed += 1
            discontinuity = discontinuity || entry.discontinuity
            if entry.pts != nil { result = entry }
        }
        guard consumed > 0 else { return nil }
        stamps.removeFirst(consumed)
        var stamp = result ?? PendingStamp(offset: position, pts: nil, dts: nil, discontinuity: false)
        stamp.discontinuity = discontinuity
        return stamp
    }

    /// Drops bytes already handled and caps a NAL unit that never ends.
    private mutating func compact() {
        if let open = openNAL, buffer.count - open > Self.maximumAccessUnitSize {
            openNAL = nil
            unit?.isBroken = true
            scanPosition = max(0, buffer.count - 3)
        }
        let keep = min(openNAL ?? scanPosition, scanPosition)
        guard keep > 0 else { return }
        buffer.removeSubrange(0..<keep)
        scanPosition -= keep
        openNAL = openNAL.map { $0 - keep }
        for index in stamps.indices {
            stamps[index].offset = max(0, stamps[index].offset - keep)
        }
    }
}
