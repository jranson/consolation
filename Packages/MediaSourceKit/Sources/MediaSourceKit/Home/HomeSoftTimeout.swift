import Foundation

/// The composer's soft timeout: which sources answered within it. Off the main actor, and driven by an injected
/// sleep so tests fire it by hand.
nonisolated enum HomeSoftTimeout {
    typealias Sleep = @Sendable (Duration) async throws -> Void

    /// Whether each source answered in time; returns the late ones.
    static func lateSources(_ waits: [(SourceID, AsyncStream<Void>)], timeout: Duration,
                            sleep: @escaping Sleep) async -> [SourceID] {
        await withTaskGroup(of: (SourceID, Bool).self) { group in
            for (id, arrived) in waits {
                group.addTask { (id, await arrivesInTime(arrived, timeout: timeout, sleep: sleep)) }
            }
            var late: [SourceID] = []
            for await (id, inTime) in group where !inTime { late.append(id) }
            return late
        }
    }

    /// True when `arrived` yields or finishes before `timeout`, or when the wait is cancelled.
    static func arrivesInTime(_ arrived: AsyncStream<Void>, timeout: Duration, sleep: @escaping Sleep) async -> Bool {
        await withTaskGroup(of: Bool.self) { group in
            group.addTask {
                for await _ in arrived { return true }
                return true
            }
            group.addTask {
                do {
                    try await sleep(timeout)
                } catch {
                    return true
                }
                return false
            }
            let first = await group.next() ?? true
            group.cancelAll()
            return first
        }
    }
}
