//
//  DecodeTierGateTests.swift
//  PlaybackKitTests
//
//  The decode tiers as applied before the decoder: which pictures pass at each tier, and that raising a tier never
//  feeds the decoder a picture whose references were dropped.
//

import MPEGTS
import Testing
@testable import PlaybackKit

struct DecodeTierGateTests {
    /// Two GOPs in decode order, the second open (its leading B pictures reference the first GOP's last P).
    private static let gops: [MPEG2PictureType] = [
        .intra, .predicted, .bidirectional, .bidirectional, .predicted, .bidirectional, .bidirectional,
        .intra, .bidirectional, .bidirectional, .predicted, .bidirectional, .bidirectional
    ]

    private static func letters(_ types: [MPEG2PictureType]) -> String {
        String(types.map { type -> Character in
            switch type {
            case .intra: "I"
            case .predicted: "P"
            case .bidirectional: "B"
            }
        })
    }

    private static func passed(_ tier: DecodeTier, _ types: [MPEG2PictureType] = gops) -> String {
        var gate = DecodeTierGate()
        gate.set(tier)
        return letters(types.filter { gate.admit($0) })
    }

    @Test func eachTierPassesItsPictures() {
        #expect(Self.passed(.single) == "IPBBPBBIBBPBB")
        #expect(Self.passed(.full(fieldRate: false)) == "IPBBPBBIBBPBB")
        #expect(Self.passed(.reduced) == "IPPIP")
        #expect(Self.passed(.keyframesOnly) == "II")
        #expect(Self.passed(.suspended).isEmpty)
    }

    /// Runs the GOPs with `tier` from the start and `raised` from picture `index` on.
    private static func switched(from tier: DecodeTier, to raised: DecodeTier, at index: Int) -> String {
        var gate = DecodeTierGate()
        gate.set(tier)
        var output = ""
        for (position, type) in gops.enumerated() {
            if position == index { gate.set(raised) }
            if gate.admit(type) { output += letters([type]) }
        }
        return output
    }

    @Test func raisingFromSuspendedResumesAtTheNextIntraWithoutItsLeadingB() {
        // Suspended until the second P of the first GOP: nothing until the next I, then its two leading B pictures
        // (which reference the P that wasn't decoded) are dropped too.
        #expect(Self.switched(from: .suspended, to: .single, at: 4) == "IPBB")
        #expect(Self.switched(from: .suspended, to: .reduced, at: 4) == "IP")
    }

    @Test func raisingFromKeyframesOnlyWaitsForTheNextIntra() {
        #expect(Self.switched(from: .keyframesOnly, to: .full(fieldRate: false), at: 1) == "IIPBB")
        // Raised exactly at an I picture: it resumes there.
        #expect(Self.switched(from: .keyframesOnly, to: .single, at: 7) == "IIPBB")
    }

    @Test func raisingFromReducedResumesAtOnce() {
        // I and P pictures were all decoded, so every reference is there: B pictures pass from the next one on.
        #expect(Self.switched(from: .reduced, to: .single, at: 5) == "IPPBBIBBPBB")
    }

    @Test func loweringTakesEffectAtOnce() {
        #expect(Self.switched(from: .single, to: .reduced, at: 3) == "IPBPIP")
        #expect(Self.switched(from: .single, to: .keyframesOnly, at: 3) == "IPBI")
        #expect(Self.switched(from: .single, to: .suspended, at: 3) == "IPB")
    }

    @Test func aRaiseLoweredAgainBeforeTheIntraStillWaits() {
        var gate = DecodeTierGate()
        gate.set(.suspended)
        gate.set(.single)
        gate.set(.reduced)
        #expect(gate.awaitingIntra)
        let admitted = [MPEG2PictureType.predicted, .intra, .predicted].map { gate.admit($0) }
        #expect(admitted == [false, true, true])
    }

    @Test func aNewTimelineClearsTheWait() {
        var gate = DecodeTierGate()
        gate.set(.keyframesOnly)
        gate.set(.single)
        #expect(gate.awaitingIntra)
        gate.restart()
        #expect(!gate.awaitingIntra)
        let admitted = gate.admit(.predicted)
        #expect(admitted)
    }
}
