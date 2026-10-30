//
//  PESPacket.swift
//  MPEGTS
//
//  What the demuxer emits: program-table changes, reassembled PES packets and discontinuities, with PES payloads
//  either copied (`TSDemuxEvent`) or lent (`TSDemuxBorrowedEvent`).
//

import Foundation

/// One reassembled PES packet.
nonisolated public struct PESPacket: Sendable, Equatable {
    public var pid: UInt16
    public var streamID: UInt8
    /// Presentation timestamp in 90 kHz ticks. The 33-bit wrap is unwrapped into a monotonic timeline per PID.
    public var pts: Int64?
    /// Decode timestamp in 90 kHz ticks, unwrapped like `pts`. Nil when the header carries none, in which case the
    /// decode time equals `pts` (ISO/IEC 13818-1 §2.4.3.7).
    public var dts: Int64?
    /// The elementary-stream bytes after the PES header.
    public var payload: Data
    /// The adaptation field's random_access_indicator was set on a packet of this PES.
    public var isRandomAccess: Bool
    /// Data was lost in or immediately before this PES (a continuity-counter gap or an oversized PES that was
    /// dropped), or the adaptation field's discontinuity_indicator was set. Consumers should re-anchor their timeline.
    public var isDiscontinuity: Bool

    public init(
        pid: UInt16,
        streamID: UInt8,
        pts: Int64? = nil,
        dts: Int64? = nil,
        payload: Data,
        isRandomAccess: Bool = false,
        isDiscontinuity: Bool = false
    ) {
        self.pid = pid
        self.streamID = streamID
        self.pts = pts
        self.dts = dts
        self.payload = payload
        self.isRandomAccess = isRandomAccess
        self.isDiscontinuity = isDiscontinuity
    }
}

/// Events from `TSDemuxer.feed(_:)`, in stream order.
nonisolated public enum TSDemuxEvent: Sendable, Equatable {
    /// Every program whose PMT has been received, in PAT order. Emitted whenever that set or any PMT's content changes
    /// (only CRC-valid, current sections count).
    case programs([ProgramMap])
    /// A complete PES packet of an elementary stream listed in a PMT.
    case pes(PESPacket)
    /// A continuity-counter gap or a discontinuity_indicator on an elementary-stream PID.
    case discontinuity(pid: UInt16)
}

/// `TSDemuxEvent` with the PES payload lent instead of copied, from `TSDemuxer.feed(_:_:)` and `flush(_:)`.
nonisolated public enum TSDemuxBorrowedEvent {
    /// Every program whose PMT has been received, and every program the PAT lists (`listedProgramNumbers`).
    case programs([ProgramMap], listedProgramNumbers: [UInt16])
    /// A complete PES packet and its payload, which is valid only during the callback. The packet's own `payload`
    /// is empty.
    case pes(PESPacket, payload: UnsafeBufferPointer<UInt8>)
    case discontinuity(pid: UInt16)
}

extension TSDemuxEvent {
    /// The event with any PES payload copied.
    public init(_ event: TSDemuxBorrowedEvent) {
        switch event {
        case .programs(let programs, _):
            self = .programs(programs)
        case .pes(var packet, let payload):
            packet.payload = Data(buffer: payload)
            self = .pes(packet)
        case .discontinuity(let pid):
            self = .discontinuity(pid: pid)
        }
    }
}

/// Counters for the stats overlay and for tests. They only ever grow until `reset()`.
nonisolated public struct TSDemuxStatistics: Sendable, Equatable {
    /// 188-byte packets examined.
    public var packets = 0
    /// Times sync was lost after having been acquired.
    public var syncLosses = 0
    /// Bytes skipped while hunting for three consecutive sync bytes.
    public var skippedBytes = 0
    /// Packets with transport_error_indicator set (dropped).
    public var transportErrors = 0
    /// Continuity-counter gaps on any PID.
    public var continuityErrors = 0
    /// Packets with non-zero transport_scrambling_control (payload ignored).
    public var scrambledPackets = 0
    /// PSI sections that failed CRC-32.
    public var crcErrors = 0
    /// Packets or PSI sections with impossible lengths or layouts.
    public var malformed = 0
    /// PES packets whose header was missing or inconsistent (dropped).
    public var malformedPES = 0
    /// PES packets dropped for exceeding `TSDemuxer.maximumPESSize`.
    public var oversizedPES = 0

    public init() {}
}
