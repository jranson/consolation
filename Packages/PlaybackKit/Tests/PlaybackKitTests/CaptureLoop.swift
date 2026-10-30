//
//  CaptureLoop.swift
//  PlaybackKitTests
//
//  Replays a short transport stream capture as one endless live stream for the performance harness: every pass
//  shifts PCR, PTS and DTS by the capture's duration and carries each PID's continuity counter on, so the engine
//  sees a continuous broadcast instead of a jump back in time (and a decoder restart) every few seconds.
//

import Foundation

nonisolated struct CaptureLoop: Sendable {
    static let packetSize = 188

    /// Whole packets of the capture.
    let data: Data
    /// 90 kHz ticks one pass covers, extrapolated from the PCRs to the whole capture.
    let duration: Int64
    /// The capture's own rate (from its PCRs), at which a tuner would deliver it.
    let bytesPerSecond: Double
    /// Per PID: how far the continuity counter advances over one pass.
    private let continuitySteps: [UInt8]

    init?(data source: Data) {
        let packets = source.count / Self.packetSize
        guard packets > 2 else { return nil }
        data = source.prefix(packets * Self.packetSize)
        var firstPCR: (offset: Int, base: Int64)?
        var lastPCR: (offset: Int, base: Int64)?
        var firstCC = [Int](repeating: -1, count: 8_192)
        var lastCC = [Int](repeating: -1, count: 8_192)
        data.withUnsafeBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count, by: Self.packetSize) {
                let packet = UnsafeBufferPointer(rebasing: bytes[offset..<(offset + Self.packetSize)])
                let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
                if (packet[3] & 0x10) != 0 {
                    if firstCC[pid] < 0 { firstCC[pid] = Int(packet[3] & 0x0F) }
                    lastCC[pid] = Int(packet[3] & 0x0F)
                }
                if let base = Self.pcrBase(packet) {
                    if firstPCR == nil { firstPCR = (offset, base) }
                    lastPCR = (offset, base)
                }
            }
        }
        guard let firstPCR, let lastPCR, lastPCR.offset > firstPCR.offset, lastPCR.base > firstPCR.base else {
            return nil
        }
        let ticksPerByte = Double(lastPCR.base - firstPCR.base) / Double(lastPCR.offset - firstPCR.offset)
        duration = Int64((ticksPerByte * Double(data.count)).rounded())
        bytesPerSecond = 90_000 / ticksPerByte
        continuitySteps = zip(firstCC, lastCC).map { first, last in
            first < 0 ? 0 : UInt8((last + 1 - first) & 0x0F)
        }
    }

    /// Bytes `range` (whole packets) of pass `pass`, with continuity counters carried on, and timestamps too unless
    /// `shiftsTimestamps` is false (then each pass jumps back in time with no continuity break to flag it).
    func bytes(_ range: Range<Int>, pass: Int, shiftsTimestamps: Bool = true) -> Data {
        var chunk = data.subdata(in: range)
        guard pass > 0 else { return chunk }
        let shift = shiftsTimestamps ? Int64(pass) * duration : 0
        chunk.withUnsafeMutableBytes { raw in
            let bytes = raw.bindMemory(to: UInt8.self)
            for offset in stride(from: 0, to: bytes.count - Self.packetSize + 1, by: Self.packetSize) {
                let packet = UnsafeMutableBufferPointer(rebasing: bytes[offset..<(offset + Self.packetSize)])
                patch(packet, pass: pass, shift: shift)
            }
        }
        return chunk
    }

    private func patch(_ packet: UnsafeMutableBufferPointer<UInt8>, pass: Int, shift: Int64) {
        let pid = Int(packet[1] & 0x1F) << 8 | Int(packet[2])
        let hasPayload = (packet[3] & 0x10) != 0
        if hasPayload {
            let counter = (Int(packet[3] & 0x0F) + pass * Int(continuitySteps[pid])) & 0x0F
            packet[3] = (packet[3] & 0xF0) | UInt8(counter)
        }
        guard shift != 0 else { return }
        if let base = Self.pcrBase(UnsafeBufferPointer(packet)) {
            let shifted = (base + shift) & Self.timestampMask
            packet[6] = UInt8(truncatingIfNeeded: shifted >> 25)
            packet[7] = UInt8(truncatingIfNeeded: shifted >> 17)
            packet[8] = UInt8(truncatingIfNeeded: shifted >> 9)
            packet[9] = UInt8(truncatingIfNeeded: shifted >> 1)
            packet[10] = UInt8(truncatingIfNeeded: (shifted & 1) << 7) | (packet[10] & 0x7F)
        }
        guard hasPayload, (packet[1] & 0x40) != 0 else { return }
        let start = (packet[3] & 0x20) != 0 ? 5 + Int(packet[4]) : 4
        guard start + 19 <= Self.packetSize, packet[start] == 0, packet[start + 1] == 0, packet[start + 2] == 1,
              packet[start + 3] >= 0xBC, (packet[start + 6] & 0xC0) == 0x80 else { return }
        let flags = (packet[start + 7] >> 6) & 0x03
        if (flags & 0x02) != 0 { Self.shiftTimestamp(packet, at: start + 9, by: shift) }
        if flags == 0x03 { Self.shiftTimestamp(packet, at: start + 14, by: shift) }
    }

    private static let timestampMask: Int64 = (1 << 33) - 1

    private static func pcrBase(_ packet: UnsafeBufferPointer<UInt8>) -> Int64? {
        guard (packet[3] & 0x20) != 0, packet[4] >= 7, (packet[5] & 0x10) != 0 else { return nil }
        return Int64(packet[6]) << 25 | Int64(packet[7]) << 17 | Int64(packet[8]) << 9 | Int64(packet[9]) << 1
            | Int64(packet[10] >> 7)
    }

    private static func shiftTimestamp(_ packet: UnsafeMutableBufferPointer<UInt8>, at index: Int, by shift: Int64) {
        let raw = Int64((packet[index] >> 1) & 0x07) << 30 | Int64(packet[index + 1]) << 22
            | Int64(packet[index + 2] >> 1) << 15 | Int64(packet[index + 3]) << 7 | Int64(packet[index + 4] >> 1)
        let value = (raw + shift) & timestampMask
        packet[index] = (packet[index] & 0xF0) | UInt8(truncatingIfNeeded: (value >> 29) & 0x0E) | 1
        packet[index + 1] = UInt8(truncatingIfNeeded: value >> 22)
        packet[index + 2] = UInt8(truncatingIfNeeded: (value >> 14) & 0xFE) | 1
        packet[index + 3] = UInt8(truncatingIfNeeded: value >> 7)
        packet[index + 4] = UInt8(truncatingIfNeeded: (value << 1) & 0xFE) | 1
    }
}
