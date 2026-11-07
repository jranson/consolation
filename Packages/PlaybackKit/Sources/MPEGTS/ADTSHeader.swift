//
//  ADTSHeader.swift
//  MPEGTS
//
//  The header in front of every AAC frame in ADTS (Audio Data Transport Stream, ISO/IEC 13818-7 §6.2 and
//  ISO/IEC 14496-3 §1.A.2), the form AAC takes in MPEG-TS (stream_type 0x0F): the profile, sample rate and channel
//  configuration of a plain AAC stream, and the frame's length. SBR (HE-AAC) is never signalled here: an ADTS
//  header names the core rate, and only the payload shows SBR.
//

import Foundation

nonisolated public struct ADTSHeader: Sendable, Equatable {
    /// The fixed and variable header without its CRC.
    public static let minimumSize = 7

    /// The audio object type: the header's profile plus one (2 is AAC LC).
    public var objectType: Int
    public var sampleRateIndex: Int
    /// The core decoder's sample rate.
    public var sampleRate: Int
    /// 1-6 are 1 to 6 channels, 7 is 8 channels; 0 means a program config element in the payload says.
    public var channelConfiguration: Int
    /// The whole frame, header included.
    public var frameLength: Int
    /// 7, or 9 with the CRC.
    public var headerLength: Int
    /// Raw data blocks in the frame (1 to 4), 1024 samples each.
    public var rawDataBlocks: Int

    /// Samples per frame at the core rate.
    public var samplesPerFrame: Int { rawDataBlocks * 1_024 }

    /// What must not change for frames to share one format.
    public var format: Format {
        Format(objectType: objectType, sampleRateIndex: sampleRateIndex, channelConfiguration: channelConfiguration)
    }

    public struct Format: Sendable, Hashable {
        public var objectType: Int
        public var sampleRateIndex: Int
        public var channelConfiguration: Int
    }

    /// The plain AAC config this header describes (no SBR), or nil when the layout is left to a program config
    /// element.
    public var config: AudioSpecificConfig? {
        guard channelConfiguration > 0 else { return nil }
        return AudioSpecificConfig(objectType: objectType, sampleRate: sampleRate,
                                   channels: channelConfiguration == 7 ? 8 : channelConfiguration)
    }

    /// Reads a header at `position`; nil when there is none there (or too little of it).
    public static func parse(_ bytes: UnsafeBufferPointer<UInt8>, at position: Int) -> ADTSHeader? {
        guard position >= 0, position + minimumSize <= bytes.count else { return nil }
        let byte1 = bytes[position + 1]
        let byte2 = bytes[position + 2]
        let byte3 = bytes[position + 3]
        // The 12-bit syncword and a layer of 0.
        guard bytes[position] == 0xFF, byte1 & 0xF6 == 0xF0 else { return nil }
        let rateIndex = Int((byte2 >> 2) & 0x0F)
        guard rateIndex < AudioSpecificConfig.sampleRates.count else { return nil }
        let headerLength = byte1 & 0x01 == 1 ? 7 : 9
        let frameLength = (Int(byte3 & 0x03) << 11) | (Int(bytes[position + 4]) << 3) | Int(bytes[position + 5] >> 5)
        guard frameLength > headerLength else { return nil }
        return ADTSHeader(
            objectType: Int(byte2 >> 6) + 1, sampleRateIndex: rateIndex,
            sampleRate: AudioSpecificConfig.sampleRates[rateIndex],
            channelConfiguration: (Int(byte2 & 0x01) << 2) | Int(byte3 >> 6), frameLength: frameLength,
            headerLength: headerLength, rawDataBlocks: Int(bytes[position + 6] & 0x03) + 1)
    }
}

/// One ADTS frame: its header and the access unit after it.
nonisolated public struct ADTSFrame: Sendable, Equatable {
    /// The whole frame, header included (AudioToolbox's ADTS parser reads it whole).
    public var frame: Data
    public var header: ADTSHeader
    /// 90 kHz on the demuxer's timeline. The first frame starting in a PES gets that PES's PTS; later frames add
    /// 1024 samples at the core rate (3840 ticks at 24 kHz).
    public var pts: Int64

    public init(frame: Data, header: ADTSHeader, pts: Int64) {
        self.frame = frame
        self.header = header
        self.pts = pts
    }

    /// The access unit without the header (and its CRC), as an AAC decoder takes it.
    public var accessUnit: Data {
        frame.subdata(in: (frame.startIndex + header.headerLength)..<frame.endIndex)
    }
}
