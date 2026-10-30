import Foundation
@testable import PlaybackKit

/// Builds synthetic CEA-608 byte pairs and A/53 `cc_data` for caption tests.
nonisolated enum CaptionBytes {
    typealias Pair = (UInt8, UInt8)

    static let rcl: Pair = (0x14, 0x20)
    static let backspace: Pair = (0x14, 0x21)
    static let der: Pair = (0x14, 0x24)
    static let ru2: Pair = (0x14, 0x25)
    static let ru3: Pair = (0x14, 0x26)
    static let ru4: Pair = (0x14, 0x27)
    static let rdc: Pair = (0x14, 0x29)
    static let edm: Pair = (0x14, 0x2C)
    static let carriageReturn: Pair = (0x14, 0x2D)
    static let enm: Pair = (0x14, 0x2E)
    static let eoc: Pair = (0x14, 0x2F)

    /// Sets bit 7 where needed so the byte has odd parity.
    static func odd(_ byte: UInt8) -> UInt8 {
        let low = byte & 0x7F
        return low.nonzeroBitCount % 2 == 1 ? low : low | 0x80
    }

    /// Flips the parity bit so the byte fails the parity check.
    static func corrupt(_ byte: UInt8) -> UInt8 {
        odd(byte) ^ 0x80
    }

    /// A control code as broadcast: the pair sent twice. Channel 2 sets bit 3 of the first byte.
    static func control(_ pair: Pair, channel: Int = 1) -> [Pair] {
        let first = channel == 2 ? pair.0 | 0x08 : pair.0
        return [(first, pair.1), (first, pair.1)]
    }

    /// Basic characters packed two per pair, padded with 0x00.
    static func text(_ string: String) -> [Pair] {
        let bytes = Array(string.utf8)
        return stride(from: 0, to: bytes.count, by: 2).map { index in
            (bytes[index], index + 1 < bytes.count ? bytes[index + 1] : 0)
        }
    }

    /// A preamble address code for a 1-based row, with either an indent or a color/italic style.
    static func pac(
        row: Int,
        indent: Int = 0,
        color: CaptionColor = .white,
        italic: Bool = false,
        underline: Bool = false,
        channel: Int = 1
    ) -> [Pair] {
        let firstBytes: [Int: UInt8] = [
            1: 0x11, 2: 0x11, 3: 0x12, 4: 0x12, 5: 0x15, 6: 0x15, 7: 0x16, 8: 0x16,
            9: 0x17, 10: 0x17, 11: 0x10, 12: 0x13, 13: 0x13, 14: 0x14, 15: 0x14
        ]
        let lowerOfPair: Set<Int> = [2, 4, 6, 8, 10, 13, 15]
        var second: UInt8 = lowerOfPair.contains(row) ? 0x60 : 0x40
        if indent > 0 {
            second |= 0x10 | UInt8(indent / 4) << 1
        } else if italic {
            second |= 0x0E
        } else {
            second |= UInt8(color.rawValue) << 1
        }
        if underline {
            second |= 0x01
        }
        return control((firstBytes[row] ?? 0x14, second), channel: channel)
    }

    /// A mid-row code (0x11 0x20-0x2F).
    static func midRow(color: CaptionColor = .white, italic: Bool = false, underline: Bool = false) -> [Pair] {
        var second: UInt8 = 0x20 | (italic ? 0x0E : UInt8(color.rawValue) << 1)
        if underline {
            second |= 0x01
        }
        return control((0x11, second))
    }

    /// `cc_data` triplets for one picture: each pair with odd parity, `cc_valid` set, on `field` (1 or 2).
    static func ccData(_ pairs: [Pair], field: Int = 1) -> Data {
        var bytes: [UInt8] = []
        for pair in pairs {
            bytes += [0xFC | UInt8(field - 1), odd(pair.0), odd(pair.1)]
        }
        return Data(bytes)
    }
}

/// Feeds a decoder one pair per picture at 29.97 fps, as a broadcast would.
nonisolated final class CaptionFeeder {
    static let frameTicks: Int64 = 3_003

    var decoder: CEA608Decoder
    var pts: Int64 = 0
    var field = 1

    init(service: CaptionService = .cc1) {
        decoder = CEA608Decoder(service: service)
        field = service.field
    }

    var screen: CaptionScreen { decoder.screen }

    /// Decodes one picture's `cc_data` at an explicit time.
    @discardableResult
    func decode(_ data: Data, at time: Int64) -> Bool {
        decoder.decode(ccData: data, pts: time)
    }

    /// Sends the pairs; returns whether any of them changed the displayed caption.
    @discardableResult
    func send(_ pairs: [CaptionBytes.Pair]) -> Bool {
        var changed = false
        for pair in pairs {
            pts += Self.frameTicks
            changed = decoder.decode(ccData: CaptionBytes.ccData([pair], field: field), pts: pts) || changed
        }
        return changed
    }

    /// Sends raw pairs (parity bits as given), one per picture.
    @discardableResult
    func sendRaw(_ pairs: [CaptionBytes.Pair]) -> Bool {
        var changed = false
        for pair in pairs {
            pts += Self.frameTicks
            let header: UInt8 = 0xFC | UInt8(field - 1)
            changed = decoder.decode(ccData: Data([header, pair.0, pair.1]), pts: pts) || changed
        }
        return changed
    }
}
