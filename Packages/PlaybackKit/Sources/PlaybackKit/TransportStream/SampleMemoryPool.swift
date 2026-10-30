//
//  SampleMemoryPool.swift
//  PlaybackKit
//
//  Recycles the memory behind compressed sample buffers (one per pipeline): blocks freed when a picture or audio
//  sample is done are handed out again instead of going back to malloc, and blocks unused for a while age out.
//  CoreMedia's CMMemoryPool does the work; its allocator is safe to use and free from any thread.
//

import CoreMedia

nonisolated final class SampleMemoryPool: @unchecked Sendable {
    // @unchecked: CMMemoryPool is thread-safe; the reference never changes.
    private let pool = CMMemoryPoolCreate(options: nil)
    /// The allocator for `CMBlockBufferCreateWithMemoryBlock`'s `blockAllocator`.
    let allocator: CFAllocator

    init() {
        allocator = CMMemoryPoolGetAllocator(pool)
    }

    deinit {
        // Blocks still held by sample buffers stay valid and are freed normally when released.
        CMMemoryPoolInvalidate(pool)
    }
}
