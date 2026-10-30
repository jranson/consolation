import Foundation
import Testing
@testable import PlaybackKit

struct ByteRingTests {
    private func rings(capacity: Int) -> [any ByteRing] {
        var result: [any ByteRing] = [MemoryByteRing(capacity: capacity)]
        if let file = FileByteRing(capacity: capacity) { result.append(file) }
        return result
    }

    private func pattern(_ count: Int, from start: Int) -> Data {
        Data((0..<count).map { UInt8(truncatingIfNeeded: start + $0) })
    }

    @Test func readsBackWhatWasWritten() {
        for ring in rings(capacity: 1 << 20) {
            ring.append(pattern(1_000, from: 0))
            ring.append(pattern(500, from: 1_000))
            #expect(ring.writeHead == 1_500)
            #expect(ring.oldestOffset == 0)
            #expect(ring.read(from: 990, maxLength: 20) == pattern(20, from: 990))
            ring.close()
        }
    }

    @Test func wrapsAndForgetsTheOldestBytes() {
        let capacity = 1 << 20
        for ring in rings(capacity: capacity) {
            let chunk = 300_000
            for index in 0..<5 { ring.append(pattern(chunk, from: index * chunk)) }
            #expect(ring.writeHead == Int64(5 * chunk))
            #expect(ring.oldestOffset == Int64(5 * chunk - capacity))
            #expect(ring.read(from: 0, maxLength: 10).isEmpty)
            let offset = Int(ring.oldestOffset) + 7
            #expect(ring.read(from: Int64(offset), maxLength: 4_096) == pattern(4_096, from: offset))
            ring.close()
        }
    }

    @Test func readNeverPassesTheHead() {
        for ring in rings(capacity: 1 << 20) {
            ring.append(pattern(100, from: 0))
            #expect(ring.read(from: 90, maxLength: 1_000).count == 10)
            #expect(ring.read(from: 100, maxLength: 10).isEmpty)
            ring.close()
        }
    }

    /// The file ring stages writes in memory: reads that straddle the file and the staged bytes, and wrap past the
    /// file's end, still return exactly what was written.
    @Test func fileRingReadsAcrossStagedAndWrittenBytes() throws {
        let capacity = 3 << 20
        let ring = try #require(FileByteRing(capacity: capacity))
        defer { ring.close() }
        var written = 0
        let chunk = 70_001
        while written < 8 << 20 {
            ring.append(pattern(chunk, from: written))
            written += chunk
            let oldest = Int(ring.oldestOffset)
            // Just behind the head (staged), straddling a staging flush, and the oldest bytes (in the file).
            for offset in [written - 500, max(oldest, written - FileByteRing.stagingSize - 3_000), oldest + 1] {
                let length = min(96_256, written - offset)
                #expect(ring.read(from: Int64(offset), maxLength: length) == pattern(length, from: offset))
            }
        }
        #expect(ring.writeHead == Int64(written))
        #expect(ring.read(from: 0, maxLength: 10).isEmpty)
    }

    @Test func closedFileRingReadsNothing() throws {
        let ring = try #require(FileByteRing(capacity: 1 << 20))
        ring.append(pattern(100, from: 0))
        ring.close()
        ring.close()
        #expect(ring.read(from: 0, maxLength: 10).isEmpty)
    }
}
