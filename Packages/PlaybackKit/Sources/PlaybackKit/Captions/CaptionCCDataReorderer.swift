//
//  CaptionCCDataReorderer.swift
//  PlaybackKit
//
//  MPEG-2 pictures, and so their A/53 `cc_data`, arrive in decode order; CEA-608 bytes must be decoded in display
//  order or B pictures scramble the text. This holds a small PTS-sorted window and releases the earliest entries.
//

import Foundation

nonisolated public struct CaptionCCDataReorderer: Sendable {
    /// One picture's `cc_data` and its presentation time (90 kHz).
    public struct Entry: Sendable, Equatable {
        public var pts: Int64
        public var data: Data

        public init(pts: Int64, data: Data) {
            self.pts = pts
            self.data = data
        }
    }

    /// Entries older than the last released one by more than this (90 kHz) mean the timeline jumped backwards.
    public static let jumpThreshold: Int64 = 90_000

    /// How many pictures are held back. Two cover IBBP GOPs; four leave room for deeper reordering.
    public let window: Int
    private var pending: [Entry] = []
    private var lastReleased: Int64?

    public init(window: Int = 4) {
        self.window = max(1, window)
    }

    /// Number of entries held back.
    public var count: Int { pending.count }

    public var isEmpty: Bool { pending.isEmpty }

    /// Adds one picture's `cc_data` (in decode order) and returns the entries now due, in presentation order.
    public mutating func push(pts: Int64, data: Data) -> [Entry] {
        var released: [Entry] = []
        if let last = lastReleased, pts < last {
            if last - pts > Self.jumpThreshold {
                // A backward timestamp jump: drain the old timeline before starting the new one.
                released = flush()
            } else {
                // Arrived too late for the window; releasing it now loses less than dropping it.
                return [Entry(pts: pts, data: data)]
            }
        }
        let index = pending.firstIndex { $0.pts > pts } ?? pending.endIndex
        pending.insert(Entry(pts: pts, data: data), at: index)
        while pending.count > window {
            let entry = pending.removeFirst()
            lastReleased = entry.pts
            released.append(entry)
        }
        return released
    }

    /// Releases everything held, in presentation order (end of stream).
    public mutating func flush() -> [Entry] {
        let released = pending
        pending.removeAll()
        lastReleased = nil
        return released
    }

    /// Drops everything held, as after a discontinuity.
    public mutating func reset() {
        pending.removeAll()
        lastReleased = nil
    }
}
