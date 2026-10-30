//
//  AC3Header.swift
//  MPEGTS
//
//  AC-3 (ATSC A/52) and E-AC-3 (A/52 Annex E) syncframe headers and the frame type `AC3Framer` emits.
//

import Foundation

/// One AC-3 syncframe, or one E-AC-3 access unit (an independent substream 0 frame plus the dependent and further
/// substream frames that follow it).
nonisolated public struct AC3Frame: Sendable, Equatable {
    public var data: Data
    /// 90 kHz on the demuxer's timeline. The first frame starting in a PES gets that PES's PTS; later frames add
    /// `samplesPerFrame / sampleRate` (2880 ticks for 1536 samples at 48 kHz).
    public var pts: Int64
    public var sampleRate: Int
    /// Channels from `acmod` plus the LFE channel (6 for 5.1). For E-AC-3, of the independent substream only.
    public var channelCount: Int
    /// Audio coding mode: 0 1+1, 1 1/0, 2 2/0, 3 3/0, 4 2/1, 5 3/1, 6 2/2, 7 3/2.
    public var acmod: UInt8
    public var hasLFE: Bool
    public var isEAC3: Bool
    /// 1536 for AC-3; 256 × blocks (256, 512, 768 or 1536) for E-AC-3.
    public var samplesPerFrame: Int

    public init(
        data: Data,
        pts: Int64,
        sampleRate: Int,
        channelCount: Int,
        acmod: UInt8,
        hasLFE: Bool,
        isEAC3: Bool,
        samplesPerFrame: Int
    ) {
        self.data = data
        self.pts = pts
        self.sampleRate = sampleRate
        self.channelCount = channelCount
        self.acmod = acmod
        self.hasLFE = hasLFE
        self.isEAC3 = isEAC3
        self.samplesPerFrame = samplesPerFrame
    }

    /// Full-bandwidth channels per acmod.
    static let channelsByMode = [2, 1, 2, 3, 3, 4, 4, 5]
}

/// The syncinfo and bit-stream-information fields `AC3Framer` needs.
nonisolated struct AC3SyncInfo: Equatable {
    var isEAC3: Bool
    var frameSize: Int
    var sampleRate: Int
    var samplesPerFrame: Int
    var acmod: UInt8
    var hasLFE: Bool
    /// E-AC-3 strmtyp (0 independent, 1 dependent, 2 AC-3 converted); 0 for AC-3.
    var streamType: UInt8 = 0
    var substreamID: UInt8 = 0

    /// Whether this frame starts a new access unit (AC-3, or E-AC-3 independent substream 0).
    var startsAccessUnit: Bool { !isEAC3 || (streamType != 1 && substreamID == 0) }

    static let headerSize = 8
    /// Bit rates in kbit/s per frmsizecod >> 1 (A/52 Table 5.18).
    static let bitRates = [32, 40, 48, 56, 64, 80, 96, 112, 128, 160, 192, 224, 256, 320, 384, 448, 512, 576, 640]
    static let sampleRates = [48_000, 44_100, 32_000]
    static let reducedSampleRates = [24_000, 22_050, 16_000]
    static let blocksPerFrame = [1, 2, 3, 6]

    /// Parses the header at `offset`, which must hold the 0x0B77 syncword. Nil for reserved or impossible values.
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>, at offset: Int) -> AC3SyncInfo? {
        guard offset >= 0, offset + headerSize <= bytes.count,
              bytes[offset] == 0x0B, bytes[offset + 1] == 0x77 else { return nil }
        let bsid = Int(bytes[offset + 5] >> 3)
        let header = UnsafeBufferPointer(rebasing: bytes[offset..<(offset + headerSize)])
        switch bsid {
        case 0...10: return parseAC3(header, bsid: bsid)
        case 11...16: return parseEAC3(header)
        default: return nil
        }
    }

    private static func parseAC3(_ header: UnsafeBufferPointer<UInt8>, bsid: Int) -> AC3SyncInfo? {
        let fscod = Int(header[4] >> 6)
        let frmsizecod = Int(header[4] & 0x3F)
        guard fscod < 3, frmsizecod < 38 else { return nil }
        let baseRate = sampleRates[fscod]
        var words = bitRates[frmsizecod >> 1] * 96_000 / baseRate
        if fscod == 1 {
            words += frmsizecod & 1
        }
        var reader = BitReader(header, offset: 6)
        let acmod = UInt8(reader.int(3))
        if (acmod & 0x01) != 0, acmod != 1 { reader.skip(2) }  // cmixlev
        if (acmod & 0x04) != 0 { reader.skip(2) }  // surmixlev
        if acmod == 2 { reader.skip(2) }  // dsurmod
        let lfe = reader.flag()
        guard !reader.isOverrun else { return nil }
        // bsid 9 and 10 halve and quarter the sample rate (as decoders treat them); the frame size is unchanged.
        let shift = max(bsid, 8) - 8
        return AC3SyncInfo(isEAC3: false, frameSize: words * 2, sampleRate: baseRate >> shift,
                           samplesPerFrame: 1536, acmod: acmod, hasLFE: lfe)
    }

    private static func parseEAC3(_ header: UnsafeBufferPointer<UInt8>) -> AC3SyncInfo? {
        var reader = BitReader(header, offset: 2)
        let streamType = UInt8(reader.int(2))
        let substreamID = UInt8(reader.int(3))
        let frameSize = (reader.int(11) + 1) * 2
        let fscod = reader.int(2)
        let rateOrBlocks = reader.int(2)
        let acmod = UInt8(reader.int(3))
        let lfe = reader.flag()
        guard !reader.isOverrun, streamType != 3, frameSize >= headerSize else { return nil }
        let sampleRate: Int
        let blocks: Int
        if fscod == 3 {
            guard rateOrBlocks < 3 else { return nil }
            sampleRate = reducedSampleRates[rateOrBlocks]
            blocks = 6
        } else {
            sampleRate = sampleRates[fscod]
            blocks = blocksPerFrame[rateOrBlocks]
        }
        return AC3SyncInfo(isEAC3: true, frameSize: frameSize, sampleRate: sampleRate, samplesPerFrame: blocks * 256,
                           acmod: acmod, hasLFE: lfe, streamType: streamType, substreamID: substreamID)
    }
}
