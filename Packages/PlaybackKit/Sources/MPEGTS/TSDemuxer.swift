//
//  TSDemuxer.swift
//  MPEGTS
//
//  A pure-Swift MPEG-2 transport stream demuxer. Feed it arbitrary byte chunks; it keeps a partial-packet remainder,
//  acquires sync only on three consecutive 0x47 bytes 188 apart, parses PAT/PMT (CRC-checked, versioned, multi-program)
//  and reassembles PES packets of every elementary stream listed in a PMT.
//

import Foundation

nonisolated public struct TSDemuxer: Sendable {
    public static let packetSize = 188
    /// A PES larger than this is dropped and its PID resynchronizes at the next payload_unit_start_indicator.
    public static let maximumPESSize = 4 * 1024 * 1024
    static let syncByte: UInt8 = 0x47
    static let nullPID: UInt16 = 0x1FFF
    static let pidCount = 8192
    /// Bytes needed to confirm sync: three sync bytes 188 apart.
    static let syncWindow = 2 * packetSize + 1

    public internal(set) var statistics = TSDemuxStatistics()
    /// The program list most recently emitted as `.programs`.
    public internal(set) var programs: [ProgramMap] = []
    /// When set, only these PIDs are reassembled into PES packets (for example, only the selected program's video
    /// and audio when a full multiplex carries several programs).
    public internal(set) var pesFilter: Set<UInt16>?
    /// The program numbers the current PAT lists, in PAT order, whether or not their PMTs have arrived yet.
    public var listedProgramNumbers: [UInt16] { psi.entries.map(\.programNumber) }

    var remainder: [UInt8] = []
    /// The remainder joined with the head of the next input, reused for every join.
    var joinScratch: [UInt8] = []
    var isLocked = false
    /// Last continuity_counter per PID; 0xFF means none seen yet.
    var continuity = [UInt8](repeating: 0xFF, count: TSDemuxer.pidCount)
    /// Index into `assemblers` per PID; -1 means the PID is not reassembled.
    var pesSlot = [Int16](repeating: -1, count: TSDemuxer.pidCount)
    var assemblers: [PESAssembler] = []
    var psi = PSIState()
    /// The last unwrapped timestamp per program, used to anchor the first timestamp of each new PID.
    var timelineReference: [UInt16: Int64] = [:]
    var lastPCRs: [UInt16: Int64] = [:]

    public init() {}

    /// Feeds the next chunk of the stream, of any size, and returns the events it completed (PES payloads copied).
    public mutating func feed(_ data: Data) -> [TSDemuxEvent] {
        var events: [TSDemuxEvent] = []
        feed(data) { events.append(TSDemuxEvent($0)) }
        return events
    }

    /// Feeds the next chunk of the stream, of any size, and hands each event it completed to `body`, in stream order.
    /// PES payloads are lent rather than copied, so they are valid only during the call. `body` must not use this
    /// demuxer (it is still being changed); apply a new PES filter, for example, after this returns.
    public mutating func feed(_ data: Data, _ body: (TSDemuxBorrowedEvent) -> Void) {
        data.withUnsafeBytes { feed($0, body) }
    }

    /// `feed(_:_:)` for bytes in a caller's buffer (for example a reader's reusable one).
    public mutating func feed(_ bytes: UnsafeRawBufferPointer, _ body: (TSDemuxBorrowedEvent) -> Void) {
        feed(bytes.bindMemory(to: UInt8.self), emit: body)
    }

    /// Emits every PES still being assembled (an unbounded video PES otherwise waits for the next unit start).
    /// Call at the end of a finite input.
    public mutating func flush() -> [TSDemuxEvent] {
        var events: [TSDemuxEvent] = []
        flush { events.append(TSDemuxEvent($0)) }
        return events
    }

    /// `flush()`, lending the payloads as `feed(_:_:)` does.
    public mutating func flush(_ body: (TSDemuxBorrowedEvent) -> Void) {
        for slot in assemblers.indices where assemblers[slot].isActive {
            finishPES(slot: slot, emit: body)
        }
    }

    /// Forgets all state (programs, partial packets and PES, continuity, timelines, statistics). The PES filter stays.
    public mutating func reset() {
        let filter = pesFilter
        self = TSDemuxer()
        pesFilter = filter
    }

    /// Forgets partial packets and PES, continuity and timestamps, but keeps the program tables (and the PES
    /// filter): reading can resume anywhere else in the same stream (a seek) without waiting for its next PAT and
    /// PMT. PES reassembly starts at each PID's next unit start.
    public mutating func resynchronize() {
        remainder.removeAll(keepingCapacity: true)
        isLocked = false
        continuity = [UInt8](repeating: 0xFF, count: Self.pidCount)
        for slot in assemblers.indices {
            assemblers[slot].abandon()
            assemblers[slot].pendingDiscontinuity = false
            assemblers[slot].lastTimestamp = nil
        }
        timelineReference = [:]
    }

    /// Restricts PES reassembly to `pids` (nil for every elementary stream). Takes effect immediately.
    public mutating func setPESFilter(_ pids: Set<UInt16>?) {
        pesFilter = pids
        rebuildSlots()
    }

    /// The most recent program_clock_reference seen on `pid`, in 27 MHz ticks (33-bit base × 300 + extension).
    public func lastPCR(pid: UInt16) -> Int64? {
        lastPCRs[pid]
    }

    // MARK: - Packet framing

    mutating func feed(_ input: UnsafeBufferPointer<UInt8>, emit: (TSDemuxBorrowedEvent) -> Void) {
        var offset = 0
        while !remainder.isEmpty, offset < input.count {
            // Join the remainder with a bounded head of the input; that is always enough to get past the remainder.
            let take = min(input.count - offset, Self.syncWindow + Self.packetSize)
            var joined: [UInt8] = []
            swap(&joined, &joinScratch)
            joined.removeAll(keepingCapacity: true)
            joined.append(contentsOf: remainder)
            joined.append(contentsOf: UnsafeBufferPointer(rebasing: input[offset..<(offset + take)]))
            let previousCount = remainder.count
            let stop = joined.withUnsafeBufferPointer { consume($0, from: 0, emit: emit) }
            remainder.removeAll(keepingCapacity: true)
            if stop >= previousCount {
                offset += stop - previousCount
            } else {
                remainder.append(contentsOf: joined[stop...])
                offset += take
            }
            swap(&joined, &joinScratch)
        }
        guard remainder.isEmpty, offset < input.count else { return }
        let stop = consume(input, from: offset, emit: emit)
        if stop < input.count {
            remainder.append(contentsOf: UnsafeBufferPointer(rebasing: input[stop...]))
        }
    }

    /// Processes whole packets from `start` and returns the index of the first byte it could not use yet.
    private mutating func consume(
        _ bytes: UnsafeBufferPointer<UInt8>,
        from start: Int,
        emit: (TSDemuxBorrowedEvent) -> Void
    ) -> Int {
        var position = start
        let count = bytes.count
        while true {
            if isLocked {
                guard position + Self.packetSize <= count else { return position }
                if bytes[position] == Self.syncByte {
                    let packet = UnsafeBufferPointer(rebasing: bytes[position..<(position + Self.packetSize)])
                    processPacket(packet, emit: emit)
                    position += Self.packetSize
                    continue
                }
                isLocked = false
                statistics.syncLosses += 1
            }
            let searchEnd = count - Self.syncWindow
            guard let found = Self.findSync(bytes, from: position, through: searchEnd) else {
                let stop = max(position, searchEnd + 1)
                statistics.skippedBytes += stop - position
                return stop
            }
            statistics.skippedBytes += found - position
            position = found
            isLocked = true
        }
    }

    /// The first index in `start...last` where three sync bytes sit 188 bytes apart.
    private static func findSync(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int, through last: Int) -> Int? {
        guard start <= last else { return nil }
        var index = start
        while index <= last {
            if bytes[index] == syncByte, bytes[index + packetSize] == syncByte,
               bytes[index + 2 * packetSize] == syncByte {
                return index
            }
            index += 1
        }
        return nil
    }

    // MARK: - Packets

    private struct PacketHeader {
        var pid: UInt16
        var unitStart: Bool
        var continuityCounter: UInt8
        var hasPayloadFlag: Bool
        var isScrambled: Bool
        var payloadStart: Int
        var randomAccess = false
        var discontinuityIndicator = false
        var pcr: Int64?
    }

    /// Parses the 4-byte header and adaptation field. Nil for packets that must be dropped.
    private mutating func parseHeader(_ packet: UnsafeBufferPointer<UInt8>) -> PacketHeader? {
        let flags = packet[1]
        guard (flags & 0x80) == 0 else {
            statistics.transportErrors += 1
            return nil
        }
        let control = packet[3]
        let adaptationControl = (control >> 4) & 0x03
        guard adaptationControl != 0 else {
            statistics.malformed += 1
            return nil
        }
        var header = PacketHeader(
            pid: ByteField.u13(flags, packet[2]),
            unitStart: (flags & 0x40) != 0,
            continuityCounter: control & 0x0F,
            hasPayloadFlag: (adaptationControl & 0x01) != 0,
            isScrambled: (control >> 6) != 0,
            payloadStart: 4
        )
        if (adaptationControl & 0x02) != 0 {
            let length = Int(packet[4])
            let limit = header.hasPayloadFlag ? 182 : 183
            guard length <= limit else {
                statistics.malformed += 1
                return nil
            }
            if length > 0 {
                let afFlags = packet[5]
                header.discontinuityIndicator = (afFlags & 0x80) != 0
                header.randomAccess = (afFlags & 0x40) != 0
                if (afFlags & 0x10) != 0, length >= 7 {
                    header.pcr = ByteField.pcr(packet, at: 6)
                }
            }
            header.payloadStart = 5 + length
        }
        return header
    }

    private mutating func processPacket(_ packet: UnsafeBufferPointer<UInt8>, emit: (TSDemuxBorrowedEvent) -> Void) {
        statistics.packets += 1
        guard let header = parseHeader(packet), header.pid != Self.nullPID else { return }
        let pid = header.pid
        if let pcr = header.pcr {
            lastPCRs[pid] = pcr
        }
        var gap = false
        if header.hasPayloadFlag {
            let last = continuity[Int(pid)]
            if last != 0xFF, !header.discontinuityIndicator {
                if header.continuityCounter == last {
                    return  // A duplicate packet (13818-1 allows one); its payload was already used.
                }
                gap = header.continuityCounter != (last &+ 1) & 0x0F
            }
            continuity[Int(pid)] = header.continuityCounter
        }
        if gap {
            statistics.continuityErrors += 1
        }
        let slot = Int(pesSlot[Int(pid)])
        if slot >= 0, gap || header.discontinuityIndicator {
            emit(.discontinuity(pid: pid))
        }
        if header.isScrambled {
            statistics.scrambledPackets += 1
            if slot >= 0 { assemblers[slot].pendingDiscontinuity = true }
            return
        }
        let hasPayload = header.hasPayloadFlag && header.payloadStart < Self.packetSize
        let payload = UnsafeBufferPointer(rebasing: packet[min(header.payloadStart, Self.packetSize)...])
        if slot >= 0 {
            handlePES(slot: slot, header: header, payload: hasPayload ? payload : nil, gap: gap, emit: emit)
        } else if hasPayload {
            handlePSI(pid: pid, payload: payload, unitStart: header.unitStart, gap: gap, emit: emit)
        }
    }

    private mutating func handlePES(
        slot: Int,
        header: PacketHeader,
        payload: UnsafeBufferPointer<UInt8>?,
        gap: Bool,
        emit: (TSDemuxBorrowedEvent) -> Void
    ) {
        if header.unitStart, payload != nil {
            if assemblers[slot].isActive {
                if gap { assemblers[slot].isDiscontinuity = true }
                finishPES(slot: slot, emit: emit)
            }
            assemblers[slot].begin(randomAccess: header.randomAccess,
                                   discontinuity: gap || header.discontinuityIndicator)
        } else {
            guard assemblers[slot].isActive else {
                if gap || header.discontinuityIndicator { assemblers[slot].pendingDiscontinuity = true }
                return
            }
            if gap || header.discontinuityIndicator { assemblers[slot].isDiscontinuity = true }
            if header.randomAccess { assemblers[slot].isRandomAccess = true }
        }
        guard let payload else { return }
        switch assemblers[slot].append(payload, limit: Self.maximumPESSize) {
        case .partial:
            break
        case .complete:
            finishPES(slot: slot, emit: emit)
        case .overflow:
            statistics.oversizedPES += 1
            assemblers[slot].abandon()
            assemblers[slot].pendingDiscontinuity = true
        }
    }

    /// Parses the PES being assembled in `slot`, emits it (lending its payload) if valid and ends it.
    mutating func finishPES(slot: Int, emit: (TSDemuxBorrowedEvent) -> Void) {
        let header = assemblers[slot].buffer.withUnsafeBufferPointer { PESHeader.parse($0) }
        let pid = assemblers[slot].pid
        let program = assemblers[slot].programNumber
        let isRandomAccess = assemblers[slot].isRandomAccess
        let isDiscontinuity = assemblers[slot].isDiscontinuity
        guard let header else {
            assemblers[slot].abandon()
            statistics.malformedPES += 1
            assemblers[slot].pendingDiscontinuity = isDiscontinuity
            return
        }
        var reference = assemblers[slot].lastTimestamp ?? timelineReference[program]
        let dts = header.dts.map { raw in reference.map { Timestamp33.unwrap(raw, near: $0) } ?? raw }
        if let dts { reference = dts }
        let pts = header.pts.map { raw in reference.map { Timestamp33.unwrap(raw, near: $0) } ?? raw }
        if let latest = dts ?? pts {
            assemblers[slot].lastTimestamp = latest
            timelineReference[program] = latest
        }
        let packet = PESPacket(pid: pid, streamID: header.streamID, pts: pts, dts: dts, payload: Data(),
                               isRandomAccess: isRandomAccess, isDiscontinuity: isDiscontinuity)
        assemblers[slot].buffer.withUnsafeBufferPointer { bytes in
            emit(.pes(packet, payload: UnsafeBufferPointer(rebasing: bytes[header.payloadRange])))
        }
        assemblers[slot].abandon()
    }
}
