//
//  AllocationCounter.swift
//  PlaybackKitTests
//
//  Counts the process's heap allocations, for opt-in measurements only (never the CI gate). It hooks libmalloc's
//  `malloc_logger`, the hook MallocStackLogging uses, which sees every malloc-family allocation and free on every
//  thread, including CoreFoundation's and CoreMedia's. The hook only does atomic arithmetic, so it never allocates.
//

import Darwin
import Synchronization

#if os(macOS)
nonisolated enum AllocationCounter {
    /// Totals since `install()`.
    struct Snapshot {
        var allocations: Int
        var bytes: Int
        /// Bytes allocated and not yet freed (frees of memory allocated before `install()` count against it).
        var live: Int
    }

    private typealias Logger = @convention(c) (UInt32, UInt, UInt, UInt, UInt, UInt32) -> Void

    // libmalloc's MALLOC_LOG_TYPE_* flags.
    private static let allocate: UInt32 = 2
    private static let deallocate: UInt32 = 4
    private static let hasZone: UInt32 = 8

    private static let allocations = Atomic<Int>(0)
    private static let bytes = Atomic<Int>(0)
    private static let live = Atomic<Int>(0)
    private static let peak = Atomic<Int>(0)

    private nonisolated(unsafe) static let slot: UnsafeMutablePointer<Logger?>? =
        dlsym(UnsafeMutableRawPointer(bitPattern: -2), "malloc_logger").map { $0.assumingMemoryBound(to: Logger?.self) }

    private static let hook: Logger = { type, first, second, _, result, _ in
        if type & deallocate != 0 {
            // free(ptr) logs the pointer after the zone; realloc logs the old pointer the same way.
            let freed = type & hasZone != 0 ? second : first
            if freed != 0 {
                live.subtract(malloc_size(UnsafeRawPointer(bitPattern: freed)), ordering: .relaxed)
            }
        }
        guard type & allocate != 0, result != 0 else { return }
        let size = malloc_size(UnsafeRawPointer(bitPattern: result))
        allocations.add(1, ordering: .relaxed)
        bytes.add(size, ordering: .relaxed)
        let now = live.add(size, ordering: .relaxed).newValue
        var highest = peak.load(ordering: .relaxed)
        while now > highest {
            let (exchanged, original) = peak.compareExchange(expected: highest, desired: now, ordering: .relaxed)
            if exchanged { break }
            highest = original
        }
    }

    static var isAvailable: Bool { slot != nil }

    /// Starts counting. Touches every static first, so their lazy initialization never runs inside the hook.
    static func install() {
        _ = allocations.load(ordering: .relaxed) + bytes.load(ordering: .relaxed) + live.load(ordering: .relaxed)
            + peak.load(ordering: .relaxed)
        slot?.pointee = hook
    }

    static func uninstall() {
        slot?.pointee = nil
    }

    static func snapshot() -> Snapshot {
        Snapshot(allocations: allocations.load(ordering: .relaxed), bytes: bytes.load(ordering: .relaxed),
                 live: live.load(ordering: .relaxed))
    }

    /// Restarts the peak at the current live bytes.
    static func resetPeak() {
        peak.store(live.load(ordering: .relaxed), ordering: .relaxed)
    }

    /// The most live bytes since `resetPeak()`.
    static var peakLive: Int { peak.load(ordering: .relaxed) }
}
#endif
