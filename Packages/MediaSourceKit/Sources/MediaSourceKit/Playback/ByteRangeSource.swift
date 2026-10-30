import Foundation

/// Random access for sources that are not a URL (in-app SMB, NFS) or that must follow a moving file (`.grab`).
/// An adapter will conform it to PlaybackKit's `ByteSource` once the engine takes finite and growing streams.
public nonisolated protocol ByteRangeSource: Sendable {
    /// Bytes readable now; may grow.
    func length() async throws -> UInt64
    /// Returns up to `maxLength` bytes. At the current end of a growing file it returns empty `Data`, which means
    /// "no new data yet", not end-of-stream.
    func read(offset: UInt64, maxLength: Int) async throws -> Data
}

/// The source's view of a recording in progress. The stream finishes after `.complete` or `.lost`.
public nonisolated protocol GrowthMonitor: Sendable {
    func events() -> AsyncStream<GrowthEvent>
}

public nonisolated enum GrowthEvent: Hashable, Sendable {
    case growing(length: UInt64)
    /// The recording finished; end-of-file is now real.
    case complete(length: UInt64)
    /// The file vanished and could not be relocated.
    case lost(String)
}
