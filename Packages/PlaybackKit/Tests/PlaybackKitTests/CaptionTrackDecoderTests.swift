import Foundation
import Testing
@testable import PlaybackKit

struct CaptionTrackDecoderTests {
    typealias Bytes = CaptionBytes

    /// Display-order frame numbers in the decode order of an IBBP GOP (M = 3): I0 P3 B1 B2 P6 B4 B5 P9 B7 B8.
    private static let decodeOrder: [Int64] = [0, 3, 1, 2, 6, 4, 5, 9, 7, 8]

    private func entry(_ frame: Int64) -> CaptionCCDataReorderer.Entry {
        CaptionCCDataReorderer.Entry(pts: frame * 3_003, data: Data([UInt8(frame)]))
    }

    @Test func reordererReleasesInPresentationOrder() {
        for window in [2, 3, 4] {
            var reorderer = CaptionCCDataReorderer(window: window)
            var released: [CaptionCCDataReorderer.Entry] = []
            for frame in Self.decodeOrder {
                let next = entry(frame)
                released += reorderer.push(pts: next.pts, data: next.data)
            }
            #expect(reorderer.count == window)
            released += reorderer.flush()
            #expect(released == (0...9).map(entry))
            #expect(reorderer.isEmpty)
        }
    }

    @Test func reordererHoldsOnlyItsWindow() {
        var reorderer = CaptionCCDataReorderer(window: 3)
        #expect(reorderer.push(pts: 0, data: Data()).isEmpty)
        #expect(reorderer.push(pts: 9_009, data: Data()).isEmpty)
        #expect(reorderer.push(pts: 3_003, data: Data()).isEmpty)
        #expect(reorderer.push(pts: 6_006, data: Data()).map(\.pts) == [0])
    }

    @Test func reordererReleasesLateEntriesImmediately() {
        var reorderer = CaptionCCDataReorderer(window: 1)
        _ = reorderer.push(pts: 6_006, data: Data())
        #expect(reorderer.push(pts: 9_009, data: Data()).map(\.pts) == [6_006])
        // 3003 is older than what was released but within the jump threshold: it is let through as is.
        #expect(reorderer.push(pts: 3_003, data: Data()).map(\.pts) == [3_003])
        #expect(reorderer.count == 1)
    }

    @Test func reordererDrainsOnBackwardJump() {
        var reorderer = CaptionCCDataReorderer(window: 2)
        for pts: Int64 in [900_000, 903_003, 906_006] {
            _ = reorderer.push(pts: pts, data: Data())
        }
        let released = reorderer.push(pts: 0, data: Data())
        #expect(released.map(\.pts) == [903_003, 906_006])
        #expect(reorderer.count == 1)
    }

    @Test func reordererReset() {
        var reorderer = CaptionCCDataReorderer(window: 4)
        _ = reorderer.push(pts: 1, data: Data())
        reorderer.reset()
        #expect(reorderer.isEmpty)
        #expect(reorderer.flush().isEmpty)
    }

    /// One caption pair per display frame, sent with the pictures in decode order.
    private func decodeOrderPictures(_ pairs: [Bytes.Pair]) -> [(pts: Int64, data: Data)] {
        var pictures: [(pts: Int64, data: Data)] = []
        var base: Int64 = 0
        while base < Int64(pairs.count) {
            for offset in Self.decodeOrder {
                let frame = base + offset
                let data = frame < Int64(pairs.count) ? Bytes.ccData([pairs[Int(frame)]]) : Bytes.ccData([(0, 0)])
                pictures.append((frame * 3_003, data))
            }
            base += 10
        }
        return pictures
    }

    @Test func trackDecoderUnscramblesDecodeOrder() {
        let pairs = Bytes.control(Bytes.rcl) + Bytes.pac(row: 15) + Bytes.text("HELLO WORLD")
            + Bytes.control(Bytes.eoc)
        var track = CaptionTrackDecoder()
        var updates: [CaptionTrackDecoder.Update] = []
        for picture in decodeOrderPictures(pairs) {
            updates += track.feedUpdates(pts: picture.pts, captionData: picture.data)
        }
        updates += track.flush()
        #expect(updates.count == 1)
        #expect(updates.first?.screen.lines == ["HELLO WORLD"])
        // The caption takes effect at the presentation time of the first EOC transmission.
        #expect(updates.first?.pts == Int64(pairs.count - 2) * 3_003)
        #expect(track.screen.lines == ["HELLO WORLD"])
        #expect(track.servicesWithCaptions == [.cc1])
    }

    @Test func decodingInDecodeOrderWouldScramble() {
        let pairs = Bytes.control(Bytes.rdc) + Bytes.pac(row: 15) + Bytes.text("ABCDEFGH")
        var scrambled = CEA608Decoder()
        for picture in decodeOrderPictures(pairs) {
            scrambled.decode(ccData: picture.data, pts: picture.pts)
        }
        #expect(scrambled.screen.lines != ["ABCDEFGH"])

        var track = CaptionTrackDecoder(reorderWindow: 2)
        var last: CaptionScreen?
        for picture in decodeOrderPictures(pairs) {
            last = track.feed(pts: picture.pts, captionData: picture.data) ?? last
        }
        last = track.flush().last?.screen ?? last
        #expect(last?.lines == ["ABCDEFGH"])
    }

    @Test func serviceSelectionAndReset() {
        let pairs = Bytes.control(Bytes.rdc) + Bytes.pac(row: 15) + Bytes.text("ENGLISH")
            + Bytes.control(Bytes.rdc, channel: 2) + Bytes.pac(row: 15, channel: 2) + Bytes.text("ESPANOL")
        var track = CaptionTrackDecoder(reorderWindow: 1)
        var updates: [CaptionTrackDecoder.Update] = []
        for (index, pair) in pairs.enumerated() {
            updates += track.feedUpdates(pts: Int64(index) * 3_003, captionData: Bytes.ccData([pair]))
        }
        updates += track.flush()
        #expect(updates.last?.screen.lines == ["ENGLISH"])
        #expect(track.servicesWithCaptions == [.cc1, .cc2])
        let spanish = track.select(.cc2)
        #expect(spanish.lines == ["ESPANOL"])
        #expect(track.service == .cc2)
        let silent = track.select(.cc3)
        #expect(silent.isEmpty)

        track.select(.cc1)
        track.reset()
        #expect(track.screen.isEmpty)
        #expect(track.servicesWithCaptions.isEmpty)
        let nothing = track.feed(pts: 0, captionData: nil)
        #expect(nothing == nil)
    }

    @Test func gridLayoutCentersTheFourByThreeSafeArea() {
        let grid = CaptionGridLayout(container: CGSize(width: 1_920, height: 1_080), videoAspectRatio: 16.0 / 9.0)
        // 4:3 region 1440 × 1080, safe area 80%: 1152 × 864.
        func close(_ lhs: CGFloat, _ rhs: CGFloat) -> Bool { abs(lhs - rhs) < 1e-6 }
        #expect(close(grid.cellWidth, 36))
        #expect(close(grid.rowHeight, 57.6))
        #expect(close(grid.origin.x, 384) && close(grid.origin.y, 108))
        // A 4:3 picture pillarboxed in a 16:9 container gives the same region.
        let boxed = CaptionGridLayout(container: CGSize(width: 1_920, height: 1_080), videoAspectRatio: 4.0 / 3.0)
        #expect(close(boxed.cellWidth, grid.cellWidth) && close(boxed.origin.x, grid.origin.x))
        #expect(grid.fontSize > 0)
    }

    @Test func screenRunsSplitOnStyleAndGaps() {
        var cells = [CaptionCell?](repeating: nil, count: 15 * 32)
        let red = CaptionStyle(color: .red)
        cells[32 * 2 + 1] = CaptionCell(character: "a")
        cells[32 * 2 + 2] = CaptionCell(character: "b")
        cells[32 * 2 + 3] = CaptionCell(character: "c", style: red)
        cells[32 * 2 + 6] = CaptionCell(character: "d", style: red)
        let screen = CaptionScreen(cells: cells)
        #expect(screen.rows.count == 1)
        #expect(screen.rows[0].runs == [
            CaptionRun(column: 1, text: "ab"),
            CaptionRun(column: 3, text: "c", style: red),
            CaptionRun(column: 6, text: "d", style: red)
        ])
        #expect(screen.lines == ["abc  d"])
    }
}
