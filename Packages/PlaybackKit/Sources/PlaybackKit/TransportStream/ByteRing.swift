//
//  ByteRing.swift
//  PlaybackKit
//
//  The live time-shift buffer: incoming stream bytes are written at the head; playback reads behind it at its own
//  pace. Positions are absolute byte offsets since the stream started, so a reader can tell when the oldest data
//  it wanted has been overwritten. Kept in memory or in a temporary file, limited by size.
//

import Foundation

nonisolated protocol ByteRing: AnyObject, Sendable {
    /// Total bytes ever written (the write head as an absolute offset).
    var writeHead: Int64 { get }
    /// The oldest absolute offset still held.
    var oldestOffset: Int64 { get }
    var capacity: Int { get }
    func append(_ data: Data)
    /// Reads up to `maxLength` bytes starting at `offset` (which must be within oldestOffset..<writeHead).
    func read(from offset: Int64, maxLength: Int) -> Data
    /// Reads up to `destination.count` bytes starting at `offset` into `destination` (a reader's reusable buffer) and
    /// returns how many it read: 0 when `offset` isn't within oldestOffset..<writeHead.
    func read(from offset: Int64, into destination: UnsafeMutableRawBufferPointer) -> Int
    /// Drops everything and carries on at absolute offset `offset` (a finite source reopened there for a seek):
    /// `oldestOffset` and `writeHead` both become `offset`.
    func reset(to offset: Int64)
    func close()
}

/// A ring held in memory.
nonisolated final class MemoryByteRing: ByteRing, @unchecked Sendable {
    // @unchecked: all state is guarded by `lock`.
    private let lock = NSLock()
    private var storage: [UInt8]
    private var head: Int64 = 0
    /// Nothing before this offset is held (after `reset(to:)`).
    private var base: Int64 = 0
    let capacity: Int

    /// `minimum` exists for tests that need a ring smaller than the 1 MiB floor.
    init(capacity: Int, minimum: Int = 1 << 20) {
        self.capacity = max(capacity, minimum, 188)
        storage = [UInt8](repeating: 0, count: self.capacity)
    }

    var writeHead: Int64 { lock.withLock { head } }
    var oldestOffset: Int64 { lock.withLock { max(base, head - Int64(capacity)) } }

    func reset(to offset: Int64) {
        lock.withLock {
            head = max(0, offset)
            base = head
        }
    }

    func append(_ data: Data) {
        lock.withLock {
            data.withUnsafeBytes { raw in
                guard let bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = raw.count
                var source = bytes
                // Only the newest `capacity` bytes matter.
                if remaining > capacity {
                    source += remaining - capacity
                    head += Int64(remaining - capacity)
                    remaining = capacity
                }
                while remaining > 0 {
                    let position = Int(head % Int64(capacity))
                    let chunk = min(remaining, capacity - position)
                    storage.withUnsafeMutableBufferPointer { dest in
                        (dest.baseAddress! + position).update(from: source, count: chunk)
                    }
                    source += chunk
                    remaining -= chunk
                    head += Int64(chunk)
                }
            }
        }
    }

    func read(from offset: Int64, maxLength: Int) -> Data {
        lock.withLock {
            let oldest = max(base, head - Int64(capacity))
            guard offset >= oldest, offset < head, maxLength > 0 else { return Data() }
            var length = Int(min(Int64(maxLength), head - offset))
            var result = Data(capacity: length)
            var cursor = offset
            while length > 0 {
                let position = Int(cursor % Int64(capacity))
                let chunk = min(length, capacity - position)
                storage.withUnsafeBufferPointer { buffer in
                    result.append(buffer.baseAddress! + position, count: chunk)
                }
                cursor += Int64(chunk)
                length -= chunk
            }
            return result
        }
    }

    func read(from offset: Int64, into destination: UnsafeMutableRawBufferPointer) -> Int {
        lock.withLock {
            let oldest = max(base, head - Int64(capacity))
            guard offset >= oldest, offset < head, let target = destination.baseAddress else { return 0 }
            let length = Int(min(Int64(destination.count), head - offset))
            var copied = 0
            storage.withUnsafeBytes { raw in
                while copied < length {
                    let position = Int((offset + Int64(copied)) % Int64(capacity))
                    let chunk = min(length - copied, capacity - position)
                    (target + copied).copyMemory(from: raw.baseAddress! + position, byteCount: chunk)
                    copied += chunk
                }
            }
            return copied
        }
    }

    func close() {
        lock.withLock { storage = [] }
    }
}

/// A ring kept in a temporary file in Caches, which never leaves the device and is deleted on close.
///
/// A live stream arrives in chunks of tens of KB; each one written straight to the file would be a syscall (and,
/// before, a seek too). New bytes are staged in memory and written in `stagingSize` blocks with one `pwrite`, so a
/// 19.4 Mbps stream makes about 2–3 writes a second instead of 20–100. Reads of staged bytes come from memory; the
/// rest is read with one `pread` per contiguous run, straight into the result (recently written data is normally
/// still in the page cache, so no flash read happens). The file is written at 8.7 GB an hour for a 19.4 Mbps
/// stream either way: that is the cost of time-shifting to flash.
nonisolated final class FileByteRing: ByteRing, @unchecked Sendable {
    // @unchecked: all state is guarded by `lock`.
    /// Bytes gathered before one write to the file.
    static let stagingSize = 1 << 20

    private let lock = NSLock()
    private let descriptor: Int32
    private let fileURL: URL
    /// Every byte before `flushedHead` is in the file; `staging` holds `flushedHead..<head`.
    private var head: Int64 = 0
    private var flushedHead: Int64 = 0
    /// Nothing before this offset is held (after `reset(to:)`).
    private var base: Int64 = 0
    private var staging: [UInt8] = []
    private var isClosed = false
    let capacity: Int

    init?(capacity: Int, directory: URL = FileManager.default.temporaryDirectory) {
        self.capacity = max(capacity, 1 << 20)
        fileURL = directory.appendingPathComponent("\(Self.filePrefix)\(UUID().uuidString).ts")
        let opened = open(fileURL.path, O_RDWR | O_CREAT | O_EXCL | O_CLOEXEC, 0o600)
        guard opened >= 0 else { return nil }
        descriptor = opened
        // The name goes at once; the open descriptor keeps the data. Its space returns when the descriptor closes, even
        // if the process is killed (a relaunch from Xcode or `make run-device`), which used to leave gigabytes behind
        // on an Apple TV until its storage ran out.
        unlink(fileURL.path)
        staging.reserveCapacity(Self.stagingSize)
    }

    static let filePrefix = "timeshift-"

    /// Deletes time-shift files left in `directory` by builds that kept the name until they closed. Call at launch,
    /// before anything plays.
    static func removeLeftovers(in directory: URL = FileManager.default.temporaryDirectory) {
        let names = (try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? []
        for name in names where name.hasPrefix(filePrefix) && name.hasSuffix(".ts") {
            try? FileManager.default.removeItem(at: directory.appendingPathComponent(name))
        }
    }

    /// Bytes free for a time-shift file on `directory`'s volume, or nil when unknown.
    static func availableBytes(in directory: URL = FileManager.default.temporaryDirectory) -> Int? {
        // The file system's free size (tvOS has no "important usage" capacity).
        let attributes = try? FileManager.default.attributesOfFileSystem(forPath: directory.path)
        return (attributes?[.systemFreeSize] as? NSNumber).map { Int(clamping: $0.int64Value) }
    }

    deinit {
        close()
    }

    var writeHead: Int64 { lock.withLock { head } }
    var oldestOffset: Int64 { lock.withLock { max(base, head - Int64(capacity)) } }

    func reset(to offset: Int64) {
        lock.withLock {
            head = max(0, offset)
            flushedHead = head
            base = head
            staging.removeAll(keepingCapacity: true)
        }
    }

    func append(_ data: Data) {
        lock.withLock {
            guard !isClosed else { return }
            data.withUnsafeBytes { raw in
                guard var bytes = raw.bindMemory(to: UInt8.self).baseAddress else { return }
                var remaining = raw.count
                while remaining > 0 {
                    let take = min(remaining, Self.stagingSize - staging.count)
                    staging.append(contentsOf: UnsafeBufferPointer(start: bytes, count: take))
                    bytes += take
                    remaining -= take
                    head += Int64(take)
                    if staging.count >= Self.stagingSize { flushStaging() }
                }
            }
        }
    }

    func read(from offset: Int64, maxLength: Int) -> Data {
        lock.withLock {
            let oldest = max(base, head - Int64(capacity))
            guard !isClosed, offset >= oldest, offset < head, maxLength > 0 else { return Data() }
            let length = Int(min(Int64(maxLength), head - offset))
            var result = Data(count: length)
            let filled = result.withUnsafeMutableBytes { raw -> Int in
                guard let base = raw.baseAddress else { return 0 }
                return fill(base, from: offset, length: length)
            }
            if filled < length { result.removeSubrange(filled...) }
            return result
        }
    }

    func read(from offset: Int64, into destination: UnsafeMutableRawBufferPointer) -> Int {
        lock.withLock {
            let oldest = max(base, head - Int64(capacity))
            guard !isClosed, offset >= oldest, offset < head, let target = destination.baseAddress else { return 0 }
            return fill(target, from: offset, length: Int(min(Int64(destination.count), head - offset)))
        }
    }

    func close() {
        lock.withLock {
            guard !isClosed else { return }
            isClosed = true
            staging = []
            Darwin.close(descriptor)
            try? FileManager.default.removeItem(at: fileURL)
        }
    }

    /// Copies `offset..<offset+length` into `destination`: the file part with `pread`, the staged part from memory.
    /// Returns how many bytes it copied (fewer only if the file read failed).
    private func fill(_ destination: UnsafeMutableRawPointer, from offset: Int64, length: Int) -> Int {
        var copied = 0
        var cursor = offset
        while copied < length, cursor < flushedHead {
            let position = Int(cursor % Int64(capacity))
            let run = min(length - copied, Int(flushedHead - cursor), capacity - position)
            let got = pread(descriptor, destination + copied, run, off_t(position))
            guard got == run else { return copied }
            copied += run
            cursor += Int64(run)
        }
        if copied < length {
            let start = Int(cursor - flushedHead)
            staging.withUnsafeBytes { raw in
                (destination + copied).copyMemory(from: raw.baseAddress! + start, byteCount: length - copied)
            }
            copied = length
        }
        return copied
    }

    /// Writes the staged bytes to their place in the file (two writes when they wrap past its end).
    private func flushStaging() {
        staging.withUnsafeBytes { raw in
            guard let base = raw.baseAddress else { return }
            var written = 0
            while written < raw.count {
                let position = Int((flushedHead + Int64(written)) % Int64(capacity))
                let run = min(raw.count - written, capacity - position)
                guard pwrite(descriptor, base + written, run, off_t(position)) == run else { break }
                written += run
            }
        }
        flushedHead = head
        staging.removeAll(keepingCapacity: true)
    }
}
