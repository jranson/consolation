#!/usr/bin/env swift
//
// ts-fixture-tool.swift
//
// Helpers for scripts/make-test-fixtures.sh. Byte surgery that FFmpeg can't do, written from the specs
// (ISO/IEC 13818-1 and -2, ATSC A/53 Part 4, CEA-608), never from FFmpeg's or any other GPL/LGPL code:
//
//   swift scripts/ts-fixture-tool.swift captions <in.m2v> <out.m2v>
//       Adds A/53 GA94 cc_data user data to every picture of an MPEG-2 elementary stream: a CEA-608 CC1 pop-on
//       caption "GOLDEN 608", one byte pair per picture in display order (by temporal_reference), so a decoder
//       must reorder coded-order cc_data by PTS to read it.
//   swift scripts/ts-fixture-tool.swift splice <a.ts> <b.ts> <out.ts>
//       Concatenates two transport streams and sets discontinuity_indicator on the first packet of every PID in
//       <b> that has an adaptation field, like a signalled splice.
//   swift scripts/ts-fixture-tool.swift excerpt <in.ts> <out.ts> <packets>
//       A header-only excerpt of the first <packets> packets of a real capture: PAT and PMT sections, and for every
//       PES that starts in the window its TS header, adaptation field (PCR) and PES header (PTS/DTS); MPEG-2 video
//       keeps only its sequence, extension, GOP and picture headers, AC-3 only its 8-byte sync info and BSI start.
//       Every picture, audio and caption byte is zeroed and the rest of each PES is dropped. PSIP (0x1FFB), null
//       packets and any other PID are dropped, so no guide text or station data is kept. Continuity counters are
//       renumbered so the excerpt demuxes cleanly.

import Foundation

let packetSize = 188

func fail(_ message: String) -> Never {
    FileHandle.standardError.write(Data((message + "\n").utf8))
    exit(1)
}

func read(_ path: String) -> [UInt8] {
    guard let data = FileManager.default.contents(atPath: path) else { fail("can't read \(path)") }
    return [UInt8](data)
}

func write(_ bytes: [UInt8], to path: String) {
    guard FileManager.default.createFile(atPath: path, contents: Data(bytes)) else { fail("can't write \(path)") }
}

// MARK: - captions

/// CEA-608 bytes carry odd parity in bit 7.
func odd(_ byte: UInt8) -> UInt8 {
    let low = byte & 0x7F
    return low.nonzeroBitCount % 2 == 1 ? low : low | 0x80
}

/// The CC1 pairs, one per displayed picture: a pop-on caption on row 15.
func captionPairs() -> [(UInt8, UInt8)] {
    let rcl: (UInt8, UInt8) = (0x14, 0x20), enm: (UInt8, UInt8) = (0x14, 0x2E), eoc: (UInt8, UInt8) = (0x14, 0x2F)
    let pac: (UInt8, UInt8) = (0x14, 0x60)  // row 15, column 0, white
    var pairs = [rcl, rcl, enm, enm, pac, pac]
    let text = Array("GOLDEN 608".utf8)
    for index in stride(from: 0, to: text.count, by: 2) {
        pairs.append((text[index], index + 1 < text.count ? text[index + 1] : 0))
    }
    pairs += [eoc, eoc]
    return pairs.map { (odd($0.0), odd($0.1)) }
}

/// GA94 user data for one picture: 20 triplets (the A/53 count at 29.97 Hz), CC1 first, a null field 2 pair, then
/// DTVCC padding.
func userData(pair: (UInt8, UInt8)) -> [UInt8] {
    let count = 20
    var bytes: [UInt8] = [0x00, 0x00, 0x01, 0xB2, 0x47, 0x41, 0x39, 0x34, 0x03, 0xC0 | UInt8(count), 0xFF]
    bytes += [0xFC, pair.0, pair.1, 0xFD, 0x80, 0x80]
    for _ in 2..<count { bytes += [0xFA, 0x00, 0x00] }
    bytes.append(0xFF)
    return bytes
}

/// Offsets of every `00 00 01 xx` start code (the offset of the first zero).
func startCodes(_ bytes: [UInt8]) -> [Int] {
    var result: [Int] = []
    var index = 0
    while index + 3 < bytes.count {
        if bytes[index] == 0, bytes[index + 1] == 0, bytes[index + 2] == 1 {
            result.append(index)
            index += 3
        } else {
            index += 1
        }
    }
    return result
}

func addCaptions(_ input: [UInt8]) -> [UInt8] {
    let pairs = captionPairs()
    let codes = startCodes(input)
    var output: [UInt8] = []
    var gopBase = 0, picturesInGOP = 0, pendingDisplay: Int?
    var copied = 0
    for offset in codes {
        let code = input[offset + 3]
        if let display = pendingDisplay, code != 0xB5 {
            // The picture's headers and extensions end here: user data goes before its first slice.
            output += input[copied..<offset]
            copied = offset
            output += userData(pair: display < pairs.count ? pairs[display] : (0x80, 0x80))
            pendingDisplay = nil
        }
        switch code {
        case 0xB8:
            gopBase += picturesInGOP
            picturesInGOP = 0
        case 0x00:
            let reference = Int(input[offset + 4]) << 2 | Int(input[offset + 5]) >> 6
            pendingDisplay = gopBase + reference
            picturesInGOP += 1
        default:
            break
        }
    }
    output += input[copied...]
    return output
}

// MARK: - transport stream helpers

struct Packet {
    var bytes: [UInt8]
    var pid: Int { Int(bytes[1] & 0x1F) << 8 | Int(bytes[2]) }
    var unitStart: Bool { bytes[1] & 0x40 != 0 }
    var hasAdaptation: Bool { bytes[3] & 0x20 != 0 }
    var hasPayload: Bool { bytes[3] & 0x10 != 0 }
    var payloadStart: Int { hasAdaptation ? 5 + Int(bytes[4]) : 4 }
    var counter: UInt8 {
        get { bytes[3] & 0x0F }
        set { bytes[3] = (bytes[3] & 0xF0) | (newValue & 0x0F) }
    }
}

/// The 188-byte packets from the first offset with three sync bytes in a row; a trailing partial packet is dropped.
func packets(_ bytes: [UInt8]) -> [Packet] {
    guard let first = (0..<min(packetSize, bytes.count)).first(where: { offset in
        (0..<3).allSatisfy { offset + $0 * packetSize < bytes.count && bytes[offset + $0 * packetSize] == 0x47 }
    }) else { fail("no transport stream sync") }
    let end = first + (bytes.count - first) / packetSize * packetSize
    return stride(from: first, to: end, by: packetSize).map { Packet(bytes: Array(bytes[$0..<($0 + packetSize)])) }
}

func splice(_ first: [UInt8], _ second: [UInt8]) -> [UInt8] {
    var marked: Set<Int> = []
    var tail = packets(second)
    for index in tail.indices where !marked.contains(tail[index].pid) && tail[index].hasAdaptation {
        guard tail[index].bytes[4] > 0 else { continue }
        tail[index].bytes[5] |= 0x80
        marked.insert(tail[index].pid)
    }
    return first + tail.flatMap(\.bytes)
}

// MARK: - excerpt

/// PMT PIDs from PAT sections and elementary PIDs with their stream types from PMT sections.
struct ProgramTables {
    var pmtPIDs: Set<Int> = []
    var streams: [Int: UInt8] = [:]

    mutating func learn(_ packet: Packet) {
        guard packet.unitStart, packet.hasPayload else { return }
        let start = packet.payloadStart + 1 + Int(packet.bytes[packet.payloadStart])
        let body = Array(packet.bytes[start...])
        guard body.count > 12 else { return }
        let length = min(Int(body[1] & 0x0F) << 8 | Int(body[2]), body.count - 3)
        if packet.pid == 0, body[0] == 0x00 {
            for entry in stride(from: 8, to: 3 + length - 4 - 3, by: 4) where body[entry] != 0 || body[entry + 1] != 0 {
                pmtPIDs.insert(Int(body[entry + 2] & 0x1F) << 8 | Int(body[entry + 3]))
            }
        } else if pmtPIDs.contains(packet.pid), body[0] == 0x02 {
            var entry = 12 + (Int(body[10] & 0x0F) << 8 | Int(body[11]))
            while entry + 5 <= 3 + length - 4 {
                streams[Int(body[entry + 1] & 0x1F) << 8 | Int(body[entry + 2])] = body[entry]
                entry += 5 + (Int(body[entry + 3] & 0x0F) << 8 | Int(body[entry + 4]))
            }
        }
    }
}

/// Zeroes a video PES from its first start code that is not a sequence, extension, GOP or picture header. Returns
/// true once that point was found (the rest of the PES is dropped).
func stripVideo(_ packet: inout Packet, from start: Int, previous: inout Packet?) -> Bool {
    var index = start
    while index < packetSize {
        // A start code may begin in the previous kept packet of this PES.
        let zeroes = (1...3).map { back -> UInt8? in
            let position = index - back
            if position >= start { return packet.bytes[position] }
            let earlier = packetSize - (start - position)
            return previous.map { $0.bytes[earlier] }
        }
        if zeroes[0] == 1, zeroes[1] == 0, zeroes[2] == 0, ![0x00, 0xB3, 0xB5, 0xB8].contains(packet.bytes[index]) {
            for back in 1...3 {
                let position = index - back
                if position >= start {
                    packet.bytes[position] = 0
                } else {
                    previous?.bytes[packetSize - start + position] = 0
                }
            }
            for position in index..<packetSize { packet.bytes[position] = 0 }
            return true
        }
        index += 1
    }
    return false
}

/// Keeps the PES header and an AC-3 frame's first 8 bytes, zeroes the rest and ends the PES in this packet.
func stripAudio(_ packet: inout Packet) {
    let pes = packet.payloadStart
    guard packet.bytes[pes] == 0, packet.bytes[pes + 1] == 0, packet.bytes[pes + 2] == 1 else { return }
    let headerEnd = pes + 9 + Int(packet.bytes[pes + 8])
    let keep = packet.bytes[headerEnd] == 0x0B && packet.bytes[headerEnd + 1] == 0x77 ? 8 : 0
    for position in (headerEnd + keep)..<packetSize { packet.bytes[position] = 0 }
    let length = packetSize - (pes + 6)
    packet.bytes[pes + 4] = UInt8(length >> 8)
    packet.bytes[pes + 5] = UInt8(length & 0xFF)
}

func excerpt(_ input: [UInt8], packets limit: Int) -> [UInt8] {
    var tables = ProgramTables()
    var output: [Packet] = []
    var counters: [Int: UInt8] = [:]
    /// Per video PID: the index in `output` of the last kept packet of a PES still being stripped.
    var openVideo: [Int: Int] = [:]
    for var packet in packets(input).prefix(limit) where packet.bytes[1] & 0x80 == 0 {
        let pid = packet.pid
        tables.learn(packet)
        var keep = pid == 0 || tables.pmtPIDs.contains(pid)
        if !keep, let type = tables.streams[pid], packet.hasPayload {
            if type == 0x02 {
                if packet.unitStart {
                    openVideo[pid] = -1
                }
                if let last = openVideo[pid] {
                    let pes = packet.payloadStart
                    let start = packet.unitStart ? pes + 9 + Int(packet.bytes[pes + 8]) : pes
                    var previous = last >= 0 ? output[last] : nil
                    let done = stripVideo(&packet, from: start, previous: &previous)
                    if last >= 0, let previous { output[last] = previous }
                    keep = true
                    openVideo[pid] = done ? nil : output.count
                }
            } else if packet.unitStart, type == 0x81 || type == 0x06 {
                stripAudio(&packet)
                keep = true
            }
        }
        guard keep else { continue }
        let next = ((counters[pid] ?? 0x0F) &+ 1) & 0x0F
        counters[pid] = next
        packet.counter = next
        output.append(packet)
    }
    return output.flatMap(\.bytes)
}

// MARK: - main

let arguments = CommandLine.arguments.dropFirst()
switch arguments.first {
case "captions" where arguments.count == 3:
    let paths = Array(arguments.dropFirst())
    write(addCaptions(read(paths[0])), to: paths[1])
case "splice" where arguments.count == 4:
    let paths = Array(arguments.dropFirst())
    write(splice(read(paths[0]), read(paths[1])), to: paths[2])
case "excerpt" where arguments.count == 4:
    let paths = Array(arguments.dropFirst())
    guard let limit = Int(paths[2]) else { fail("packets must be a number") }
    write(excerpt(read(paths[0]), packets: limit), to: paths[1])
default:
    fail("usage: ts-fixture-tool.swift captions|splice|excerpt …")
}
