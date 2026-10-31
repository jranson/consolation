//
//  MatroskaBlock.swift
//  Matroska
//
//  A SimpleBlock or a BlockGroup's Block: the track number, a timestamp relative to the Cluster's, flags, and one or
//  more frames. Several frames in one block are "laced" (Xiph, EBML or fixed-size lacing); each frame's size is
//  checked against what the block holds.
//

import Foundation

/// A block as the demuxer hands it on: where its frames are in the payload it lends with it.
nonisolated public struct MatroskaBlock: Sendable, Equatable {
    public var track: UInt64
    /// The first frame's timestamp, in timestamp units: the Cluster's timestamp plus the block's relative one.
    public var timestamp: Int64
    /// BlockDuration, in timestamp units, when the block has one.
    public var duration: Int64?
    /// A SimpleBlock's keyframe flag, or a Block without a ReferenceBlock.
    public var isKeyframe: Bool
    /// SimpleBlock's discardable flag: nothing references these frames.
    public var isDiscardable: Bool
    /// Each frame's bytes within the lent payload, in order.
    public var frames: [Range<Int>]
    /// The absolute offset of the Cluster the block is in.
    public var clusterOffset: Int64

    public init(track: UInt64, timestamp: Int64, duration: Int64? = nil, isKeyframe: Bool, isDiscardable: Bool = false,
                frames: [Range<Int>], clusterOffset: Int64) {
        self.track = track
        self.timestamp = timestamp
        self.duration = duration
        self.isKeyframe = isKeyframe
        self.isDiscardable = isDiscardable
        self.frames = frames
        self.clusterOffset = clusterOffset
    }
}

/// A block's header and frame layout, before the Cluster's timestamp is added.
nonisolated struct MatroskaBlockLayout: Equatable {
    var track: UInt64
    var relativeTimestamp: Int16
    var flags: UInt8
    var frames: [Range<Int>]

    /// SimpleBlock flags.
    var isKeyframe: Bool { (flags & 0x80) != 0 }
    var isDiscardable: Bool { (flags & 0x01) != 0 }

    /// Parses a SimpleBlock or Block payload; nil when it is malformed (a frame size that doesn't fit, or fixed-size
    /// lacing that doesn't divide evenly).
    static func parse(_ bytes: UnsafeBufferPointer<UInt8>) -> MatroskaBlockLayout? {
        guard let track = EBML.variableInteger(bytes, at: 0), !track.isAllOnes else { return nil }
        let headerEnd = track.length + 3
        guard headerEnd <= bytes.count else { return nil }
        let timestamp = Int16(bitPattern: (UInt16(bytes[track.length]) << 8) | UInt16(bytes[track.length + 1]))
        let flags = bytes[track.length + 2]
        let lacing = (flags >> 1) & 0x03
        guard lacing != 0 else {
            return MatroskaBlockLayout(track: track.value, relativeTimestamp: timestamp, flags: flags,
                                       frames: [headerEnd..<bytes.count])
        }
        guard headerEnd < bytes.count else { return nil }
        let count = Int(bytes[headerEnd]) + 1
        var offset = headerEnd + 1
        let sizes: [Int]?
        switch lacing {
        case 1: sizes = xiphSizes(bytes, count: count, offset: &offset)
        case 3: sizes = ebmlSizes(bytes, count: count, offset: &offset)
        default: sizes = fixedSizes(remaining: bytes.count - offset, count: count)
        }
        guard let sizes, let frames = ranges(sizes, from: offset, total: bytes.count) else { return nil }
        return MatroskaBlockLayout(track: track.value, relativeTimestamp: timestamp, flags: flags, frames: frames)
    }

    /// The sizes of all frames but the last: runs of 255 plus a final byte.
    private static func xiphSizes(_ bytes: UnsafeBufferPointer<UInt8>, count: Int, offset: inout Int) -> [Int]? {
        var sizes: [Int] = []
        for _ in 0..<(count - 1) {
            var size = 0
            while true {
                guard offset < bytes.count else { return nil }
                let byte = bytes[offset]
                offset += 1
                size += Int(byte)
                guard byte == 0xFF else { break }
            }
            sizes.append(size)
        }
        return sizes
    }

    /// The first size as a variable-length integer, each next one as a signed difference from the one before.
    private static func ebmlSizes(_ bytes: UnsafeBufferPointer<UInt8>, count: Int, offset: inout Int) -> [Int]? {
        guard count > 1 else { return [] }
        guard let first = EBML.variableInteger(bytes, at: offset), let firstSize = Int(exactly: first.value) else {
            return nil
        }
        offset += first.length
        var sizes = [firstSize]
        for _ in 0..<max(0, count - 2) {
            guard let delta = EBML.signedVariableInteger(bytes, at: offset), let previous = sizes.last else {
                return nil
            }
            offset += delta.length
            let (size, overflow) = Int64(previous).addingReportingOverflow(delta.value)
            guard !overflow, size >= 0, let next = Int(exactly: size) else { return nil }
            sizes.append(next)
        }
        return sizes
    }

    /// Every frame the same size; the sizes listed are all but the last, as for the other lacings.
    private static func fixedSizes(remaining: Int, count: Int) -> [Int]? {
        guard remaining >= 0, remaining % count == 0 else { return nil }
        return Array(repeating: remaining / count, count: count - 1)
    }

    /// The frames' ranges: the listed sizes, then the last frame takes what remains.
    private static func ranges(_ sizes: [Int], from start: Int, total: Int) -> [Range<Int>]? {
        var frames: [Range<Int>] = []
        var offset = start
        for size in sizes {
            guard size >= 0, size <= total - offset else { return nil }
            frames.append(offset..<(offset + size))
            offset += size
        }
        guard offset <= total else { return nil }
        frames.append(offset..<total)
        return frames
    }
}

/// A SimpleBlock, or a BlockGroup's Block with the group's duration and references.
nonisolated struct MatroskaBlockGroup {
    let layout: MatroskaBlockLayout
    /// The block's own payload, which the layout's frame ranges index into.
    let payload: UnsafeBufferPointer<UInt8>
    var duration: Int64?
    /// A ReferenceBlock is present: the block depends on another (it isn't a keyframe).
    var hasReference = false

    init?(simpleBlock payload: UnsafeBufferPointer<UInt8>) {
        guard let layout = MatroskaBlockLayout.parse(payload) else { return nil }
        self.layout = layout
        self.payload = payload
    }

    init?(group: UnsafeBufferPointer<UInt8>) {
        var block: UnsafeBufferPointer<UInt8>?
        var duration: Int64?
        var hasReference = false
        for child in EBMLChildren(group) {
            switch child.id {
            case MatroskaID.block: block = child.payload
            case MatroskaID.blockDuration: duration = child.unsigned.flatMap { Int64(exactly: $0) }
            case MatroskaID.referenceBlock: hasReference = true
            default: break
            }
        }
        guard let block, let layout = MatroskaBlockLayout.parse(block) else { return nil }
        self.layout = layout
        payload = block
        self.duration = duration
        self.hasReference = hasReference
    }
}
