import Foundation
@testable import PlaybackKit
import Testing

/// The disk time-shift buffer never leaves a file behind: its name goes as soon as it opens (a killed process frees the
/// space), and files of older builds are swept at launch (left behind, they can fill an Apple TV).
struct FileByteRingCleanupTests {
    private static func scratchDirectory() throws -> URL {
        let directory = FileManager.default.temporaryDirectory
            .appendingPathComponent("ring-cleanup-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    @Test func theFileHasNoNameWhileTheRingStillWorks() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let ring = try #require(FileByteRing(capacity: 4 << 20, directory: directory))
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path).isEmpty)
        let bytes = Data((0..<(3 << 20)).map { UInt8(truncatingIfNeeded: $0) })
        ring.append(bytes)
        #expect(ring.read(from: 1_000, maxLength: 16) == bytes.subdata(in: 1_000..<1_016))
        ring.close()
    }

    @Test func leftoversFromOlderBuildsAreSwept() throws {
        let directory = try Self.scratchDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let leftover = directory.appendingPathComponent("timeshift-\(UUID().uuidString).ts")
        let unrelated = directory.appendingPathComponent("keep.ts")
        FileManager.default.createFile(atPath: leftover.path, contents: Data([1, 2, 3]))
        FileManager.default.createFile(atPath: unrelated.path, contents: Data([4]))
        FileByteRing.removeLeftovers(in: directory)
        #expect(try FileManager.default.contentsOfDirectory(atPath: directory.path) == ["keep.ts"])
    }
}
