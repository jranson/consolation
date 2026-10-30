//
//  PictureQueue.swift
//  PlaybackKit
//
//  The compressed pictures waiting for the decoder, first in, first out. Taking the first picture moves a head index
//  instead of shifting every picture behind it; a taken slot is cleared at once, so its sample buffer (and pooled
//  memory) goes back as soon as the decoder is done with it. The storage is compacted when the queue empties, or
//  when the taken slots outnumber the waiting ones.
//

import Foundation

nonisolated struct PictureQueue {
    private var slots: [CompressedPicture?] = []
    private var head = 0

    var count: Int { slots.count - head }
    var isEmpty: Bool { head == slots.count }

    mutating func append(contentsOf pictures: [CompressedPicture]) {
        for picture in pictures { slots.append(picture) }
    }

    /// Takes the first picture, or nil when the queue is empty.
    mutating func popFirst() -> CompressedPicture? {
        guard head < slots.count else { return nil }
        let picture = slots[head]
        slots[head] = nil
        head += 1
        if head == slots.count {
            slots.removeAll(keepingCapacity: true)
            head = 0
        } else if head >= 64, head * 2 >= slots.count {
            slots.removeSubrange(0..<head)
            head = 0
        }
        return picture
    }

    mutating func removeAll() {
        slots.removeAll(keepingCapacity: true)
        head = 0
    }
}
