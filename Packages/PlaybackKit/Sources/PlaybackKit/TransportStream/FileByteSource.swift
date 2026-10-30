//
//  FileByteSource.swift
//  PlaybackKit
//
//  Reads a local transport stream file from any offset, a chunk at a time as the pipeline asks for it (the stream is
//  pulled, so nothing runs ahead of the reader). HTTPByteSource hands one out when a seek in a file goes beyond the
//  time-shift buffer.
//

import Foundation

nonisolated public final class FileByteSource: ByteSource, @unchecked Sendable {
    // @unchecked: `handle`, `size` and `cancelled` are only touched under `lock`.
    static let chunkSize = 1 << 20

    private let url: URL
    private let startOffset: Int64
    private let lock = NSLock()
    private var handle: FileHandle?
    private var size: Int64?
    private var cancelled = false

    public init(url: URL, startingAt offset: Int64 = 0) {
        self.url = url
        startOffset = max(0, offset)
    }

    public var isFinite: Bool { true }

    public var contentLength: Int64? { lock.withLock { size } }

    public func reopened(at offset: Int64) -> (any ByteSource)? {
        FileByteSource(url: url, startingAt: offset)
    }

    public func open() async throws -> AsyncThrowingStream<Data, any Error> {
        let handle = try FileHandle(forReadingFrom: url)
        let end = try handle.seekToEnd()
        try handle.seek(toOffset: min(UInt64(startOffset), end))
        let isCancelled = lock.withLock {
            self.handle = handle
            size = Int64(end)
            return cancelled
        }
        if isCancelled { throw CancellationError() }
        return AsyncThrowingStream { [weak self] in
            try self?.next()
        }
    }

    public func cancel() {
        lock.withLock {
            cancelled = true
            try? handle?.close()
            handle = nil
        }
    }

    /// The next chunk, or nil at the end (or once cancelled).
    private func next() throws -> Data? {
        try lock.withLock {
            guard let handle, !cancelled else { return nil }
            guard let data = try handle.read(upToCount: Self.chunkSize), !data.isEmpty else {
                try? handle.close()
                self.handle = nil
                return nil
            }
            return data
        }
    }
}
