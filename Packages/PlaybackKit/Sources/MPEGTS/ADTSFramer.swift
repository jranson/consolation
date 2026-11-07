//
//  ADTSFramer.swift
//  MPEGTS
//
//  Splits AAC PES payloads in ADTS (stream_type 0x0F) into frames. Frames may span PES boundaries. ADTS has no
//  checksum to confirm a header by (the optional CRC covers only part of the frame), so a frame where none was due
//  is taken only when the next frame's header follows it with the same format; an 0xFFF inside garbage is skipped.
//  Frames before the first PTS are dropped, and so are frames of several raw data blocks, which a decoder can't take
//  as one packet (their time is kept).
//

import Foundation

nonisolated public struct ADTSFramer: Sendable {
    static let maximumPendingStamps = 64
    static let maximumBufferSize = 64 * 1024

    /// Frames dropped: no timestamp yet, several raw data blocks, or a layout left to a program config element.
    public internal(set) var droppedFrames = 0

    var buffer: [UInt8] = []
    var stamps: [PendingStamp] = []
    var anchorPTS: Int64?
    var anchorSampleRate = 0
    var samplesSinceAnchor: Int64 = 0
    /// The buffer starts exactly where the last frame ended, so a frame is due at offset 0.
    var continuesAtStart = false
    /// The format of the last frame taken, which a frame where one is due must keep.
    var lastFormat: ADTSHeader.Format?

    public init() {}

    /// Appends one audio PES and returns the frames it completed.
    public mutating func append(_ pes: PESPacket) -> [ADTSFrame] {
        pes.payload.withUnsafeBytes { raw in append(raw.bindMemory(to: UInt8.self), of: pes) }
    }

    /// `append(_:)` for a payload lent by `TSDemuxer.feed(_:_:)` (`pes.payload` is ignored).
    public mutating func append(_ payload: UnsafeBufferPointer<UInt8>, of pes: PESPacket) -> [ADTSFrame] {
        if pes.pts != nil {
            stamps.append(PendingStamp(offset: buffer.count, pts: pes.pts, dts: nil,
                                       discontinuity: pes.isDiscontinuity))
            if stamps.count > Self.maximumPendingStamps {
                stamps.removeFirst(stamps.count - Self.maximumPendingStamps)
            }
        }
        buffer.append(contentsOf: payload)
        var output: [ADTSFrame] = []
        var bytes: [UInt8] = []
        swap(&bytes, &buffer)
        let consumed = bytes.withUnsafeBufferPointer { split($0, output: &output) }
        swap(&bytes, &buffer)
        discard(consumed)
        return output
    }

    /// Forgets buffered bytes and the timestamp anchor.
    public mutating func reset() {
        self = ADTSFramer()
    }

    /// Emits every complete frame it can trust and returns how many leading bytes are no longer needed.
    private mutating func split(_ bytes: UnsafeBufferPointer<UInt8>, output: inout [ADTSFrame]) -> Int {
        var position = 0
        // Where the next frame should start if the stream is intact (-1 while hunting for sync).
        var expected = continuesAtStart ? 0 : -1
        let count = bytes.count
        while position + ADTSHeader.minimumSize <= count {
            guard let header = ADTSHeader.parse(bytes, at: position) else {
                position += 1
                continue
            }
            let end = position + header.frameLength
            guard end <= count else { break }
            if position != expected || header.format != lastFormat {
                // Hunting: the next header must follow with the same format, so wait for it.
                guard end + ADTSHeader.minimumSize <= count else { break }
                guard ADTSHeader.parse(bytes, at: end)?.format == header.format else {
                    position += 1
                    continue
                }
            }
            emit(header, frame: UnsafeBufferPointer(rebasing: bytes[position..<end]), at: position, output: &output)
            lastFormat = header.format
            position = end
            expected = end
        }
        continuesAtStart = position == expected
        return position
    }

    private mutating func emit(_ header: ADTSHeader, frame: UnsafeBufferPointer<UInt8>, at position: Int,
                               output: inout [ADTSFrame]) {
        guard let pts = nextPTS(for: header, at: position), header.rawDataBlocks == 1,
              header.channelConfiguration > 0 else {
            droppedFrames += 1
            return
        }
        output.append(ADTSFrame(frame: Data(buffer: frame), header: header, pts: pts))
    }

    /// The PTS of a frame starting at `position`, advancing the sample count. Nil before the first PES PTS.
    private mutating func nextPTS(for header: ADTSHeader, at position: Int) -> Int64? {
        if let pts = takePTS(at: position) {
            anchorPTS = pts
            anchorSampleRate = header.sampleRate
            samplesSinceAnchor = 0
        }
        guard let anchor = anchorPTS else { return nil }
        if header.sampleRate != anchorSampleRate {
            // Re-anchor at the end of the previous frame so a rate change does not rescale earlier samples.
            anchorPTS = anchor + samplesSinceAnchor * 90_000 / Int64(max(anchorSampleRate, 1))
            anchorSampleRate = header.sampleRate
            samplesSinceAnchor = 0
        }
        let pts = (anchorPTS ?? anchor) + samplesSinceAnchor * 90_000 / Int64(anchorSampleRate)
        samplesSinceAnchor += Int64(header.samplesPerFrame)
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
            drop = buffer.count - ADTSHeader.minimumSize
            continuesAtStart = false
        }
        guard drop > 0 else { return }
        buffer.removeSubrange(0..<drop)
        for index in stamps.indices {
            stamps[index].offset = max(0, stamps[index].offset - drop)
        }
    }
}
