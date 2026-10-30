//
//  MPEG2Framer.swift
//  MPEGTS
//
//  Splits an MPEG-2 video elementary stream into access units: exactly one coded picture (or field pair) per unit, with
//  the sequence header, sequence extension, GOP header and user data that precede it. A new unit starts only at a
//  sequence header, GOP header or picture start code after a picture has been seen, so headers are never emitted on
//  their own (VideoToolbox fails those with -12909).
//
//  Output starts at the first sequence header followed by an I picture with a PTS, and the leading B pictures of
//  that first open GOP are dropped because they reference a GOP that was never received.
//

import Foundation

nonisolated public struct MPEG2Framer: Sendable {
    /// Bytes of one access unit beyond which the unit is discarded as garbage.
    public static let maximumAccessUnitSize = 4 * 1024 * 1024
    static let maximumPendingStamps = 64

    /// The most recently parsed sequence parameters.
    public internal(set) var sequence: MPEG2SequenceInfo?

    var buffer: [UInt8] = []
    var scanPosition = 0
    /// The start code whose header bytes run to the next start code, and where it is.
    var openCode: UInt8?
    var openCodePosition = 0
    var unit = UnitBuilder(start: 0)
    var stamps: [PendingStamp] = []
    var timing = MPEG2Timing()
    var hasStarted = false
    var isDroppingLeadingB = false
    /// The current unit's first picture is a field: route the next picture coding extension to the second field.
    var isSecondFieldExtension = false

    public init() {}

    /// Appends one video PES and returns the access units it completed, in decode order.
    public mutating func append(_ pes: PESPacket) -> [MPEG2AccessUnit] {
        var output: [MPEG2AccessUnit] = []
        pes.payload.withUnsafeBytes { raw in
            append(raw.bindMemory(to: UInt8.self), of: pes) { output.append($0.copying($1)) }
        }
        return output
    }

    /// Appends one video PES's payload (`pes.payload` is ignored) and hands each access unit it completed to
    /// `body`, in decode order. The unit's `data` is empty: its bytes are lent instead, valid only during the call.
    public mutating func append(
        _ payload: UnsafeBufferPointer<UInt8>,
        of pes: PESPacket,
        _ body: (MPEG2AccessUnit, UnsafeBufferPointer<UInt8>) -> Void
    ) {
        if pes.pts != nil || pes.isDiscontinuity {
            stamps.append(PendingStamp(offset: buffer.count, pts: pes.pts, dts: pes.dts,
                                       discontinuity: pes.isDiscontinuity))
            if stamps.count > Self.maximumPendingStamps {
                stamps.removeFirst(stamps.count - Self.maximumPendingStamps)
            }
        }
        buffer.append(contentsOf: payload)
        scan(emit: body)
        compact()
    }

    /// Completes the unit in progress, for the end of a finite stream.
    public mutating func flush() -> [MPEG2AccessUnit] {
        var output: [MPEG2AccessUnit] = []
        flush { output.append($0.copying($1)) }
        return output
    }

    /// `flush()`, lending the unit's bytes as `append(_:of:_:)` does.
    public mutating func flush(_ body: (MPEG2AccessUnit, UnsafeBufferPointer<UInt8>) -> Void) {
        var bytes: [UInt8] = []
        swap(&bytes, &buffer)
        bytes.withUnsafeBufferPointer { pointer in
            closeSegment(end: pointer.count, bytes: pointer)
            if unit.pictureCount > 0 {
                finalize(end: pointer.count, bytes: pointer, emit: body)
            }
        }
        swap(&bytes, &buffer)
        buffer.removeAll(keepingCapacity: true)
        scanPosition = 0
        openCode = nil
        unit = UnitBuilder(start: 0)
        stamps.removeAll()
    }

    /// Forgets everything, including the sequence; output restarts at the next sequence header and I picture.
    public mutating func reset() {
        self = MPEG2Framer()
    }

    // MARK: - Scanning

    private mutating func scan(emit: (MPEG2AccessUnit, UnsafeBufferPointer<UInt8>) -> Void) {
        var bytes: [UInt8] = []
        swap(&bytes, &buffer)
        bytes.withUnsafeBufferPointer { pointer in
            var position = scanPosition
            while let start = MPEG2StartCode.find(pointer, from: position) {
                closeSegment(end: start, bytes: pointer)
                position = handleStartCode(pointer[start + 3], at: start, bytes: pointer, emit: emit)
            }
            scanPosition = max(position, pointer.count - 3)
        }
        swap(&bytes, &buffer)
    }

    /// Applies the access-unit boundary rules for a start code and opens its header segment. Returns where to resume.
    private mutating func handleStartCode(
        _ code: UInt8,
        at start: Int,
        bytes: UnsafeBufferPointer<UInt8>,
        emit: (MPEG2AccessUnit, UnsafeBufferPointer<UInt8>) -> Void
    ) -> Int {
        switch code {
        case MPEG2StartCode.sequenceHeader:
            if unit.pictureCount > 0 {
                finalize(end: start, bytes: bytes, emit: emit)
            }
            unit = UnitBuilder(start: start)
        case MPEG2StartCode.groupOfPictures:
            if unit.pictureCount > 0 {
                finalize(end: start, bytes: bytes, emit: emit)
                unit = UnitBuilder(start: start)
            } else if !unit.hasSequenceHeader {
                unit = UnitBuilder(start: start)
            }
        case MPEG2StartCode.picture:
            if unit.pictureCount > 0, !unit.awaitingSecondField {
                finalize(end: start, bytes: bytes, emit: emit)
                unit = UnitBuilder(start: start)
            } else if unit.isEmpty {
                unit = UnitBuilder(start: start)
            }
            let stamp = takeStamp(at: start)
            if unit.pictureCount == 0 {
                unit.stamp = stamp
            } else if stamp?.discontinuity == true {
                unit.stamp?.discontinuity = true
            }
        case MPEG2StartCode.sequenceEnd:
            if unit.pictureCount > 0 {
                finalize(end: start + 4, bytes: bytes, emit: emit)
                unit = UnitBuilder(start: start + 4)
            }
            openCode = nil
            return start + 4
        default:
            break
        }
        openCode = code
        openCodePosition = start
        return start + 4
    }

    /// The timestamps for a picture starting at `position`: the latest PES timestamp at or before it, with
    /// discontinuity flags merged. Consumes those entries.
    private mutating func takeStamp(at position: Int) -> PendingStamp? {
        var consumed = 0
        var result: PendingStamp?
        var discontinuity = false
        for entry in stamps {
            guard entry.offset <= position else { break }
            consumed += 1
            discontinuity = discontinuity || entry.discontinuity
            if entry.pts != nil {
                result = entry
            }
        }
        guard consumed > 0 else { return nil }
        stamps.removeFirst(consumed)
        var stamp = result ?? PendingStamp(offset: position, pts: nil, dts: nil, discontinuity: false)
        stamp.discontinuity = discontinuity
        return stamp
    }

    /// Drops bytes no longer needed and caps the unit in progress.
    private mutating func compact() {
        if buffer.count - unit.start > Self.maximumAccessUnitSize {
            let restart = max(unit.start, buffer.count - 3)
            unit = UnitBuilder(start: restart)
            openCode = nil
            scanPosition = restart
            stamps.removeAll()
        }
        var keep = min(unit.start, scanPosition)
        if openCode != nil {
            keep = min(keep, openCodePosition)
        }
        guard keep > 0 else { return }
        buffer.removeSubrange(0..<keep)
        unit.start -= keep
        scanPosition -= keep
        openCodePosition = max(0, openCodePosition - keep)
        for index in stamps.indices {
            stamps[index].offset = max(0, stamps[index].offset - keep)
        }
    }
}
