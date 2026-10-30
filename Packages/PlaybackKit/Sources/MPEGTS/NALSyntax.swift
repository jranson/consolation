//
//  NALSyntax.swift
//  MPEGTS
//
//  Syntax shared by H.264 and HEVC NAL units: removing emulation prevention bytes to get the RBSP, and splitting SEI
//  messages, including ATSC A/53 caption data in user_data_registered_itu_t_t35 (ATSC A/72 Part 1 §6.4, A/53 Part 4).
//

nonisolated enum NALSyntax {
    /// Headers never need more of a NAL unit than this; anything longer is cut short (and so fails as an overrun).
    static let maximumParsedBytes = 64 * 1024
    /// SEI messages read from one SEI NAL unit, at most.
    static let maximumSEIMessages = 64

    /// The RBSP of `bytes[start...]`: every `00 00 03` loses its 03 (emulation_prevention_three_byte).
    static func rbsp(_ bytes: UnsafeBufferPointer<UInt8>, from start: Int,
                     limit: Int = maximumParsedBytes) -> [UInt8] {
        guard start >= 0, start < bytes.count else { return [] }
        var output: [UInt8] = []
        output.reserveCapacity(min(bytes.count - start, limit))
        var zeros = 0
        var index = start
        while index < bytes.count, output.count < limit {
            let byte = bytes[index]
            index += 1
            if zeros >= 2, byte == 0x03 {
                zeros = 0
                continue
            }
            output.append(byte)
            zeros = byte == 0 ? zeros + 1 : 0
        }
        return output
    }

    struct SEIMessage: Equatable {
        let payloadType: Int
        /// The payload's bytes within the RBSP the messages were split from.
        let payload: Range<Int>
    }

    /// The sei_message()s of an SEI RBSP (H.264 §7.3.2.3, HEVC §7.3.5), stopping at the trailing bits or at the
    /// first message that claims more bytes than remain.
    static func seiMessages(_ rbsp: [UInt8]) -> [SEIMessage] {
        var messages: [SEIMessage] = []
        var offset = 0
        while offset < rbsp.count, messages.count < maximumSEIMessages {
            if rbsp[offset] == 0x80, offset == rbsp.count - 1 { break }
            guard let type = ffCoded(rbsp, at: &offset), let size = ffCoded(rbsp, at: &offset),
                  offset + size <= rbsp.count else { break }
            messages.append(SEIMessage(payloadType: type, payload: offset..<(offset + size)))
            offset += size
        }
        return messages
    }

    /// A payloadType or payloadSize: a run of 0xFF bytes (255 each) plus a last byte.
    private static func ffCoded(_ bytes: [UInt8], at offset: inout Int) -> Int? {
        var value = 0
        while offset < bytes.count, bytes[offset] == 0xFF {
            value += 255
            offset += 1
        }
        guard offset < bytes.count else { return nil }
        value += Int(bytes[offset])
        offset += 1
        return value
    }

    /// payloadType 4, user_data_registered_itu_t_t35.
    static let userDataRegisteredT35 = 4

    /// Appends the `cc_data` triplets of an ATSC A/53 t35 payload: itu_t_t35_country_code 0xB5 (United States),
    /// itu_t_t35_provider_code 0x0031 (ATSC), then the same `GA94` user data as MPEG-2 picture user data.
    static func appendCaptions(t35 payload: UnsafeBufferPointer<UInt8>, to captions: inout [UInt8]) {
        guard payload.count >= 3, payload[0] == 0xB5, payload[1] == 0x00, payload[2] == 0x31 else { return }
        MPEG2Headers.appendCaptions(UnsafeBufferPointer(rebasing: payload[3...]), to: &captions)
    }
}
