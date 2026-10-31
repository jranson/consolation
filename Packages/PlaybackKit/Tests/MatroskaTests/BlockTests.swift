//
//  BlockTests.swift
//  MatroskaTests
//
//  SimpleBlock and Block layouts: the header, the flags, and each of the three lacings, with frame sizes that don't
//  fit refused rather than read past the end.
//

import Foundation
@testable import Matroska
import Testing

struct BlockTests {
    private func parse(_ bytes: [UInt8]) -> MatroskaBlockLayout? {
        bytes.withUnsafeBufferPointer { MatroskaBlockLayout.parse($0) }
    }

    private func sizes(_ layout: MatroskaBlockLayout?) -> [Int]? {
        layout?.frames.map(\.count)
    }

    @Test func aBlockWithoutLacing() throws {
        let layout = try #require(parse([0x81, 0x00, 0x05, 0x81, 1, 2, 3]))
        #expect(layout.track == 1)
        #expect(layout.relativeTimestamp == 5)
        #expect(layout.isKeyframe && layout.isDiscardable)
        #expect(layout.frames == [4..<7])
        #expect(parse([0x81, 0xFF, 0xFE, 0x00, 9])?.relativeTimestamp == -2)
        #expect(parse([0x40, 0x02, 0x00, 0x00, 0x00])?.track == 2)
    }

    @Test func xiphLacing() {
        let data = [UInt8](repeating: 7, count: 256 + 2 + 3)
        let layout = parse([0x81, 0, 0, 0x02, 2, 0xFF, 0x01, 0x02] + data)
        #expect(sizes(layout) == [256, 2, 3])
        #expect(layout?.frames.first?.lowerBound == 8)
    }

    @Test func ebmlLacing() {
        // First size 3, then +1 (4); the last frame takes the remaining 5.
        let layout = parse([0x81, 0, 0, 0x06, 2, 0x83, 0xC0] + [UInt8](repeating: 1, count: 12))
        #expect(sizes(layout) == [3, 4, 5])
        // A difference that makes a size negative is refused.
        #expect(parse([0x81, 0, 0, 0x06, 2, 0x82, 0x80] + [UInt8](repeating: 1, count: 12)) == nil)
    }

    @Test func fixedLacing() {
        #expect(sizes(parse([0x81, 0, 0, 0x04, 1, 1, 2, 3, 4, 5, 6])) == [3, 3])
        #expect(parse([0x81, 0, 0, 0x04, 1, 1, 2, 3, 4, 5, 6, 7]) == nil)
    }

    @Test func malformedBlocksAreRefused() {
        #expect(parse([]) == nil)
        #expect(parse([0x81, 0x00]) == nil)
        #expect(parse([0xFF, 0, 0, 0]) == nil)
        // Lacing flags without the lace count, and Xiph sizes past the end.
        #expect(parse([0x81, 0, 0, 0x02]) == nil)
        #expect(parse([0x81, 0, 0, 0x02, 1, 0xFF, 0xFF, 0x10, 1, 2]) == nil)
        #expect(parse([0x81, 0, 0, 0x02, 1, 0xFF]) == nil)
    }

    @Test func blockGroupsReadTheirDurationAndReferences() throws {
        let block: [UInt8] = [0xA1, 0x85, 0x81, 0x00, 0x00, 0x00, 0x09]
        let duration: [UInt8] = [0x9B, 0x81, 0x28]
        let reference: [UInt8] = [0xFB, 0x81, 0xFE]
        let group = try #require((block + duration + reference).withUnsafeBufferPointer {
            MatroskaBlockGroup(group: $0).map { ($0.duration, $0.hasReference, $0.layout.frames.count) }
        })
        #expect(group.0 == 40)
        #expect(group.1)
        #expect(group.2 == 1)
        #expect(duration.withUnsafeBufferPointer { MatroskaBlockGroup(group: $0) } == nil)
    }
}
