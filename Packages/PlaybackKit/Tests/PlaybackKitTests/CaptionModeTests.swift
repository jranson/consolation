import Foundation
import Testing
@testable import PlaybackKit

struct CaptionModeTests {
    typealias Bytes = CaptionBytes

    @Test func popOnShowsOnlyAtEndOfCaption() {
        let feeder = CaptionFeeder()
        let loading = feeder.send(Bytes.control(Bytes.rcl) + Bytes.pac(row: 15) + Bytes.text("HELLO"))
        #expect(!loading)
        #expect(feeder.screen.isEmpty)

        #expect(feeder.send(Bytes.control(Bytes.eoc)))
        #expect(feeder.screen.lines == ["HELLO"])
        #expect(feeder.screen.rows.first?.row == 14)
        #expect(feeder.screen.rows.first?.runs.first?.column == 0)

        // The next caption builds off screen while the first stays up.
        #expect(!feeder.send(Bytes.control(Bytes.enm) + Bytes.control(Bytes.rcl) + Bytes.pac(row: 14)
                             + Bytes.text("WORLD")))
        #expect(feeder.screen.lines == ["HELLO"])
        #expect(feeder.send(Bytes.control(Bytes.eoc)))
        #expect(feeder.screen.lines == ["WORLD"])
        #expect(feeder.screen.rows.first?.row == 13)

        #expect(feeder.send(Bytes.control(Bytes.edm)))
        #expect(feeder.screen.isEmpty)
    }

    @Test func endOfCaptionSwapsMemories() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rcl) + Bytes.pac(row: 1) + Bytes.text("FIRST") + Bytes.control(Bytes.eoc))
        // Without ENM, the old caption is back in non-displayed memory and the next EOC shows it again.
        feeder.send(Bytes.control(Bytes.eoc))
        #expect(feeder.screen.isEmpty)
        feeder.send(Bytes.control(Bytes.eoc))
        #expect(feeder.screen.lines == ["FIRST"])
    }

    @Test func popOnCaptionWithTwoRows() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rcl) + Bytes.pac(row: 14, indent: 4) + Bytes.text("TOP LINE")
                    + Bytes.pac(row: 15, indent: 8) + Bytes.text("BOTTOM") + Bytes.control(Bytes.eoc))
        #expect(feeder.screen.lines == ["TOP LINE", "BOTTOM"])
        #expect(feeder.screen.rows.map(\.row) == [13, 14])
        #expect(feeder.screen.rows.map { $0.runs.first?.column } == [4, 8])
    }

    @Test func rollUpScrollsWithinItsWindow() {
        let feeder = CaptionFeeder()
        #expect(feeder.send(Bytes.control(Bytes.ru2) + Bytes.pac(row: 15) + Bytes.text("ONE")))
        #expect(feeder.screen.lines == ["ONE"])
        feeder.send(Bytes.control(Bytes.carriageReturn) + Bytes.text("TWO"))
        #expect(feeder.screen.lines == ["ONE", "TWO"])
        #expect(feeder.screen.rows.map(\.row) == [13, 14])
        feeder.send(Bytes.control(Bytes.carriageReturn) + Bytes.text("THREE"))
        #expect(feeder.screen.lines == ["TWO", "THREE"])
        #expect(feeder.screen.rows.map(\.row) == [13, 14])

        // RU3 keeps what is shown and lets a third row accumulate.
        feeder.send(Bytes.control(Bytes.ru3) + Bytes.control(Bytes.carriageReturn) + Bytes.text("FOUR"))
        #expect(feeder.screen.lines == ["TWO", "THREE", "FOUR"])
        feeder.send(Bytes.control(Bytes.carriageReturn) + Bytes.text("FIVE"))
        #expect(feeder.screen.lines == ["THREE", "FOUR", "FIVE"])

        // Back to RU2: rows above the shorter window are erased.
        feeder.send(Bytes.control(Bytes.ru2))
        #expect(feeder.screen.lines == ["FOUR", "FIVE"])
    }

    @Test func rollUpFourAndBaseRowMove() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.ru4) + Bytes.pac(row: 15) + Bytes.text("A"))
        for word in ["B", "C", "D", "E"] {
            feeder.send(Bytes.control(Bytes.carriageReturn) + Bytes.text(word))
        }
        #expect(feeder.screen.lines == ["B", "C", "D", "E"])
        #expect(feeder.screen.rows.map(\.row) == [11, 12, 13, 14])

        // A PAC to another row moves the whole window there; its indent puts the cursor back at column 0.
        feeder.send(Bytes.pac(row: 5) + Bytes.text("F"))
        #expect(feeder.screen.lines == ["B", "C", "D", "F"])
        #expect(feeder.screen.rows.map(\.row) == [1, 2, 3, 4])
    }

    @Test func rollUpBaseRowIsKeptBelowTheWindowDepth() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.ru3) + Bytes.pac(row: 1) + Bytes.text("X"))
        #expect(feeder.screen.rows.map(\.row) == [2])
    }

    @Test func enteringRollUpErasesPopOnCaption() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rcl) + Bytes.pac(row: 2) + Bytes.text("POP") + Bytes.control(Bytes.eoc))
        #expect(feeder.send(Bytes.control(Bytes.ru2)))
        #expect(feeder.screen.isEmpty)
        feeder.send(Bytes.text("ROLL"))
        #expect(feeder.screen.lines == ["ROLL"])
        #expect(feeder.screen.rows.first?.row == 14)
    }

    @Test func carriageReturnOutsideRollUpDoesNothing() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rdc) + Bytes.pac(row: 3) + Bytes.text("PAINT"))
        #expect(!feeder.send(Bytes.control(Bytes.carriageReturn)))
        #expect(feeder.screen.lines == ["PAINT"])
    }

    @Test func paintOnDrawsEachCharacterAsItArrives() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rdc) + Bytes.pac(row: 8, indent: 12))
        #expect(feeder.screen.isEmpty)
        #expect(feeder.send(Bytes.text("AB")))
        #expect(feeder.screen.lines == ["AB"])
        #expect(feeder.screen.rows.first?.row == 7)
        #expect(feeder.screen.rows.first?.runs.first?.column == 12)
        #expect(feeder.send(Bytes.text("C")))
        #expect(feeder.screen.lines == ["ABC"])
    }

    @Test func charactersBeforeAnyModeAreDropped() {
        let feeder = CaptionFeeder()
        #expect(!feeder.send(Bytes.pac(row: 15) + Bytes.text("LOST")))
        #expect(feeder.screen.isEmpty)
    }

    @Test func textModeCharactersAreNotCaptions() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rdc) + Bytes.pac(row: 15) + Bytes.text("CAP"))
        feeder.send(Bytes.control((0x14, 0x2A)) + Bytes.text("TEXT SERVICE"))
        #expect(feeder.screen.lines == ["CAP"])
    }

    @Test func staleCaptionTimesOut() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rcl) + Bytes.pac(row: 15) + Bytes.text("STALE") + Bytes.control(Bytes.eoc))
        #expect(!feeder.screen.isEmpty)
        // The caption went up with the first of the two EOC transmissions.
        let shown = feeder.pts - CaptionFeeder.frameTicks
        #expect(!feeder.decode(Data(), at: shown + CEA608Decoder.defaultStaleTimeout - 1))
        #expect(!feeder.screen.isEmpty)
        #expect(feeder.decode(Data(), at: shown + CEA608Decoder.defaultStaleTimeout))
        #expect(feeder.screen.isEmpty)
    }

    @Test func staleTimeoutRestartsOnBackwardJump() {
        let feeder = CaptionFeeder()
        feeder.decoder.staleTimeout = 1_000
        let caption = Bytes.control(Bytes.rdc) + Bytes.pac(row: 15) + Bytes.text("HI")
        feeder.decode(Bytes.ccData(caption), at: 50_000)
        #expect(!feeder.decode(Data(), at: 10))
        #expect(!feeder.decode(Data(), at: 900))
        #expect(feeder.decode(Data(), at: 1_010))
        #expect(feeder.screen.isEmpty)
    }

    @Test func resetForgetsEverything() {
        let feeder = CaptionFeeder()
        feeder.send(Bytes.control(Bytes.rdc) + Bytes.pac(row: 15) + Bytes.text("GONE"))
        feeder.decoder.reset()
        #expect(feeder.screen.isEmpty)
        // Mode is forgotten too, so characters need a new mode command.
        feeder.send(Bytes.text("X"))
        #expect(feeder.screen.isEmpty)
    }
}
