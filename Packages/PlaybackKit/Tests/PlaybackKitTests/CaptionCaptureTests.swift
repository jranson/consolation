import Foundation
import MPEGTS
import Testing
@testable import PlaybackKit

/// Opt-in: decodes the captions of local (gitignored) HDHomeRun captures; each test is skipped where its capture is
/// absent, such as CI.
struct CaptionCaptureTests {
    private nonisolated static let captures = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        .deletingLastPathComponent().deletingLastPathComponent()
        .appendingPathComponent("localdata/captures")

    private nonisolated static func exists(_ name: String) -> Bool {
        FileManager.default.fileExists(atPath: captures.appendingPathComponent(name).path)
    }

    private struct Decoded {
        var pictures = 0
        var updates: [CaptionTrackDecoder.Update] = []
        var services: Set<CaptionService> = []
        var start: Int64 = 0
    }

    /// Demuxes a capture, frames its video and feeds each picture's `cc_data` to a CC1 track decoder in decode order.
    private static func decode(_ name: String) throws -> Decoded {
        let data = try Data(contentsOf: captures.appendingPathComponent(name))
        var demuxer = TSDemuxer()
        var framer = MPEG2Framer()
        var track = CaptionTrackDecoder()
        var videoPID: UInt16?
        var result = Decoded()
        func feed(_ units: [MPEG2AccessUnit]) {
            for unit in units {
                if result.pictures == 0 {
                    result.start = unit.pts
                }
                result.pictures += 1
                if unit.isDiscontinuity {
                    track.reset()
                }
                result.updates += track.feedUpdates(pts: unit.pts, captionData: unit.captionData)
            }
        }
        func handle(_ events: [TSDemuxEvent]) {
            for event in events {
                switch event {
                case .programs(let programs):
                    videoPID = programs.first?.videoStream?.pid
                case .pes(let packet) where packet.pid == videoPID:
                    feed(framer.append(packet))
                default:
                    break
                }
            }
        }
        var offset = 0
        while offset < data.count {
            let end = min(data.count, offset + 65_536)
            handle(demuxer.feed(data.subdata(in: offset..<end)))
            offset = end
        }
        handle(demuxer.flush())
        feed(framer.flush())
        result.updates += track.flush()
        result.services = track.servicesWithCaptions
        return result
    }

    /// Prints the captions that stayed on screen for at least half a second, for a person to eyeball.
    private static func report(_ name: String, _ decoded: Decoded) {
        let services = decoded.services.map { "CC\($0.rawValue)" }.sorted().joined(separator: ", ")
        print("\(name): \(decoded.pictures) pictures, \(decoded.updates.count) CC1 screen changes, "
              + "services with captions: [\(services)]")
        var printed = 0
        for (index, update) in decoded.updates.enumerated() where !update.screen.isEmpty && printed < 10 {
            let next = index + 1 < decoded.updates.count ? decoded.updates[index + 1].pts : Int64.max
            guard next - update.pts >= 45_000 else { continue }
            printed += 1
            let seconds = Double(update.pts - decoded.start) / 90_000
            let rows = update.screen.rows.map { "row \($0.row + 1): \($0.text)" }
            print(String(format: "  +%6.2f s  ", seconds) + rows.joined(separator: " | "))
        }
    }

    @Test(.enabled(if: exists("hdhr-9.1.ts"), "needs localdata/captures/hdhr-9.1.ts"))
    func capture91DecodesCleanly() throws {
        // This capture's field 1 is all null padding and field 2 only XDS, so there may be nothing to show.
        let decoded = try Self.decode("hdhr-9.1.ts")
        #expect(decoded.pictures > 300)
        #expect(decoded.updates.allSatisfy { $0.screen.rows.count <= CaptionScreen.rowCount })
        Self.report("hdhr-9.1", decoded)
    }

    @Test(.enabled(if: exists("hdhr-4.1.ts"), "needs localdata/captures/hdhr-4.1.ts"))
    func capture41HasCaptions() throws {
        let decoded = try Self.decode("hdhr-4.1.ts")
        #expect(decoded.updates.contains { !$0.screen.isEmpty })
        #expect(decoded.services.contains(.cc1))
        Self.report("hdhr-4.1", decoded)
    }

    @Test(.enabled(if: exists("hdhr-7.1.ts"), "needs localdata/captures/hdhr-7.1.ts"))
    func capture71HasCaptions() throws {
        let decoded = try Self.decode("hdhr-7.1.ts")
        #expect(decoded.updates.contains { !$0.screen.isEmpty })
        #expect(decoded.services.contains(.cc1))
        Self.report("hdhr-7.1", decoded)
    }
}
