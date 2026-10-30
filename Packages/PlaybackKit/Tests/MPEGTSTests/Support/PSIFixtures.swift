//
//  PSIFixtures.swift
//  MPEGTSTests
//
//  Synthetic PAT/PMT sections, descriptors and PES packets.
//

import Foundation

struct StreamSpec {
    var streamType: UInt8
    var pid: UInt16
    var descriptors: [UInt8] = []
}

enum PSIFixtures {
    static func longSection(
        tableID: UInt8,
        tableIDExtension: UInt16,
        version: UInt8 = 0,
        current: Bool = true,
        sectionNumber: UInt8 = 0,
        lastSectionNumber: UInt8 = 0,
        body: [UInt8]
    ) -> [UInt8] {
        let length = 5 + body.count + 4
        var section: [UInt8] = [
            tableID, 0xB0 | UInt8((length >> 8) & 0x0F), UInt8(length & 0xFF),
            UInt8(tableIDExtension >> 8), UInt8(tableIDExtension & 0xFF),
            0xC0 | ((version & 0x1F) << 1) | (current ? 1 : 0), sectionNumber, lastSectionNumber
        ]
        section += body
        let crc = ReferenceCRC.crc32MPEG2(section)
        section += [UInt8(crc >> 24), UInt8((crc >> 16) & 0xFF), UInt8((crc >> 8) & 0xFF), UInt8(crc & 0xFF)]
        return section
    }

    /// A PAT. Reserved bits are set as on air (`0xE0 | pid >> 8`), which is what a precedence bug trips on.
    static func pat(
        transportStreamID: UInt16 = 0x0801,
        version: UInt8 = 0,
        programs: [(number: UInt16, pmtPID: UInt16)],
        sectionNumber: UInt8 = 0,
        lastSectionNumber: UInt8 = 0
    ) -> [UInt8] {
        var body: [UInt8] = []
        for program in programs {
            body += [UInt8(program.number >> 8), UInt8(program.number & 0xFF),
                     0xE0 | UInt8(program.pmtPID >> 8), UInt8(program.pmtPID & 0xFF)]
        }
        return longSection(tableID: 0x00, tableIDExtension: transportStreamID, version: version,
                           sectionNumber: sectionNumber, lastSectionNumber: lastSectionNumber, body: body)
    }

    static func pmt(
        program: UInt16,
        version: UInt8 = 0,
        pcrPID: UInt16,
        programInfo: [UInt8] = [],
        streams: [StreamSpec]
    ) -> [UInt8] {
        var body: [UInt8] = [
            0xE0 | UInt8(pcrPID >> 8), UInt8(pcrPID & 0xFF),
            0xF0 | UInt8(programInfo.count >> 8), UInt8(programInfo.count & 0xFF)
        ]
        body += programInfo
        for stream in streams {
            body += [stream.streamType, 0xE0 | UInt8(stream.pid >> 8), UInt8(stream.pid & 0xFF),
                     0xF0 | UInt8(stream.descriptors.count >> 8), UInt8(stream.descriptors.count & 0xFF)]
            body += stream.descriptors
        }
        return longSection(tableID: 0x02, tableIDExtension: program, version: version, body: body)
    }

    static func language(_ code: String, audioType: UInt8 = 0) -> [UInt8] {
        [0x0A, 4] + Array(code.utf8) + [audioType]
    }

    static func registration(_ format: String) -> [UInt8] {
        [0x05, 4] + Array(format.utf8)
    }

    /// ATSC AC-3_audio_stream_descriptor with the given num_channels code (48 kHz, bsid 8).
    static func atscAC3(numChannels: Int) -> [UInt8] {
        [0x81, 3, 0x08, 0x38, UInt8((numChannels & 0x0F) << 1) | 0x01]
    }

    /// The 9.1-style program: MPEG-2 video on 0x31, AC-3 eng 5.1 on 0x34 and spa 2.0 on 0x35.
    static func broadcastStreams() -> [StreamSpec] {
        [
            StreamSpec(streamType: 0x02, pid: 0x31, descriptors: [0x06, 0x01, 0x02]),
            StreamSpec(streamType: 0x81, pid: 0x34,
                       descriptors: registration("AC-3") + atscAC3(numChannels: 7) + language("eng")),
            StreamSpec(streamType: 0x81, pid: 0x35,
                       descriptors: registration("AC-3") + atscAC3(numChannels: 2) + language("spa"))
        ]
    }

    static func timestamp(prefix: UInt8, _ value: Int64) -> [UInt8] {
        let masked = value & ((1 << 33) - 1)
        return [
            (prefix << 4) | UInt8((masked >> 29) & 0x0E) | 0x01,
            UInt8((masked >> 22) & 0xFF),
            UInt8((masked >> 14) & 0xFE) | 0x01,
            UInt8((masked >> 7) & 0xFF),
            UInt8((masked << 1) & 0xFE) | 0x01
        ]
    }

    /// A PES packet. `bounded` writes PES_packet_length; otherwise 0, as for broadcast video.
    static func pes(streamID: UInt8, pts: Int64?, dts: Int64? = nil, payload: [UInt8], bounded: Bool) -> [UInt8] {
        var optional: [UInt8] = []
        var flags: UInt8 = 0
        if let pts {
            flags = dts == nil ? 0x80 : 0xC0
            optional += timestamp(prefix: dts == nil ? 0x2 : 0x3, pts)
            if let dts {
                optional += timestamp(prefix: 0x1, dts)
            }
        }
        let header: [UInt8] = [0x80, flags, UInt8(optional.count)] + optional
        let length = bounded ? header.count + payload.count : 0
        return [0x00, 0x00, 0x01, streamID, UInt8((length >> 8) & 0xFF), UInt8(length & 0xFF)] + header + payload
    }
}
