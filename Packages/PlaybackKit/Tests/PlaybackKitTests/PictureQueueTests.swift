//
//  PictureQueueTests.swift
//  PlaybackKitTests
//

import CoreMedia
import Foundation
import Testing
@testable import PlaybackKit

#if !os(tvOS)
struct PictureQueueTests {
    private let pictures: [CompressedPicture]

    init() throws {
        pictures = SyntheticVideoFixture.pictures(in: try SyntheticVideoFixture.data("testsrc-480i"))
    }

    @Test func keepsOrderAcrossCompaction() {
        var queue = PictureQueue()
        var expected: [Int64] = []
        var taken: [Int64] = []
        // Enough rounds to pass the compaction threshold several times with pictures still waiting.
        for round in 0..<60 {
            queue.append(contentsOf: pictures)
            expected += pictures.map(\.info.pts)
            for _ in 0..<(round % 3 == 0 ? 15 : 5) {
                guard let picture = queue.popFirst() else { break }
                taken.append(picture.info.pts)
            }
            #expect(queue.count == expected.count - taken.count)
        }
        while let picture = queue.popFirst() { taken.append(picture.info.pts) }
        #expect(taken == expected)
        #expect(queue.isEmpty)
        #expect(queue.popFirst() == nil)
    }

    /// A taken picture's sample buffer is let go at once, not when the storage is next compacted.
    @Test func releasesTakenPictures() throws {
        var queue = PictureQueue()
        let sample = try #require(pictures.first?.sample)
        queue.append(contentsOf: pictures)
        let held = CFGetRetainCount(sample)
        _ = queue.popFirst()
        #expect(CFGetRetainCount(sample) == held - 1)
        queue.removeAll()
        #expect(queue.isEmpty)
    }
}
#endif
