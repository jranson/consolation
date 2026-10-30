import Foundation

/// The open `shelfContributions()` streams of one source actor. Each stream keeps only the newest batch, because a
/// batch replaces everything the source contributed before.
nonisolated struct ContributionObservers {
    typealias Continuation = AsyncStream<[ShelfContribution]>.Continuation

    private var continuations: [UInt64: Continuation] = [:]
    private var nextID: UInt64 = 0

    static func makeStream() -> (stream: AsyncStream<[ShelfContribution]>, continuation: Continuation) {
        AsyncStream.makeStream(of: [ShelfContribution].self, bufferingPolicy: .bufferingNewest(1))
    }

    var isEmpty: Bool { continuations.isEmpty }

    mutating func add(_ continuation: Continuation) -> UInt64 {
        defer { nextID &+= 1 }
        continuations[nextID] = continuation
        return nextID
    }

    mutating func remove(_ observerID: UInt64) {
        continuations[observerID] = nil
    }

    func yield(_ batch: [ShelfContribution]) {
        for continuation in continuations.values { continuation.yield(batch) }
    }
}
