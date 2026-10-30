//
//  SectionAssembler.swift
//  MPEGTS
//
//  Reassembles PSI sections that span TS packets, following pointer_field on payload_unit_start packets and
//  stopping at 0xFF stuffing. Section sizes are capped, so a hostile section_length cannot grow the buffer.
//

nonisolated struct SectionAssembler {
    /// 3 header bytes plus the largest PAT/PMT section_length.
    static let maximumSectionSize = 3 + PSIParser.maximumSectionLength

    private var buffer: [UInt8] = []
    /// Total size of the section being assembled; 0 while its 3-byte header is still incomplete.
    private var expected = 0
    private(set) var isAssembling = false

    mutating func reset() {
        buffer.removeAll(keepingCapacity: true)
        expected = 0
        isAssembling = false
    }

    /// Consumes one packet payload and returns every section completed by it.
    mutating func push(_ payload: UnsafeBufferPointer<UInt8>, unitStart: Bool, malformed: inout Int) -> [[UInt8]] {
        var sections: [[UInt8]] = []
        guard unitStart else {
            if isAssembling {
                _ = absorb(payload, from: 0, into: &sections, malformed: &malformed)
            }
            return sections
        }
        guard !payload.isEmpty else {
            reset()
            return sections
        }
        let sectionStart = 1 + Int(payload[0])
        if isAssembling {
            let tail = UnsafeBufferPointer(rebasing: payload[0..<min(sectionStart, payload.count)])
            _ = absorb(tail, from: 1, into: &sections, malformed: &malformed)
        }
        reset()
        guard sectionStart <= payload.count else {
            malformed += 1
            return sections
        }
        var index = sectionStart
        while index < payload.count, payload[index] != 0xFF {
            isAssembling = true
            index = absorb(payload, from: index, into: &sections, malformed: &malformed)
            if isAssembling || index < 0 { break }
        }
        return sections
    }

    /// Appends bytes from `payload[start...]` to the current section. Returns the index after the bytes used,
    /// or -1 if the section header was malformed.
    private mutating func absorb(
        _ payload: UnsafeBufferPointer<UInt8>,
        from start: Int,
        into sections: inout [[UInt8]],
        malformed: inout Int
    ) -> Int {
        var index = start
        if expected == 0 {
            let take = min(3 - buffer.count, payload.count - index)
            guard take > 0 else { return index }
            buffer.append(contentsOf: UnsafeBufferPointer(rebasing: payload[index..<(index + take)]))
            index += take
            guard buffer.count == 3 else { return index }
            let size = 3 + ByteField.u12(buffer[1], buffer[2])
            guard size <= Self.maximumSectionSize else {
                malformed += 1
                reset()
                return -1
            }
            expected = size
        }
        let take = min(expected - buffer.count, payload.count - index)
        if take > 0 {
            buffer.append(contentsOf: UnsafeBufferPointer(rebasing: payload[index..<(index + take)]))
            index += take
        }
        if buffer.count == expected {
            sections.append(buffer)
            reset()
        }
        return index
    }
}
