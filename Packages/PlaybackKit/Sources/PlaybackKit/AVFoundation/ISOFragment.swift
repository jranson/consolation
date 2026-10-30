//
//  ISOFragment.swift
//  PlaybackKit
//
//  Frame rate from the first movie fragment (moof/traf/tfhd + trun) of a media segment head.
//

import Foundation

nonisolated enum ISOFragment {
    /// Common frame rates; a measured rate within 0.5% of one of them is reported as that rate.
    static let standardFrameRates: [Double] = [
        24_000.0 / 1_001.0, 24, 25, 30_000.0 / 1_001.0, 30, 48, 50, 60_000.0 / 1_001.0, 60, 100,
        120_000.0 / 1_001.0, 120
    ]

    /// The average frame rate of the video track in the first `moof` of `data`.
    /// - Parameters:
    ///   - trackID: the video track's ID from the init segment, or nil to use the first `traf`.
    ///   - timescale: the track's `mdhd` timescale from the init segment.
    ///   - defaultDuration: the `trex` default sample duration, if any.
    static func frameRate(in data: Data, trackID: UInt32?, timescale: UInt32, defaultDuration: UInt32?) -> Double? {
        guard timescale > 0 else { return nil }
        let reader = ISOBMFFReader(data)
        guard let moof = reader.firstBox("moof", in: reader.fullRange) else { return nil }
        for traf in reader.boxes(in: moof.payload) where traf.type == "traf" {
            guard let tfhd = reader.firstBox("tfhd", in: traf.payload),
                  let header = parseTrackFragmentHeader(reader: reader, tfhd: tfhd) else { continue }
            if let trackID, header.trackID != trackID { continue }
            var samples = 0
            var ticks: UInt64 = 0
            for trun in reader.boxes(in: traf.payload) where trun.type == "trun" {
                let fallback = header.defaultDuration ?? defaultDuration
                guard let run = sumTrackRun(reader: reader, trun: trun, defaultDuration: fallback) else { continue }
                samples += run.samples
                ticks += run.ticks
            }
            guard samples > 0, ticks > 0 else { return nil }
            return snapped(Double(timescale) * Double(samples) / Double(ticks))
        }
        return nil
    }

    /// Snaps a measured rate to a standard one when close, otherwise rounds it to three decimals.
    static func snapped(_ rate: Double) -> Double? {
        guard rate.isFinite, rate > 0, rate <= 1_000 else { return nil }
        if let match = standardFrameRates.first(where: { abs(rate - $0) / $0 < 0.005 }) {
            return match
        }
        return (rate * 1_000).rounded() / 1_000
    }

    private static func parseTrackFragmentHeader(reader: ISOBMFFReader,
                                                 tfhd: ISOBox) -> (trackID: UInt32, defaultDuration: UInt32?)? {
        let base = tfhd.payload.lowerBound
        guard let header = reader.fullBoxHeader(at: base), let trackID = reader.uint32(at: base + 4) else {
            return nil
        }
        var offset = base + 8
        if header.flags & 0x01 != 0 { offset += 8 }
        if header.flags & 0x02 != 0 { offset += 4 }
        let duration = header.flags & 0x08 != 0 ? reader.uint32(at: offset) : nil
        return (trackID, duration)
    }

    /// Sample count and summed durations of one `trun`, reading only the entries that are present in the data.
    private static func sumTrackRun(reader: ISOBMFFReader, trun: ISOBox,
                                    defaultDuration: UInt32?) -> (samples: Int, ticks: UInt64)? {
        let base = trun.payload.lowerBound
        guard let header = reader.fullBoxHeader(at: base), let declared = reader.uint32(at: base + 4) else {
            return nil
        }
        let flags = header.flags
        var offset = base + 8
        if flags & 0x001 != 0 { offset += 4 }
        if flags & 0x004 != 0 { offset += 4 }
        let hasDuration = flags & 0x100 != 0
        let fieldOffsets = [0x100, 0x200, 0x400, 0x800].filter { flags & $0 != 0 }
        let entrySize = fieldOffsets.count * 4
        if !hasDuration {
            guard let defaultDuration, defaultDuration > 0 else { return nil }
            return (Int(declared), UInt64(declared) * UInt64(defaultDuration))
        }
        let available = max(0, trun.payload.upperBound - offset) / max(entrySize, 1)
        let count = min(Int(declared), available)
        var ticks: UInt64 = 0
        for index in 0..<count {
            guard let duration = reader.uint32(at: offset + index * entrySize) else { break }
            ticks += UInt64(duration)
        }
        return (count, ticks)
    }
}
