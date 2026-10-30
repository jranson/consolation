//
//  LentPayloadTests.swift
//  MPEGTSTests
//
//  The lending demuxer and framer calls (`TSDemuxer.feed(_:_:)`, `MPEG2Framer.append(_:of:_:)`) give exactly what
//  the copying ones do, on every committed fixture and on damaged input. The copying calls wrap the lending ones, so
//  these check the wrappers and the lending contract only; a framing regression shared by both shows up in the
//  independent expectations of GoldenFixtureTests, MalformedInputTests and MPEG2FramerTests instead.
//

import Foundation
import MPEGTS
import Testing

struct LentPayloadTests {
    static let fixtures = ["golden-1080i", "golden-720p", "golden-720p-mid-gop", "golden-discontinuity",
                           "golden-pts-wrap", "golden-two-programs"]

    /// Events from feeding `data` in chunks, payloads copied out of the callback.
    private static func lentEvents(_ data: Data, chunk: Int) -> [TSDemuxEvent] {
        var demuxer = TSDemuxer()
        var events: [TSDemuxEvent] = []
        for offset in stride(from: 0, to: data.count, by: chunk) {
            demuxer.feed(data.subdata(in: offset..<min(offset + chunk, data.count))) {
                events.append(TSDemuxEvent($0))
            }
        }
        demuxer.flush { events.append(TSDemuxEvent($0)) }
        return events
    }

    private static func copiedEvents(_ data: Data, chunk: Int) -> [TSDemuxEvent] {
        var demuxer = TSDemuxer()
        var events: [TSDemuxEvent] = []
        for offset in stride(from: 0, to: data.count, by: chunk) {
            events += demuxer.feed(data.subdata(in: offset..<min(offset + chunk, data.count)))
        }
        return events + demuxer.flush()
    }

    /// Every video PID's access units, framed from lent payloads with their bytes copied out of the callback.
    private static func lentUnits(_ events: [TSDemuxEvent]) -> [UInt16: [MPEG2AccessUnit]] {
        var framers: [UInt16: MPEG2Framer] = [:]
        var units: [UInt16: [MPEG2AccessUnit]] = [:]
        for case .pes(let pes) in events where (0xE0...0xEF).contains(pes.streamID) {
            var framer = framers.removeValue(forKey: pes.pid) ?? MPEG2Framer()
            pes.payload.withUnsafeBytes { raw in
                framer.append(raw.bindMemory(to: UInt8.self), of: pes) { unit, bytes in
                    #expect(unit.data.isEmpty)
                    var copy = unit
                    copy.data = Data(buffer: bytes)
                    units[pes.pid, default: []].append(copy)
                }
            }
            framers[pes.pid] = framer
        }
        for (pid, var framer) in framers {
            framer.flush { unit, bytes in
                var copy = unit
                copy.data = Data(buffer: bytes)
                units[pid, default: []].append(copy)
            }
        }
        return units
    }

    private static func copiedUnits(_ events: [TSDemuxEvent]) -> [UInt16: [MPEG2AccessUnit]] {
        var framers: [UInt16: MPEG2Framer] = [:]
        var units: [UInt16: [MPEG2AccessUnit]] = [:]
        for case .pes(let pes) in events where (0xE0...0xEF).contains(pes.streamID) {
            units[pes.pid, default: []] += framers[pes.pid, default: MPEG2Framer()].append(pes)
        }
        for pid in framers.keys {
            units[pid, default: []] += framers[pid]?.flush() ?? []
        }
        return units
    }

    @Test(arguments: fixtures)
    func lentEventsMatchCopiedEvents(_ name: String) throws {
        let url = try #require(GoldenStream.url(name))
        let data = try Data(contentsOf: url)
        for chunk in [188, 7 * 1024, 188 * 512] {
            let lent = Self.lentEvents(data, chunk: chunk)
            #expect(lent == Self.copiedEvents(data, chunk: chunk))
            #expect(lent.contains { if case .pes = $0 { true } else { false } })
        }
    }

    @Test(arguments: fixtures)
    func lentAccessUnitsMatchCopiedAccessUnits(_ name: String) throws {
        let url = try #require(GoldenStream.url(name))
        let events = Self.copiedEvents(try Data(contentsOf: url), chunk: 7 * 1024)
        let lent = Self.lentUnits(events)
        #expect(!lent.isEmpty)
        #expect(lent == Self.copiedUnits(events))
    }

    /// Damaged input: dropped and corrupted packets, all lent and copied alike.
    @Test func damagedInputMatches() throws {
        let url = try #require(GoldenStream.url("golden-1080i"))
        var bytes = [UInt8](try Data(contentsOf: url))
        var state: UInt32 = 0x1234_5678
        for _ in 0..<400 {
            state = state &* 1_664_525 &+ 1_013_904_223
            let index = Int(state % UInt32(bytes.count))
            bytes[index] = UInt8(truncatingIfNeeded: state >> 24)
        }
        let data = Data(bytes)
        let events = Self.copiedEvents(data, chunk: 7 * 1024)
        #expect(Self.lentEvents(data, chunk: 7 * 1024) == events)
        #expect(Self.lentUnits(events) == Self.copiedUnits(events))
    }

    @Test func programsListTheProgramNumbersOfThePAT() throws {
        let url = try #require(GoldenStream.url("golden-two-programs"))
        var demuxer = TSDemuxer()
        var listed: [UInt16] = []
        demuxer.feed(try Data(contentsOf: url)) { event in
            if case .programs(_, let numbers) = event { listed = numbers }
        }
        #expect(listed == demuxer.listedProgramNumbers)
        #expect(listed == [3, 4])
    }
}
