//
//  PESAssembler.swift
//  MPEGTS
//
//  Per-PID PES reassembly. A PES starts only on payload_unit_start_indicator (never on a `00 00 01` pattern in the
//  payload), ends at the next start or when PES_packet_length bytes have arrived, and is capped in size.
//

nonisolated struct PESAssembler {
    enum AppendResult {
        case partial
        case complete
        case overflow
    }

    let pid: UInt16
    /// The first program listing this PID; timestamps of PIDs in the same program share an unwrap anchor.
    var programNumber: UInt16
    private(set) var buffer: [UInt8] = []
    private(set) var isActive = false
    /// 6 + PES_packet_length once known; 0 while unknown; -1 for an unbounded (length 0) video PES.
    private var declaredSize = 0
    var isRandomAccess = false
    var isDiscontinuity = false
    /// Set when data was lost while no PES was active; applied to the next PES.
    var pendingDiscontinuity = false
    /// The last unwrapped timestamp on this PID.
    var lastTimestamp: Int64?

    init(pid: UInt16, programNumber: UInt16) {
        self.pid = pid
        self.programNumber = programNumber
    }

    mutating func begin(randomAccess: Bool, discontinuity: Bool) {
        buffer.removeAll(keepingCapacity: true)
        declaredSize = 0
        isActive = true
        isRandomAccess = randomAccess
        isDiscontinuity = discontinuity || pendingDiscontinuity
        pendingDiscontinuity = false
    }

    mutating func append(_ bytes: UnsafeBufferPointer<UInt8>, limit: Int) -> AppendResult {
        guard buffer.count + bytes.count <= limit else { return .overflow }
        buffer.append(contentsOf: bytes)
        if declaredSize == 0, buffer.count >= 6 {
            let length = ByteField.u16(buffer[4], buffer[5])
            declaredSize = length > 0 ? 6 + length : -1
        }
        if declaredSize > 0, buffer.count >= declaredSize {
            return .complete
        }
        return .partial
    }

    /// Ends the current PES without emitting it.
    mutating func abandon() {
        buffer.removeAll(keepingCapacity: true)
        declaredSize = 0
        isActive = false
        isRandomAccess = false
        isDiscontinuity = false
    }
}

/// The fields of a PES header (ISO/IEC 13818-1 §2.4.3.6) that the demuxer uses.
nonisolated struct PESHeader: Equatable {
    var streamID: UInt8
    /// Raw 33-bit values.
    var pts: Int64?
    var dts: Int64?
    var payloadRange: Range<Int>

    /// Stream IDs without the optional PES header (program_stream_map, padding, private_stream_2, ECM, EMM,
    /// DSMCC, H.222.1 type E and the directory).
    private static func hasOptionalHeader(_ streamID: UInt8) -> Bool {
        switch streamID {
        case 0xBC, 0xBE, 0xBF, 0xF0, 0xF1, 0xF2, 0xF8, 0xFF: false
        default: true
        }
    }

    /// Parses a reassembled PES. The flags are in byte 7, the header length in byte 8, the PTS at byte 9 and the
    /// DTS at byte 14. Returns nil for anything inconsistent.
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> PESHeader? {
        guard bytes.count >= 6, bytes[0] == 0, bytes[1] == 0, bytes[2] == 1, bytes[3] >= 0xBC else { return nil }
        let streamID = bytes[3]
        let packetLength = ByteField.u16(bytes[4], bytes[5])
        let end = packetLength > 0 ? min(bytes.count, 6 + packetLength) : bytes.count
        guard hasOptionalHeader(streamID) else {
            return PESHeader(streamID: streamID, payloadRange: 6..<end)
        }
        guard end >= 9, (bytes[6] & 0xC0) == 0x80 else { return nil }
        let flags = (bytes[7] >> 6) & 0x03
        let headerLength = Int(bytes[8])
        let payloadStart = 9 + headerLength
        guard payloadStart <= end else { return nil }
        var header = PESHeader(streamID: streamID, payloadRange: payloadStart..<end)
        if (flags & 0x02) != 0, headerLength >= 5 {
            header.pts = ByteField.timestamp(bytes, at: 9)
        }
        if flags == 0x03, headerLength >= 10 {
            header.dts = ByteField.timestamp(bytes, at: 14)
        }
        return header
    }
}

/// 33-bit, 90 kHz timestamp arithmetic.
nonisolated public enum Timestamp33 {
    public static let period: Int64 = 1 << 33

    /// The value congruent to `raw` modulo 2^33 that is closest to `reference`. Unwrapping each timestamp against
    /// the previous one turns the 26.5-hour wrap into a monotonic 64-bit timeline, while small backward steps
    /// (B-picture PTS) stay small.
    public static func unwrap(_ raw: Int64, near reference: Int64) -> Int64 {
        var delta = (raw - reference) & (period - 1)
        if delta >= period / 2 {
            delta -= period
        }
        return reference + delta
    }

    /// `later - earlier` in ticks, for two timestamps that may have been unwrapped against different references
    /// (they differ by a multiple of 2^33): the difference closest to zero.
    public static func ticks(from earlier: Int64, to later: Int64) -> Int64 {
        unwrap(later, near: earlier) - earlier
    }
}
