import Foundation
import Testing
@testable import PlaybackKit

struct CaptionCodeTests {
    typealias Bytes = CaptionBytes

    /// A paint-on decoder with the pen at row 15, column 0, so every write shows at once.
    private func painting(_ pairs: [Bytes.Pair] = Bytes.pac(row: 15)) -> CaptionFeeder {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rdc) + pairs)
        return feeder
    }

    @Test func everyPreambleRowMapsBack() {
        for row in 1...15 {
            let feeder = painting(Bytes.pac(row: row))
            feeder.send(Bytes.text("R"))
            #expect(feeder.screen.rows.map(\.row) == [row - 1])
        }
    }

    @Test func preambleIndentsAndStyles() {
        let feeder = painting(Bytes.pac(row: 3, indent: 28, underline: true))
        feeder.send(Bytes.text("UL"))
        feeder.send(Bytes.pac(row: 4, color: .cyan) + Bytes.text("CY"))
        feeder.send(Bytes.pac(row: 5, italic: true) + Bytes.text("IT"))
        let rows = feeder.screen.rows
        #expect(rows.map(\.row) == [2, 3, 4])
        #expect(rows[0].runs == [CaptionRun(column: 28, text: "UL", style: CaptionStyle(underline: true))])
        #expect(rows[1].runs == [CaptionRun(column: 0, text: "CY", style: CaptionStyle(color: .cyan))])
        #expect(rows[2].runs == [CaptionRun(column: 0, text: "IT", style: CaptionStyle(italic: true))])
    }

    @Test func midRowCodesChangeStyleAfterASpace() {
        let feeder = painting()
        feeder.send(Bytes.text("A") + Bytes.midRow(color: .red) + Bytes.text("B"))
        feeder.send(Bytes.midRow(italic: true, underline: true) + Bytes.text("C"))
        feeder.send(Bytes.midRow(color: .yellow) + Bytes.text("D"))
        #expect(feeder.screen.lines == ["A B C D"])
        let runs = feeder.screen.rows.first?.runs ?? []
        #expect(runs == [
            CaptionRun(column: 0, text: "A"),
            CaptionRun(column: 1, text: " B", style: CaptionStyle(color: .red)),
            // Italics keep the color; a color code turns italics off.
            CaptionRun(column: 3, text: " C", style: CaptionStyle(color: .red, italic: true, underline: true)),
            CaptionRun(column: 5, text: " D", style: CaptionStyle(color: .yellow))
        ])
    }

    @Test func tabOffsetsMoveTheCursor() {
        let feeder = painting(Bytes.pac(row: 15, indent: 4))
        feeder.send(Bytes.control((0x17, 0x22)) + Bytes.text("X"))
        feeder.send(Bytes.control((0x17, 0x23)) + Bytes.text("Y"))
        feeder.send(Bytes.control((0x17, 0x21)) + Bytes.text("Z"))
        let runs = feeder.screen.rows.first?.runs ?? []
        #expect(runs.map(\.column) == [6, 10, 12])
        #expect(feeder.screen.lines == ["X   Y Z"])
    }

    @Test func backspaceAndDeleteToEndOfRow() {
        let feeder = painting()
        feeder.send(Bytes.text("ABC") + Bytes.control(Bytes.backspace))
        #expect(feeder.screen.lines == ["AB"])
        feeder.send(Bytes.text("CDEF") + Bytes.pac(row: 15) + Bytes.control((0x17, 0x22)) + Bytes.control(Bytes.der))
        #expect(feeder.screen.lines == ["AB"])
        // Backspace at column 0 does nothing.
        feeder.send(Bytes.pac(row: 15) + Bytes.control(Bytes.backspace))
        #expect(feeder.screen.lines == ["AB"])
    }

    @Test func lastColumnIsOverwritten() {
        let feeder = painting(Bytes.pac(row: 15, indent: 28))
        feeder.send(Bytes.text("ABCDEF"))
        #expect(feeder.screen.lines == ["ABCF"])
        #expect(feeder.screen.rows.first?.runs.first?.column == 28)
        feeder.send(Bytes.control(Bytes.backspace))
        #expect(feeder.screen.lines == ["ABC"])
    }

    @Test func basicSetDiffersFromASCII() {
        let feeder = painting()
        feeder.send([(0x2A, 0x5C), (0x5E, 0x5F), (0x60, 0x7B), (0x7C, 0x7D), (0x7E, 0x7F), (0x27, 0x41)])
        #expect(feeder.screen.lines == ["áéíóúç÷Ññ█'A"])
    }

    @Test func specialCharacters() {
        let feeder = painting()
        for second in UInt8(0x30)...0x3F {
            feeder.send(Bytes.control((0x11, second)))
        }
        // 0x39 is the transparent space: an empty, unboxed cell.
        #expect(feeder.screen.lines == ["®°½¿™¢£♪à èâêîôû"])
        #expect(feeder.screen.rows.first?.runs.map(\.column) == [0, 10])
    }

    @Test func extendedCharactersReplaceTheirFallback() {
        let feeder = painting()
        feeder.send(Bytes.text("E") + Bytes.control((0x12, 0x21)))
        feeder.send(Bytes.text("s") + Bytes.control((0x13, 0x34)))
        feeder.send(Bytes.text("\"") + Bytes.control((0x12, 0x2E)))
        feeder.send(Bytes.text("+") + Bytes.control((0x13, 0x3C)))
        #expect(feeder.screen.lines == ["Éß\u{201C}┌"])
    }

    @Test func extendedCharacterTablesAreComplete() {
        for set in 0...1 {
            for second in UInt8(0x20)...0x3F {
                #expect(CEA608CharacterSet.extended(set: set, second) != nil)
            }
        }
        #expect(CEA608CharacterSet.extended(set: 0, 0x2B) == "©")
        #expect(CEA608CharacterSet.extended(set: 1, 0x30) == "Ä")
    }

    @Test func doubledControlCodesActOnce() {
        let feeder = painting()
        feeder.send(Bytes.text("ABCD") + Bytes.control(Bytes.backspace))
        #expect(feeder.screen.lines == ["ABC"])
        // Two transmissions of the doubled code are two backspaces.
        feeder.send(Bytes.control(Bytes.backspace) + Bytes.control(Bytes.backspace))
        #expect(feeder.screen.lines == ["A"])
        // A null pair between the copies does not split them.
        feeder.send(Bytes.text("BC") + [Bytes.backspace, (0x00, 0x00), Bytes.backspace])
        #expect(feeder.screen.lines == ["AB"])
        // A character between them does: both apply.
        feeder.send([Bytes.backspace] + Bytes.text("Z") + [Bytes.backspace])
        #expect(feeder.screen.lines == ["A"])
    }

    @Test func doubledEndOfCaptionFlipsOnce() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rcl) + Bytes.pac(row: 15) + Bytes.text("ONCE") + Bytes.control(Bytes.eoc))
        #expect(feeder.screen.lines == ["ONCE"])
    }

    @Test func parityErrorsAreIgnored() {
        let feeder = painting()
        // A character with bad parity is dropped; its partner still prints.
        feeder.sendRaw([(Bytes.odd(0x41), Bytes.corrupt(0x42)), (Bytes.corrupt(0x43), Bytes.odd(0x44))])
        #expect(feeder.screen.lines == ["AD"])
        // A control code with bad parity is ignored, and the intact copy that follows still applies.
        feeder.sendRaw([(Bytes.corrupt(0x14), Bytes.odd(0x21)), (Bytes.odd(0x14), Bytes.odd(0x21))])
        #expect(feeder.screen.lines == ["A"])
        feeder.sendRaw([(Bytes.odd(0x14), Bytes.corrupt(0x2C))])
        #expect(feeder.screen.lines == ["A"])
    }

    @Test func invalidTripletsAreSkipped() {
        let feeder = painting()
        let caption = Bytes.ccData(Bytes.text("OK"))
        // cc_valid clear, a field 2 pair and a DTVCC triplet around the real one.
        let data = Data([0xF8, Bytes.odd(0x58), Bytes.odd(0x58), 0xFD, Bytes.odd(0x59), Bytes.odd(0x59),
                         0xFF, 0x41, 0x42]) + caption + Data([0xFE, 0x00, 0x00, 0x01])
        feeder.decode(data, at: 99_000)
        #expect(feeder.screen.lines == ["OK"])
    }

    @Test func secondDataChannelIsSelectedByControlCodes() {
        let broadcast = Bytes.control(Bytes.rdc) + Bytes.pac(row: 15) + Bytes.text("ONE")
            + Bytes.control(Bytes.rdc, channel: 2) + Bytes.pac(row: 14, channel: 2) + Bytes.text("TWO")
            + Bytes.pac(row: 15) + Bytes.control((0x17, 0x23)) + Bytes.text("1")
        let first = CaptionFeeder(service: .cc1)
        first.send(broadcast)
        #expect(first.screen.lines == ["ONE1"])
        let second = CaptionFeeder(service: .cc2)
        second.send(broadcast)
        #expect(second.screen.lines == ["TWO"])
        #expect(second.screen.rows.first?.row == 13)
    }

    @Test func fieldTwoCarriesCC3() {
        let pairs = Bytes.control((0x15, 0x29)) + Bytes.pac(row: 15) + Bytes.text("FIELD TWO")
        var decoder = CEA608Decoder(service: .cc3)
        var cc1 = CEA608Decoder(service: .cc1)
        for (index, pair) in pairs.enumerated() {
            let data = Bytes.ccData([pair], field: 2)
            decoder.decode(ccData: data, pts: Int64(index) * 3_003)
            cc1.decode(ccData: data, pts: Int64(index) * 3_003)
        }
        #expect(decoder.screen.lines == ["FIELD TWO"])
        #expect(cc1.screen.isEmpty)
    }

    @Test func xdsPacketsAreIgnored() {
        let feeder = CaptionFeeder(service: .cc3)
        feeder.send(Bytes.control(Bytes.rdc) + Bytes.pac(row: 15) + Bytes.text("CAP"))
        // An XDS packet: class/type, informational characters, then end and checksum.
        feeder.send([(0x01, 0x03)] + Bytes.text("PROGRAM NAME") + [(0x0F, 0x1D)])
        #expect(feeder.screen.lines == ["CAP"])
        feeder.send(Bytes.text("TION"))
        #expect(feeder.screen.lines == ["CAPTION"])
    }
}
