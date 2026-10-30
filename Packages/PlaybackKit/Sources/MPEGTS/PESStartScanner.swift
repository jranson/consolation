//
//  PESStartScanner.swift
//  MPEGTS
//
//  Finds where one PID's PES packets start in a transport stream as it arrives, with their timestamps and whether
//  each one is a random-access point, without reassembling anything: what a time-shift buffer needs to map between
//  time and byte offsets. It reads only packet headers and, for the PID it watches, the first packet of each PES, so
//  it costs little per byte. Input may arrive in pieces of any size; positions are absolute byte offsets.
//

import Foundation

/// The start of one PES packet.
nonisolated public struct PESStart: Equatable, Sendable {
    /// The absolute offset of the transport packet that starts the PES (its sync byte).
    public var offset: Int64
    /// Unwrapped 90 kHz timestamps (monotonic across the 33-bit wrap, as the demuxer's are).
    public var pts: Int64?
    public var dts: Int64?
    /// The PES starts a random-access point: the adaptation field's random_access_indicator, or the start of its
    /// payload holds an MPEG-2 sequence header or I picture, an H.264 IDR picture or SPS, or an HEVC IRAP picture or
    /// parameter set.
    public var isRandomAccess: Bool

    public init(offset: Int64, pts: Int64?, dts: Int64?, isRandomAccess: Bool) {
        self.offset = offset
        self.pts = pts
        self.dts = dts
        self.isRandomAccess = isRandomAccess
    }
}

nonisolated public struct PESStartScanner {
    static let packetSize = 188

    /// The PID watched; nothing is reported until one is selected.
    public private(set) var pid: UInt16?
    /// Its codec, for recognising random-access points in the payload.
    public private(set) var kind: StreamKind?
    /// Where the next input is expected to start; input elsewhere drops the partial packet held.
    private var expectedOffset: Int64?
    /// The start of a packet split across inputs, and its absolute offset.
    private var carry: [UInt8] = []
    private var carryOffset: Int64 = 0
    private var lastTimestamp: Int64?

    public init() {}

    /// Watches `pid` from the next input on.
    public mutating func select(pid: UInt16, kind: StreamKind?) {
        if pid != self.pid { lastTimestamp = nil }
        self.pid = pid
        self.kind = kind
    }

    /// Forgets the partial packet held (the next input starts somewhere else).
    public mutating func resetPosition() {
        carry.removeAll(keepingCapacity: true)
        expectedOffset = nil
    }

    /// Scans `data`, which starts at absolute offset `offset`, and returns the PES starts in it (and in a packet
    /// completed by it).
    public mutating func scan(_ data: Data, at offset: Int64) -> [PESStart] {
        if expectedOffset != offset { carry.removeAll(keepingCapacity: true) }
        expectedOffset = offset + Int64(data.count)
        guard pid != nil else { return [] }
        var found: [PESStart] = []
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            var position = 0
            if !carry.isEmpty {
                let needed = Self.packetSize - carry.count
                guard bytes.count >= needed else {
                    carry.append(contentsOf: bytes)
                    return
                }
                carry.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[0..<needed]))
                let packet = carry
                packet.withUnsafeBufferPointer { inspect($0, at: carryOffset, into: &found) }
                carry.removeAll(keepingCapacity: true)
                position = needed
            }
            while position + Self.packetSize <= bytes.count {
                guard bytes[position] == 0x47 else {
                    position = Self.nextSync(in: bytes, after: position)
                    continue
                }
                inspect(UnsafeBufferPointer(rebasing: bytes[position..<(position + Self.packetSize)]),
                        at: offset + Int64(position), into: &found)
                position += Self.packetSize
            }
            if position < bytes.count, bytes[position] == 0x47 {
                carry.append(contentsOf: UnsafeBufferPointer(rebasing: bytes[position...]))
                carryOffset = offset + Int64(position)
            }
        }
        return found
    }

    /// The next likely packet start after `position`: a sync byte with another 188 bytes on, or at the end.
    private static func nextSync(in bytes: UnsafeBufferPointer<UInt8>, after position: Int) -> Int {
        var index = position + 1
        while index < bytes.count {
            if bytes[index] == 0x47, index + packetSize >= bytes.count || bytes[index + packetSize] == 0x47 {
                return index
            }
            index += 1
        }
        return bytes.count
    }

    /// Reports the packet if it starts a PES on the watched PID.
    private mutating func inspect(_ packet: UnsafeBufferPointer<UInt8>, at offset: Int64,
                                  into found: inout [PESStart]) {
        let flags = packet[1]
        let control = packet[3]
        guard (flags & 0xC0) == 0x40, ByteField.u13(flags, packet[2]) == pid, (control & 0x10) != 0,
              (control >> 6) == 0 else { return }
        var start = 4
        var randomAccess = false
        if (control & 0x20) != 0 {
            let length = Int(packet[4])
            guard length <= 182 else { return }
            if length > 0 { randomAccess = (packet[5] & 0x40) != 0 }
            start = 5 + length
        }
        guard start + 9 <= packet.count, packet[start] == 0, packet[start + 1] == 0, packet[start + 2] == 1,
              (packet[start + 6] & 0xC0) == 0x80 else { return }
        let timestampFlags = (packet[start + 7] >> 6) & 0x03
        let headerLength = Int(packet[start + 8])
        let payloadStart = start + 9 + headerLength
        guard payloadStart <= packet.count else { return }
        let rawPTS = (timestampFlags & 0x02) != 0 && headerLength >= 5 ? ByteField.timestamp(packet, at: start + 9)
            : nil
        let rawDTS = timestampFlags == 0x03 && headerLength >= 10 ? ByteField.timestamp(packet, at: start + 14) : nil
        var reference = lastTimestamp
        let dts = rawDTS.map { raw in reference.map { Timestamp33.unwrap(raw, near: $0) } ?? raw }
        if let dts { reference = dts }
        let pts = rawPTS.map { raw in reference.map { Timestamp33.unwrap(raw, near: $0) } ?? raw }
        lastTimestamp = dts ?? pts ?? lastTimestamp
        let payload = UnsafeBufferPointer(rebasing: packet[payloadStart...])
        found.append(PESStart(offset: offset, pts: pts, dts: dts,
                              isRandomAccess: randomAccess || Self.startsRandomAccess(payload, kind: kind)))
    }

    /// Whether the start of a video PES payload shows a random-access point, from the first start code that
    /// decides it.
    static func startsRandomAccess(_ payload: UnsafeBufferPointer<UInt8>, kind: StreamKind?) -> Bool {
        guard let kind, payload.count >= 4 else { return false }
        var index = 0
        while index + 3 < payload.count {
            guard payload[index] == 0, payload[index + 1] == 0, payload[index + 2] == 1 else {
                index += 1
                continue
            }
            if let verdict = verdict(payload, startCodeAt: index, kind: kind) { return verdict }
            index += 3
        }
        return false
    }

    /// What the start code at `index` says: a random-access point (true), not one (false), or nothing yet (nil).
    private static func verdict(_ payload: UnsafeBufferPointer<UInt8>, startCodeAt index: Int,
                                kind: StreamKind) -> Bool? {
        let code = payload[index + 3]
        switch kind {
        case .mpeg2Video:
            if code == 0xB3 { return true }
            guard code == 0x00 else { return nil }
            // The picture header: picture_coding_type follows the 10-bit temporal reference.
            guard index + 5 < payload.count else { return false }
            return (payload[index + 5] >> 3) & 0x07 == 1
        case .h264:
            switch code & 0x1F {
            case 5, 7: return true
            case 1: return false
            default: return nil
            }
        case .hevc:
            switch (code >> 1) & 0x3F {
            case 16...21, 32...34: return true
            case 0...9: return false
            default: return nil
            }
        default:
            return false
        }
    }
}
