//
//  PSIParser.swift
//  MPEGTS
//
//  Parses complete PAT and PMT sections (ISO/IEC 13818-1 §2.4.4). Sections arrive whole from `SectionAssembler`;
//  every length is checked against the section bounds and every section must pass CRC-32/MPEG-2.
//

/// The long-form section header shared by the PAT and PMT.
nonisolated struct PSIHeader: Equatable {
    var tableID: UInt8
    var sectionLength: Int
    /// transport_stream_id for the PAT, program_number for a PMT.
    var tableIDExtension: UInt16
    var version: UInt8
    var isCurrent: Bool
    var sectionNumber: UInt8
    var lastSectionNumber: UInt8
    var crc: UInt32
}

nonisolated enum PSICheck: Equatable {
    case valid(PSIHeader)
    case badCRC
    case malformed
}

nonisolated struct PATEntry: Equatable {
    var programNumber: UInt16
    var pmtPID: UInt16
}

nonisolated struct PATSection: Equatable {
    var header: PSIHeader
    /// Programs in section order, excluding program_number 0 (the network PID).
    var entries: [PATEntry]
}

nonisolated enum PSIParser {
    static let patTableID: UInt8 = 0x00
    static let pmtTableID: UInt8 = 0x02
    /// The PAT and PMT section_length may not exceed 1021 (13818-1 §2.4.4.3, §2.4.4.8).
    static let maximumSectionLength = 1021

    /// Validates the header, the declared length and the CRC of a complete long-form section.
    static func check(_ section: UnsafeBufferPointer<UInt8>) -> PSICheck {
        guard section.count >= 12 else { return .malformed }
        let sectionLength = ByteField.u12(section[1], section[2])
        let syntaxIndicator = (section[1] & 0x80) != 0
        guard syntaxIndicator, sectionLength >= 9, sectionLength <= maximumSectionLength,
              section.count == 3 + sectionLength else { return .malformed }
        guard CRC32MPEG2.checksum(section) == 0 else { return .badCRC }
        let crcOffset = section.count - 4
        var crc: UInt32 = 0
        for index in 0..<4 {
            crc = (crc << 8) | UInt32(section[crcOffset + index])
        }
        let header = PSIHeader(
            tableID: section[0],
            sectionLength: sectionLength,
            tableIDExtension: UInt16(ByteField.u16(section[3], section[4])),
            version: (section[5] >> 1) & 0x1F,
            isCurrent: (section[5] & 0x01) != 0,
            sectionNumber: section[6],
            lastSectionNumber: section[7],
            crc: crc
        )
        return .valid(header)
    }

    /// Parses a CRC-checked PAT section.
    static func parsePAT(_ section: UnsafeBufferPointer<UInt8>, header: PSIHeader) -> PATSection? {
        guard header.tableID == patTableID else { return nil }
        let end = section.count - 4
        var entries: [PATEntry] = []
        var offset = 8
        while offset + 4 <= end {
            let number = UInt16(ByteField.u16(section[offset], section[offset + 1]))
            let pid = ByteField.u13(section[offset + 2], section[offset + 3])
            if number != 0 {
                entries.append(PATEntry(programNumber: number, pmtPID: pid))
            }
            offset += 4
        }
        return PATSection(header: header, entries: entries)
    }

    /// Parses a CRC-checked PMT section carried on `pmtPID`.
    static func parsePMT(_ section: UnsafeBufferPointer<UInt8>, header: PSIHeader, pmtPID: UInt16) -> ProgramMap? {
        guard header.tableID == pmtTableID, header.sectionNumber == 0 else { return nil }
        let end = section.count - 4
        let pcrPID = ByteField.u13(section[8], section[9])
        let programInfoLength = ByteField.u12(section[10], section[11])
        var offset = 12 + programInfoLength
        guard offset <= end else { return nil }
        var streams: [ElementaryStream] = []
        while offset + 5 <= end {
            let streamType = section[offset]
            let pid = ByteField.u13(section[offset + 1], section[offset + 2])
            let infoLength = ByteField.u12(section[offset + 3], section[offset + 4])
            let infoStart = offset + 5
            guard infoStart + infoLength <= end else { return nil }
            let stream = describe(streamType: streamType, pid: pid, section: section,
                                  descriptors: infoStart..<(infoStart + infoLength))
            streams.append(stream)
            offset = infoStart + infoLength
        }
        return ProgramMap(programNumber: header.tableIDExtension, pmtPID: pmtPID, pcrPID: pcrPID, streams: streams)
    }

    // MARK: - Descriptors

    private struct DescriptorSummary {
        var language: String?
        var registration: UInt32?
        var hasDVBAC3 = false
        var hasDVBEnhancedAC3 = false
        var hasDVBAC4 = false
        var atscChannelCode: Int?
    }

    static let registrationAC3: UInt32 = 0x4143_2D33   // "AC-3"
    static let registrationEAC3: UInt32 = 0x4541_4333  // "EAC3"
    static let registrationHEVC: UInt32 = 0x4845_5643  // "HEVC"
    static let registrationAC4: UInt32 = 0x4143_2D34   // "AC-4"

    static func describe(
        streamType: UInt8,
        pid: UInt16,
        section: UnsafeBufferPointer<UInt8>,
        descriptors range: Range<Int>
    ) -> ElementaryStream {
        let summary = summarize(section, range: range)
        let kind = classify(streamType: streamType, summary: summary)
        var hint: Int?
        if kind == .ac3 || kind == .eac3, let code = summary.atscChannelCode {
            hint = channelCount(atscCode: code)
        }
        return ElementaryStream(pid: pid, streamType: streamType, kind: kind, language: summary.language,
                                audioChannelsHint: hint)
    }

    private static func summarize(_ bytes: UnsafeBufferPointer<UInt8>, range: Range<Int>) -> DescriptorSummary {
        var summary = DescriptorSummary()
        var offset = range.lowerBound
        while offset + 2 <= range.upperBound {
            let tag = bytes[offset]
            let length = Int(bytes[offset + 1])
            let body = offset + 2
            guard body + length <= range.upperBound else { break }
            switch tag {
            case 0x0A where length >= 3 && summary.language == nil:
                summary.language = languageCode(bytes, at: body)
            case 0x05 where length >= 4:
                var value: UInt32 = 0
                for index in 0..<4 {
                    value = (value << 8) | UInt32(bytes[body + index])
                }
                summary.registration = value
            case 0x6A:
                summary.hasDVBAC3 = true
            case 0x7A:
                summary.hasDVBEnhancedAC3 = true
            case 0x7F where length >= 1 && bytes[body] == 0x15:
                // DVB extension descriptor carrying the AC-4 descriptor.
                summary.hasDVBAC4 = true
            case 0x81 where length >= 3:
                // ATSC A/52 Annex A AC-3_audio_stream_descriptor: byte 2 is bsmod(3) num_channels(4) full_svc(1).
                summary.atscChannelCode = Int((bytes[body + 2] >> 1) & 0x0F)
            default:
                break
            }
            offset = body + length
        }
        return summary
    }

    private static func classify(streamType: UInt8, summary: DescriptorSummary) -> StreamKind {
        switch streamType {
        case 0x02: return .mpeg2Video
        case 0x1B: return .h264
        case 0x24: return .hevc
        case 0x81: return .ac3
        case 0x87: return .eac3
        case 0x0F: return .aac
        case 0x03, 0x04: return .mpegAudio
        case 0x06:
            return classifyPrivateData(summary) ?? .other(streamType)
        case 0x80...0xFF:
            return classifyRegistered(summary.registration) ?? .other(streamType)
        default:
            return .other(streamType)
        }
    }

    /// stream_type 0x06 (PES private data): DVB AC-3/E-AC-3 descriptors or a registration descriptor.
    private static func classifyPrivateData(_ summary: DescriptorSummary) -> StreamKind? {
        if summary.hasDVBAC4 || summary.registration == registrationAC4 { return .ac4 }
        if summary.hasDVBEnhancedAC3 || summary.registration == registrationEAC3 { return .eac3 }
        if summary.hasDVBAC3 || summary.registration == registrationAC3 { return .ac3 }
        return nil
    }

    /// User-private stream types identified only by a registration descriptor.
    private static func classifyRegistered(_ registration: UInt32?) -> StreamKind? {
        switch registration {
        case registrationAC3: .ac3
        case registrationEAC3: .eac3
        case registrationHEVC: .hevc
        case registrationAC4: .ac4
        default: nil
        }
    }

    /// A/52 Table A4.4: codes 0–7 follow acmod (1+1 counts as 2), codes 8–13 are upper bounds of 1–6 channels.
    static func channelCount(atscCode code: Int) -> Int? {
        switch code {
        case 0: 2
        case 1...7: [0, 1, 2, 3, 3, 4, 4, 5][code]
        case 8...13: code - 7
        default: nil
        }
    }

    private static func languageCode(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> String? {
        var letters: [UInt8] = []
        for index in 0..<3 {
            let byte = bytes[offset + index]
            switch byte {
            case UInt8(ascii: "a")...UInt8(ascii: "z"): letters.append(byte)
            case UInt8(ascii: "A")...UInt8(ascii: "Z"): letters.append(byte + 32)
            default: return nil
            }
        }
        return String(letters.map { Character(Unicode.Scalar($0)) })
    }
}
