import Foundation
import MediaSourceKit
import Synchronization

/// A soft timeout the test fires by hand, so "the source answered in time" and "the source was late" never depend
/// on the machine's speed. Until `fire()`, every wait blocks (and ends quietly when its task is cancelled).
nonisolated final class TimeoutGate: Sendable {
    private struct State {
        var fired = false
        var waiters: [UInt64: CheckedContinuation<Void, Never>] = [:]
        var nextID: UInt64 = 0
    }

    private let state = Mutex(State())

    var sleep: HomeShelfComposer.Sleep {
        { [self] _ in try await wait() }
    }

    func fire() {
        let waiters = state.withLock { state in
            state.fired = true
            defer { state.waiters = [:] }
            return Array(state.waiters.values)
        }
        for waiter in waiters { waiter.resume() }
    }

    private func wait() async throws {
        let waiterID = state.withLock { state in
            defer { state.nextID &+= 1 }
            return state.nextID
        }
        await withTaskCancellationHandler {
            await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
                let resumeNow = state.withLock { state in
                    if state.fired || Task.isCancelled { return true }
                    state.waiters[waiterID] = waiter
                    return false
                }
                if resumeNow { waiter.resume() }
            }
        } onCancel: {
            let waiter = state.withLock { $0.waiters.removeValue(forKey: waiterID) }
            waiter?.resume()
        }
        try Task.checkCancellation()
    }
}

/// Polls until `condition` holds or about two seconds pass.
@MainActor
func eventually(_ condition: @MainActor () async -> Bool) async throws -> Bool {
    for _ in 0..<200 {
        if await condition() { return true }
        try await Task.sleep(for: .milliseconds(10))
    }
    return await condition()
}
