//
//  AVFoundationTestSupport.swift
//  PlaybackKitTests
//
//  Helpers for the AVFoundation-side tests: an in-memory fetcher, a seeded random generator for the
//  malformed-input runs, and ISO-BMFF box builders for synthetic init segments and fragments.
//

import Foundation
import Synchronization
@testable import PlaybackKit

/// Serves canned bodies by absolute URL string and records every request.
nonisolated final class FakeMediaFetcher: MediaResourceFetching {
    private let bodies: [String: Data]
    private let log = Mutex<[String]>([])

    init(_ bodies: [String: Data]) {
        self.bodies = bodies
    }

    var requests: [String] {
        log.withLock { $0 }
    }

    func fetch(_ url: URL, range: ClosedRange<Int>?, maxBytes: Int) async throws -> Data {
        log.withLock { $0.append(url.absoluteString) }
        guard let body = bodies[url.absoluteString] else {
            throw PlaybackError(kind: .network, title: "Not found", domain: "HTTPStatus", code: 404)
        }
        guard let range else {
            guard body.count <= maxBytes else { throw PlaybackErrorMapping.tooLarge }
            return body
        }
        let start = min(range.lowerBound, body.count)
        let end = min(body.count, range.upperBound + 1, start + maxBytes)
        return body.subdata(in: start..<end)
    }
}

/// SplitMix64, so malformed-input runs are reproducible.
nonisolated struct SeededGenerator: RandomNumberGenerator {
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

/// Builds ISO-BMFF boxes.
nonisolated enum Box {
    static func make(_ type: String, _ payload: [UInt8] = []) -> [UInt8] {
        be32(UInt32(8 + payload.count)) + Array(type.utf8) + payload
    }

    static func full(_ type: String, version: UInt8 = 0, flags: UInt32 = 0, _ payload: [UInt8] = []) -> [UInt8] {
        make(type, [version, UInt8((flags >> 16) & 0xFF), UInt8((flags >> 8) & 0xFF), UInt8(flags & 0xFF)] + payload)
    }

    static func be16(_ value: UInt16) -> [UInt8] {
        [UInt8(value >> 8), UInt8(value & 0xFF)]
    }

    static func be32(_ value: UInt32) -> [UInt8] {
        [UInt8(value >> 24), UInt8((value >> 16) & 0xFF), UInt8((value >> 8) & 0xFF), UInt8(value & 0xFF)]
    }

    /// hvcC for HEVC Main 10, Main tier, level 5.0 (150), compatibility 0x20000000, constraints 0x90, as in the sample
    /// init segment.
    static let sampleHvcC: [UInt8] = [0x01, 0x02, 0x20, 0x00, 0x00, 0x00, 0x90, 0x00, 0x00, 0x00, 0x00, 0x00, 0x96,
                                     0xF0, 0x00, 0xFC, 0xFD, 0xFA, 0xFA, 0x00, 0x00, 0x0F, 0x00]

    /// colr nclx with the given primaries/transfer/matrix.
    static func colr(transfer: UInt16, primaries: UInt16 = 9, matrix: UInt16 = 9) -> [UInt8] {
        make("colr", Array("nclx".utf8) + be16(primaries) + be16(transfer) + be16(matrix) + [0x00])
    }

    /// A visual sample entry with children.
    static func visualEntry(_ type: String, width: UInt16, height: UInt16, children: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 6) + be16(1) + [UInt8](repeating: 0, count: 16)
        body += be16(width) + be16(height) + be32(0x0048_0000) + be32(0x0048_0000) + be32(0) + be16(1)
        body += [UInt8](repeating: 0, count: 32) + be16(0x0018) + be16(0xFFFF)
        return make(type, body + children)
    }

    /// An audio sample entry (version 0) with children.
    static func audioEntry(_ type: String, channels: UInt16, sampleRate: UInt32, children: [UInt8]) -> [UInt8] {
        var body = [UInt8](repeating: 0, count: 6) + be16(1) + [UInt8](repeating: 0, count: 8)
        body += be16(channels) + be16(16) + be16(0) + be16(0) + be32(sampleRate << 16)
        return make(type, body + children)
    }

    /// esds for AAC with the given AudioSpecificConfig bytes.
    static func esds(objectType: UInt8 = 0x40, specific: [UInt8]) -> [UInt8] {
        let decoderSpecific = [0x05, UInt8(specific.count)] + specific
        let config = [0x04, UInt8(13 + decoderSpecific.count), objectType, 0x15] + [UInt8](repeating: 0, count: 11)
            + decoderSpecific
        let elementary = [0x03, UInt8(3 + config.count), 0x00, 0x01, 0x00] + config
        return full("esds", elementary)
    }

    /// A one-track init segment.
    static func initSegment(handler: String, timescale: UInt32, trackID: UInt32 = 1, entry: [UInt8],
                            trexDuration: UInt32 = 0) -> [UInt8] {
        let tkhd = full("tkhd", flags: 3, be32(0) + be32(0) + be32(trackID) + [UInt8](repeating: 0, count: 72))
        let mdhd = full("mdhd", be32(0) + be32(0) + be32(timescale) + be32(0) + be16(0x55C4) + be16(0))
        let hdlr = full("hdlr", be32(0) + Array(handler.utf8) + [UInt8](repeating: 0, count: 13))
        let stsd = full("stsd", be32(1) + entry)
        let stbl = make("stbl", stsd + full("stts", be32(0)))
        let minf = make("minf", stbl)
        let mdia = make("mdia", mdhd + hdlr + minf)
        let trak = make("trak", tkhd + mdia)
        let trex = full("trex", be32(trackID) + be32(1) + be32(trexDuration) + be32(0) + be32(0))
        let moov = make("moov", full("mvhd", [UInt8](repeating: 0, count: 96)) + trak + make("mvex", trex))
        return make("ftyp", Array("iso5".utf8) + be32(512)) + moov
    }

    /// A moof with one traf/tfhd/trun whose samples have the given durations (trun flags 0x301).
    static func fragment(trackID: UInt32 = 1, durations: [UInt32]) -> [UInt8] {
        let tfhd = full("tfhd", flags: 0x02_0000, be32(trackID))
        var entries: [UInt8] = []
        for duration in durations {
            entries += be32(duration) + be32(100)
        }
        let trun = full("trun", flags: 0x0301, be32(UInt32(durations.count)) + be32(0) + entries)
        let moof = make("moof", full("mfhd", be32(1)) + make("traf", tfhd + trun))
        return make("styp", Array("msdh".utf8) + be32(0)) + moof + make("mdat", [0, 0, 0, 0])
    }
}
