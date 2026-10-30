//
//  TSWriter.swift
//  MPEGTSTests
//
//  A synthetic transport-stream writer: PSI sections with CRC, PES headers with PTS/DTS, and packetization with
//  continuity counters, adaptation fields and stuffing. Written independently of the code under test (bitwise CRCs).
//

import Foundation

/// SplitMix64, so every "random" test input is reproducible.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var value = state
        value = (value ^ (value >> 30)) &* 0xBF58_476D_1CE4_E5B9
        value = (value ^ (value >> 27)) &* 0x94D0_49BB_1331_11EB
        return value ^ (value >> 31)
    }

    mutating func bytes(_ count: Int) -> [UInt8] {
        (0..<count).map { _ in UInt8.random(in: 0...255, using: &self) }
    }
}

/// Bitwise reference CRCs.
enum ReferenceCRC {
    static func crc32MPEG2(_ bytes: [UInt8]) -> UInt32 {
        var crc: UInt32 = 0xFFFF_FFFF
        for byte in bytes {
            crc ^= UInt32(byte) << 24
            for _ in 0..<8 {
                crc = (crc & 0x8000_0000) != 0 ? (crc << 1) ^ 0x04C1_1DB7 : crc << 1
            }
        }
        return crc
    }

    static func crc16(_ bytes: [UInt8]) -> UInt16 {
        var crc: UInt16 = 0
        for byte in bytes {
            crc ^= UInt16(byte) << 8
            for _ in 0..<8 {
                crc = (crc & 0x8000) != 0 ? (crc << 1) ^ 0x8005 : crc << 1
            }
        }
        return crc
    }
}

/// Packs big-endian bit fields.
struct BitWriter {
    private(set) var bytes: [UInt8] = []
    private var current: UInt8 = 0
    private var used = 0

    mutating func write(_ value: Int, bits: Int) {
        for shift in stride(from: bits - 1, through: 0, by: -1) {
            current = (current << 1) | UInt8((value >> shift) & 1)
            used += 1
            if used == 8 {
                bytes.append(current)
                current = 0
                used = 0
            }
        }
    }

    /// Pads the last byte with `fill` bits.
    mutating func finish(fill: Int = 0) -> [UInt8] {
        while used != 0 {
            write(fill, bits: 1)
        }
        return bytes
    }
}

struct AdaptationFlags {
    var randomAccess = false
    var discontinuity = false
    var pcr: Int64?
}

struct TSWriter {
    private(set) var bytes: [UInt8] = []
    private var counters: [UInt16: UInt8] = [:]

    /// Advances a PID's continuity counter without writing, to simulate a lost packet.
    mutating func losePacket(pid: UInt16) {
        counters[pid] = ((counters[pid] ?? 0x0F) &+ 1) & 0x0F
    }

    /// Writes a raw 188-byte packet as-is.
    mutating func raw(_ packet: [UInt8]) {
        bytes += packet
    }

    /// Splits `payload` into packets on `pid`. The first packet carries `unitStart` and `flags`; the last is padded
    /// with adaptation-field stuffing.
    mutating func packetize(pid: UInt16, payload: [UInt8], unitStart: Bool = true, flags: AdaptationFlags = .init()) {
        var offset = 0
        var first = true
        repeat {
            var body: [UInt8] = []
            if first {
                body = adaptationBody(flags)
            }
            let remaining = payload.count - offset
            var adaptation: [UInt8]?
            if !body.isEmpty {
                adaptation = [UInt8(body.count)] + body
            }
            let capacity = 184 - (adaptation?.count ?? 0)
            if remaining < capacity {
                let total = 184 - remaining
                if total == 1 {
                    adaptation = [0]
                } else {
                    var padded = body.isEmpty ? [0x00] : body
                    padded += [UInt8](repeating: 0xFF, count: total - 1 - padded.count)
                    adaptation = [UInt8(total - 1)] + padded
                }
            }
            let take = 184 - (adaptation?.count ?? 0)
            let chunk = Array(payload[offset..<(offset + take)])
            writePacket(pid: pid, unitStart: first && unitStart, adaptation: adaptation, payload: chunk)
            offset += take
            first = false
        } while offset < payload.count
    }

    /// Writes a PSI section with pointer_field 0, padded with 0xFF.
    mutating func section(pid: UInt16, _ section: [UInt8]) {
        var payload = [0x00] + section
        var first = true
        while !payload.isEmpty {
            var chunk = Array(payload.prefix(184))
            payload.removeFirst(chunk.count)
            chunk += [UInt8](repeating: 0xFF, count: 184 - chunk.count)
            writePacket(pid: pid, unitStart: first, adaptation: nil, payload: chunk)
            first = false
        }
    }

    mutating func writePacket(pid: UInt16, unitStart: Bool, adaptation: [UInt8]?, payload: [UInt8]) {
        let counter = ((counters[pid] ?? 0x0F) &+ (payload.isEmpty ? 0 : 1)) & 0x0F
        counters[pid] = counter
        let control = (adaptation != nil ? 0x20 : 0) | (payload.isEmpty ? 0 : 0x10)
        bytes += [0x47, (unitStart ? 0x40 : 0) | UInt8((pid >> 8) & 0x1F), UInt8(pid & 0xFF),
                  UInt8(control) | counter]
        bytes += adaptation ?? []
        bytes += payload
        precondition(bytes.count % 188 == 0, "packet must be 188 bytes")
    }

    private func adaptationBody(_ flags: AdaptationFlags) -> [UInt8] {
        var value: UInt8 = 0
        if flags.discontinuity { value |= 0x80 }
        if flags.randomAccess { value |= 0x40 }
        guard value != 0 || flags.pcr != nil else { return [] }
        var body = [value]
        if let pcr = flags.pcr {
            body[0] |= 0x10
            let base = pcr / 300
            let ext = pcr % 300
            body += [UInt8((base >> 25) & 0xFF), UInt8((base >> 17) & 0xFF), UInt8((base >> 9) & 0xFF),
                     UInt8((base >> 1) & 0xFF), UInt8(((base & 1) << 7) | 0x7E | ((ext >> 8) & 1)),
                     UInt8(ext & 0xFF)]
        }
        return body
    }
}
