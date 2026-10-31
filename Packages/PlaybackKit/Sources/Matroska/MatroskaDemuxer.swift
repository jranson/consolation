//
//  MatroskaDemuxer.swift
//  Matroska
//
//  Reads a Matroska (or WebM) stream incrementally as its bytes arrive, in chunks of any size, and hands on the
//  Segment's header at its first Cluster, any Cues it meets, and every block with its payload lent for the call.
//
//  Only the elements a player needs are buffered: the EBML header, SeekHead, Info, Tracks and Cues (each bounded),
//  and one block at a time. Segments and Clusters are entered rather than buffered, so a Cluster of any size costs no
//  more memory than its largest block; everything else (Chapters, Tags, Attachments, Void) is skipped without being
//  kept. Unknown sizes (a file written while streaming) are followed: an unknown-size Cluster ends where an element
//  that can't be in it begins. Damage makes the demuxer search for the next Cluster and carry on from there.
//

import Foundation

nonisolated public struct MatroskaDemuxer: Sendable {
    /// Blocks larger than this are dropped (a 4K keyframe is a few megabytes).
    public static let maximumBlockSize = 32 << 20
    /// Bounds on the header elements and the Cues, which are buffered whole.
    static let maximumHeaderSize = 16 << 20
    public static let maximumCuesSize = 32 << 20
    static let maximumTimestampSize: Int64 = 8

    /// The Segment's header, once its first Cluster began (or as given to `init(continuing:at:atElement:)`).
    public private(set) var segment: MatroskaSegment?
    public private(set) var failure: MatroskaError?
    public private(set) var statistics = MatroskaStatistics()

    struct OpenElement: Sendable {
        var id: UInt32
        /// The absolute offset where it ends, nil for an unknown size.
        var end: Int64?
    }

    /// Bytes from `bufferOffset` up to `inputOffset`, the next byte to be fed.
    private var buffer: [UInt8] = []
    private var bufferOffset: Int64 = 0
    private var inputOffset: Int64 = 0
    /// Where the next element starts (absolute). Beyond `inputOffset` while a skip is under way.
    private var position: Int64 = 0
    /// The masters entered: the Segment, then a Cluster.
    private var stack: [OpenElement] = []
    private var segmentElement: OpenElement?
    private var info = MatroskaSegmentInfo()
    private var tracks: [MatroskaTrack]?
    private var seekPositions: [UInt32: UInt64] = [:]
    private var cuesRead = false
    private var sawHeader = false
    /// The Segment's payload offset, recorded when the Segment was entered.
    private var segmentStart: Int64 = 0
    private var clusterOffset: Int64 = 0
    private var clusterTimestamp: Int64?
    /// Looking for the next Cluster after damage, or after a restart at an arbitrary offset.
    private var searching = false

    public init() {}

    /// A demuxer that reads from inside an already known `segment`: a second connection for the Cues, or a
    /// stream reopened elsewhere. `atElement` as for `restart(at:atElement:)`.
    public init(continuing segment: MatroskaSegment, at offset: Int64, atElement: Bool) {
        self.segment = segment
        segmentElement = OpenElement(id: MatroskaID.segment, end: segment.endOffset)
        info = segment.info
        tracks = segment.tracks
        segmentStart = segment.dataOffset
        sawHeader = true
        restart(at: offset, atElement: atElement)
    }

    /// Continues at `offset`, where the stream was reopened (a seek). With `atElement` the offset is where a Segment
    /// child starts (a Cluster from the Cues, the Cues from the SeekHead); otherwise the demuxer searches for the
    /// next Cluster. The Segment's header is kept.
    public mutating func restart(at offset: Int64, atElement: Bool) {
        buffer.removeAll(keepingCapacity: true)
        bufferOffset = offset
        inputOffset = offset
        position = offset
        stack = segmentElement.map { [$0] } ?? []
        clusterTimestamp = nil
        searching = !atElement
    }

    /// When a skip of at least `threshold` bytes between Segment children is under way (Attachments, large Tags),
    /// the offset where it ends: a seekable source can be reopened there (`skipInput(to:)`) instead of read through.
    public func pendingSkip(atLeast threshold: Int64) -> Int64? {
        guard !searching, stack.count == 1, position - inputOffset >= threshold else { return nil }
        return position
    }

    /// The input continues at `offset`, the end of the pending skip, because the source was reopened there.
    public mutating func skipInput(to offset: Int64) {
        guard offset == position, offset > inputOffset else { return }
        buffer.removeAll(keepingCapacity: true)
        bufferOffset = offset
        inputOffset = offset
    }

    /// Feeds the next bytes of the stream, contiguous with the last feed, and hands each event to `handler`.
    public mutating func feed(_ bytes: UnsafeRawBufferPointer, _ handler: (MatroskaEvent) -> Void) {
        let start = inputOffset
        inputOffset += Int64(bytes.count)
        guard failure == nil, !bytes.isEmpty else { return }
        var input = bytes.bindMemory(to: UInt8.self)
        if buffer.isEmpty {
            // Bytes before `position` belong to a skipped element.
            let drop = Int(min(max(position - start, 0), Int64(input.count)))
            input = UnsafeBufferPointer(rebasing: input[drop...])
            bufferOffset = start + Int64(drop)
        }
        buffer.append(contentsOf: input)
        parse(handler)
        compact()
    }

    // MARK: - Parsing

    private mutating func parse(_ handler: (MatroskaEvent) -> Void) {
        var bytes: [UInt8] = []
        swap(&bytes, &buffer)
        bytes.withUnsafeBufferPointer { pointer in
            while failure == nil {
                let progressed = searching ? search(pointer) : step(pointer, handler)
                if !progressed { break }
            }
        }
        swap(&bytes, &buffer)
    }

    /// Drops the bytes before `position`.
    private mutating func compact() {
        let consumed = position - bufferOffset
        guard consumed > 0 else { return }
        if consumed >= Int64(buffer.count) {
            buffer.removeAll(keepingCapacity: true)
            bufferOffset = inputOffset
        } else {
            buffer.removeSubrange(0..<Int(consumed))
            bufferOffset = position
        }
    }

    /// Handles the element at `position`; false when more bytes are needed.
    private mutating func step(_ bytes: UnsafeBufferPointer<UInt8>,
                               _ handler: (MatroskaEvent) -> Void) -> Bool {
        while let top = stack.last, let end = top.end, position >= end {
            stack.removeLast()
            if top.id == MatroskaID.cluster { clusterTimestamp = nil }
        }
        guard position >= bufferOffset, position - bufferOffset < Int64(bytes.count) else { return false }
        let local = Int(position - bufferOffset)
        switch EBML.header(bytes, at: local) {
        case .incomplete:
            return false
        case .invalid:
            return lostSync()
        case .header(let header):
            if let top = stack.last, top.end == nil, ends(top, at: header.id) {
                stack.removeLast()
                if top.id == MatroskaID.cluster { clusterTimestamp = nil }
                return true
            }
            let element = Element(header: header, offset: position, local: local)
            switch stack.last?.id {
            case nil: return topLevel(element, bytes)
            case MatroskaID.segment: return segmentChild(element, bytes, handler)
            case MatroskaID.cluster: return clusterChild(element, bytes, handler)
            default: return skip(element)
            }
        }
    }

    /// An unknown-size element ends where an element that can't be inside it begins.
    private func ends(_ open: OpenElement, at id: UInt32) -> Bool {
        let level0 = id == MatroskaID.ebml || id == MatroskaID.segment
        if open.id == MatroskaID.cluster { return level0 || MatroskaID.segmentChildren.contains(id) }
        return level0
    }

    struct Element {
        let header: EBMLElementHeader
        /// Absolute offset of the header, and its index in the buffer.
        let offset: Int64
        let local: Int

        var dataOffset: Int64 { offset + Int64(header.headerLength) }
        var end: Int64? { header.size.map { dataOffset + $0 } }
    }

    private mutating func topLevel(_ element: Element, _ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        switch element.header.id {
        case MatroskaID.ebml:
            sawHeader = true
            var progressed = false
            guard let payload = take(element, bytes, limit: Int64(Self.maximumHeaderSize),
                                     progressed: &progressed) else { return progressed }
            if let type = MatroskaDocType.docType(in: payload), !MatroskaDocType.accepted.contains(type) {
                failure = .notMatroska
            }
            return true
        case MatroskaID.segment where segmentElement == nil && sawHeader:
            let open = OpenElement(id: MatroskaID.segment, end: element.end)
            segmentElement = open
            segmentStart = element.dataOffset
            stack.append(open)
            position = element.dataOffset
            return true
        default:
            guard sawHeader else {
                failure = .notMatroska
                return false
            }
            return skip(element)
        }
    }

    private mutating func segmentChild(_ element: Element, _ bytes: UnsafeBufferPointer<UInt8>,
                                       _ handler: (MatroskaEvent) -> Void) -> Bool {
        let id = element.header.id
        let wanted = id == MatroskaID.seekHead || id == MatroskaID.info || (id == MatroskaID.tracks && segment == nil)
            || (id == MatroskaID.cues && !cuesRead)
        guard wanted else { return id == MatroskaID.cluster ? enterCluster(element, handler) : skip(element) }
        let limit = Int64(id == MatroskaID.cues ? Self.maximumCuesSize : Self.maximumHeaderSize)
        var progressed = false
        guard let payload = take(element, bytes, limit: limit, progressed: &progressed) else { return progressed }
        switch id {
        case MatroskaID.seekHead:
            seekPositions.merge(MatroskaSeekHead.positions(in: payload)) { kept, _ in kept }
        case MatroskaID.info:
            info = MatroskaSegmentInfo.parse(payload)
        case MatroskaID.tracks:
            tracks = MatroskaTrack.tracks(in: payload)
        default:
            cuesRead = true
            handler(.cues(MatroskaCues.parse(payload, segmentDataOffset: segmentStart)))
        }
        return true
    }

    private mutating func enterCluster(_ element: Element, _ handler: (MatroskaEvent) -> Void) -> Bool {
        if segment == nil {
            guard let tracks, !tracks.isEmpty, let open = segmentElement else {
                failure = .missingTracks
                return false
            }
            let dataOffset = segmentStart
            let cues = cuesRead ? nil : seekPositions[MatroskaID.cues].flatMap { Int64(exactly: $0) }
            let announced = MatroskaSegment(info: info, tracks: tracks, dataOffset: dataOffset,
                                            dataSize: open.end.map { $0 - dataOffset },
                                            cuesOffset: cues.map { dataOffset + $0 },
                                            firstClusterOffset: element.offset)
            segment = announced
            handler(.segment(announced))
        }
        stack.append(OpenElement(id: MatroskaID.cluster, end: element.end))
        clusterOffset = element.offset
        clusterTimestamp = nil
        position = element.dataOffset
        return true
    }

    private mutating func clusterChild(_ element: Element, _ bytes: UnsafeBufferPointer<UInt8>,
                                       _ handler: (MatroskaEvent) -> Void) -> Bool {
        switch element.header.id {
        case MatroskaID.timestamp:
            var progressed = false
            guard let payload = take(element, bytes, limit: Self.maximumTimestampSize,
                                     progressed: &progressed) else { return progressed }
            clusterTimestamp = EBML.unsigned(payload).flatMap { Int64(exactly: $0) }
            return true
        case MatroskaID.simpleBlock, MatroskaID.blockGroup:
            let limit = Int64(Self.maximumBlockSize + 4_096)
            if let size = element.header.size, size > limit {
                statistics.droppedBlocks += 1
                return skip(element)
            }
            var progressed = false
            guard let payload = take(element, bytes, limit: limit, progressed: &progressed) else { return progressed }
            emitBlock(payload, simple: element.header.id == MatroskaID.simpleBlock, handler)
            return true
        default:
            return skip(element)
        }
    }

    private mutating func emitBlock(_ payload: UnsafeBufferPointer<UInt8>, simple: Bool,
                                    _ handler: (MatroskaEvent) -> Void) {
        let parsed = simple ? MatroskaBlockGroup(simpleBlock: payload) : MatroskaBlockGroup(group: payload)
        guard let parsed, let clusterTimestamp else {
            statistics.droppedBlocks += 1
            return
        }
        let layout = parsed.layout
        let timestamp = clusterTimestamp + Int64(layout.relativeTimestamp)
        let block = MatroskaBlock(track: layout.track, timestamp: timestamp, duration: parsed.duration,
                                  isKeyframe: simple ? layout.isKeyframe : !parsed.hasReference,
                                  isDiscardable: simple && layout.isDiscardable, frames: layout.frames,
                                  clusterOffset: clusterOffset)
        statistics.blocks += 1
        handler(.block(block, payload: parsed.payload))
    }

    // MARK: - Moving on

    /// The element's payload once it is wholly buffered, moving past it. Nil while it isn't yet (`progressed`
    /// false), or when it was skipped instead for being larger than `limit` or of unknown size.
    private mutating func take(_ element: Element, _ bytes: UnsafeBufferPointer<UInt8>, limit: Int64,
                               progressed: inout Bool) -> UnsafeBufferPointer<UInt8>? {
        guard let size = element.header.size, size <= limit else {
            progressed = skip(element)
            return nil
        }
        let start = element.local + element.header.headerLength
        guard Int64(bytes.count - start) >= size else {
            progressed = false
            return nil
        }
        position = element.dataOffset + size
        progressed = true
        return UnsafeBufferPointer(rebasing: bytes[start..<(start + Int(size))])
    }

    /// Moves past the element; one of unknown size can't be skipped, so the demuxer searches for a Cluster.
    private mutating func skip(_ element: Element) -> Bool {
        guard let end = element.end, end > position else { return lostSync() }
        position = end
        return true
    }

    /// Damage: search for the next Cluster (only inside a Segment; anything else isn't Matroska).
    private mutating func lostSync() -> Bool {
        guard let open = segmentElement else {
            failure = .notMatroska
            return false
        }
        statistics.resynchronizations += 1
        stack = [open]
        clusterTimestamp = nil
        searching = true
        position += 1
        return true
    }

    /// Looks for a Cluster ID followed by a header and a Timestamp (or CRC-32) child; false when more bytes are
    /// needed. The last bytes of the buffer are kept, so an ID split between feeds is still found.
    private mutating func search(_ bytes: UnsafeBufferPointer<UInt8>) -> Bool {
        guard position >= bufferOffset else { return false }
        var local = Int(position - bufferOffset)
        while local + 4 <= bytes.count {
            if bytes[local] == 0x1F, bytes[local + 1] == 0x43, bytes[local + 2] == 0xB6, bytes[local + 3] == 0x75 {
                switch clusterCandidate(bytes, at: local) {
                case .some(true):
                    position = bufferOffset + Int64(local)
                    searching = false
                    return true
                case .none:
                    position = bufferOffset + Int64(local)
                    return false
                case .some(false):
                    break
                }
            }
            local += 1
        }
        position = bufferOffset + Int64(local)
        return false
    }

    /// Whether a Cluster plausibly starts at `local`; nil when more bytes are needed to tell.
    private func clusterCandidate(_ bytes: UnsafeBufferPointer<UInt8>, at local: Int) -> Bool? {
        guard case .header(let header) = EBML.header(bytes, at: local) else {
            return EBML.header(bytes, at: local) == .incomplete ? nil : false
        }
        if let size = header.size, let end = segmentElement?.end, bufferOffset + Int64(local) + size > end {
            return false
        }
        switch EBML.header(bytes, at: local + header.headerLength) {
        case .incomplete:
            return nil
        case .invalid:
            return false
        case .header(let first):
            let size = first.size ?? .max
            return (first.id == MatroskaID.timestamp && size <= Self.maximumTimestampSize)
                || (first.id == MatroskaID.crc32 && size == 4)
        }
    }
}
