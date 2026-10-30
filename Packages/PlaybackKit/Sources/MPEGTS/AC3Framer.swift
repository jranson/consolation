//
//  AC3Framer.swift
//  MPEGTS
//
//  Splits AC-3 and E-AC-3 PES payloads into syncframes. Frames may span PES boundaries. Each frame is confirmed by its
//  CRC (CRC-16 over everything after the syncword is zero), so a 0x0B77 inside garbage or a corrupted frame is never
//  emitted. Frames before the first PTS are dropped.
//

import Foundation

nonisolated public struct AC3Framer: Sendable {
    static let maximumPendingStamps = 64
    static let maximumBufferSize = 64 * 1024

    /// Frames dropped because their CRC failed.
    public internal(set) var crcErrors = 0
    /// Frames dropped for other reasons (no timestamp yet, an orphaned E-AC-3 dependent substream).
    public internal(set) var droppedFrames = 0

    var buffer: [UInt8] = []
    var stamps: [PendingStamp] = []
    var anchorPTS: Int64?
    var anchorSampleRate = 0
    var samplesSinceAnchor: Int64 = 0
    /// The buffer starts exactly where the last frame ended, so a frame is due at offset 0.
    var continuesAtStart = false

    public init() {}

    /// Appends one audio PES and returns the frames it completed.
    public mutating func append(_ pes: PESPacket) -> [AC3Frame] {
        pes.payload.withUnsafeBytes { raw in append(raw.bindMemory(to: UInt8.self), of: pes) }
    }

    /// `append(_:)` for a payload lent by `TSDemuxer.feed(_:_:)` (`pes.payload` is ignored).
    public mutating func append(_ payload: UnsafeBufferPointer<UInt8>, of pes: PESPacket) -> [AC3Frame] {
        if pes.pts != nil {
            stamps.append(PendingStamp(offset: buffer.count, pts: pes.pts, dts: nil,
                                       discontinuity: pes.isDiscontinuity))
            if stamps.count > Self.maximumPendingStamps {
                stamps.removeFirst(stamps.count - Self.maximumPendingStamps)
            }
        }
        buffer.append(contentsOf: payload)
        var output: [AC3Frame] = []
        var bytes: [UInt8] = []
        swap(&bytes, &buffer)
        let consumed = bytes.withUnsafeBufferPointer { split($0, output: &output) }
        swap(&bytes, &buffer)
        discard(consumed)
        return output
    }

    /// Forgets buffered bytes and the timestamp anchor.
    public mutating func reset() {
        self = AC3Framer()
    }

    /// Emits every complete, CRC-valid frame and returns how many leading bytes are no longer needed.
    private mutating func split(_ bytes: UnsafeBufferPointer<UInt8>, output: inout [AC3Frame]) -> Int {
        var position = 0
        // Where the next frame should start if the stream is intact (-1 while hunting for sync).
        var expected = continuesAtStart ? 0 : -1
        var lastEmittedEnd = -1
        let count = bytes.count
        while position + AC3SyncInfo.headerSize <= count {
            guard bytes[position] == 0x0B, bytes[position + 1] == 0x77,
                  let info = AC3SyncInfo.parse(bytes, at: position) else {
                position += 1
                continue
            }
            let end = position + info.frameSize
            guard end <= count else { break }
            guard CRC16AC3.checksum(UnsafeBufferPointer(rebasing: bytes[(position + 2)..<end])) == 0 else {
                crcErrors += 1
                if position == expected {
                    // A damaged frame where one was due: skip it whole, but keep its duration in the timeline.
                    if info.startsAccessUnit { _ = nextPTS(for: info, at: position) }
                    position = end
                    expected = end
                } else {
                    position += 1
                }
                continue
            }
            let frame = UnsafeBufferPointer(rebasing: bytes[position..<end])
            if info.startsAccessUnit {
                if emit(info, frame: frame, at: position, output: &output) { lastEmittedEnd = end }
            } else if lastEmittedEnd == position, let last = output.indices.last, output[last].isEAC3 {
                output[last].data.append(frame)
                lastEmittedEnd = end
            } else {
                droppedFrames += 1
            }
            position = end
            expected = end
        }
        continuesAtStart = position == expected
        return position
    }

    /// Appends the frame if it has a timestamp. Returns whether it was emitted.
    private mutating func emit(
        _ info: AC3SyncInfo,
        frame: UnsafeBufferPointer<UInt8>,
        at position: Int,
        output: inout [AC3Frame]
    ) -> Bool {
        guard let pts = nextPTS(for: info, at: position) else {
            droppedFrames += 1
            return false
        }
        let channels = AC3Frame.channelsByMode[Int(info.acmod & 0x07)] + (info.hasLFE ? 1 : 0)
        output.append(AC3Frame(data: Data(buffer: frame), pts: pts, sampleRate: info.sampleRate,
                               channelCount: channels, acmod: info.acmod, hasLFE: info.hasLFE,
                               isEAC3: info.isEAC3, samplesPerFrame: info.samplesPerFrame))
        return true
    }

    /// The PTS of a frame starting at `position`, advancing the sample count. Nil before the first PES PTS.
    private mutating func nextPTS(for info: AC3SyncInfo, at position: Int) -> Int64? {
        if let pts = takePTS(at: position) {
            anchorPTS = pts
            anchorSampleRate = info.sampleRate
            samplesSinceAnchor = 0
        }
        guard let anchor = anchorPTS, info.sampleRate > 0 else { return nil }
        if info.sampleRate != anchorSampleRate {
            // Re-anchor at the end of the previous frame so a rate change does not rescale earlier samples.
            anchorPTS = anchor + samplesSinceAnchor * 90_000 / Int64(max(anchorSampleRate, 1))
            anchorSampleRate = info.sampleRate
            samplesSinceAnchor = 0
        }
        let pts = (anchorPTS ?? anchor) + samplesSinceAnchor * 90_000 / Int64(anchorSampleRate)
        samplesSinceAnchor += Int64(info.samplesPerFrame)
        return pts
    }

    /// The PTS of the latest PES that started at or before `position`, consuming those entries.
    private mutating func takePTS(at position: Int) -> Int64? {
        var consumed = 0
        var pts: Int64?
        for entry in stamps {
            guard entry.offset <= position else { break }
            consumed += 1
            pts = entry.pts ?? pts
        }
        stamps.removeFirst(consumed)
        return pts
    }

    private mutating func discard(_ count: Int) {
        var drop = count
        if buffer.count - drop > Self.maximumBufferSize {
            drop = buffer.count - AC3SyncInfo.headerSize
            continuesAtStart = false
        }
        guard drop > 0 else { return }
        buffer.removeSubrange(0..<drop)
        for index in stamps.indices {
            stamps[index].offset = max(0, stamps[index].offset - drop)
        }
    }
}
