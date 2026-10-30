import Foundation
import Synchronization

/// Persists source configurations. The app injects real storage: JSON in Application Support on macOS and iOS, compact
/// `UserDefaults` on tvOS. Implementations never store secrets.
public nonisolated protocol SourceConfigurationStore: Sendable {
    func loadConfigurations() async throws -> [SourceConfiguration]
    /// Replaces every stored configuration. Throws `SourceConfigurationError` before writing a secret.
    func saveConfigurations(_ configurations: [SourceConfiguration]) async throws
    /// Reads, changes and writes the configurations as one step: no other change to this store runs in between, so
    /// concurrent edits never lose one another. Writes nothing when `change` leaves them as they were, and throws
    /// `SourceConfigurationError` before writing a secret.
    func updateConfigurations(_ change: @Sendable (inout [SourceConfiguration]) throws -> Void) async throws
}

nonisolated extension SourceConfigurationStore {
    /// Adds the configuration, or replaces the one with the same ID in place.
    public func upsert(_ configuration: SourceConfiguration) async throws {
        try await updateConfigurations { all in
            if let index = all.firstIndex(where: { $0.id == configuration.id }) {
                all[index] = configuration
            } else {
                all.append(configuration)
            }
        }
    }

    /// Removes the configuration with this ID, if any. Its credentials are removed through `CredentialStore`.
    public func remove(_ id: SourceID) async throws {
        try await updateConfigurations { all in all.removeAll { $0.id == id } }
    }
}

/// Small key-value storage the app injects (`UserDefaults` or files); packages never touch `UserDefaults.standard`.
public nonisolated protocol KeyValueStore: Sendable {
    func data(forKey key: String) async -> Data?
    /// Nil removes the key.
    func setData(_ data: Data?, forKey key: String) async
}

/// For tests and previews.
public actor InMemoryKeyValueStore: KeyValueStore {
    private var values: [String: Data]

    public init(_ values: [String: Data] = [:]) {
        self.values = values
    }

    public func data(forKey key: String) -> Data? {
        values[key]
    }

    public func setData(_ data: Data?, forKey key: String) {
        values[key] = data
    }

    public var keys: [String] { values.keys.sorted() }
}

/// For tests and previews. Every change runs on the actor without suspending, so it is atomic.
public actor InMemorySourceConfigurationStore: SourceConfigurationStore {
    private var configurations: [SourceConfiguration]

    public init(_ configurations: [SourceConfiguration] = []) {
        self.configurations = configurations
    }

    public func loadConfigurations() -> [SourceConfiguration] {
        configurations
    }

    public func saveConfigurations(_ configurations: [SourceConfiguration]) throws {
        for configuration in configurations { try configuration.validateNoSecrets() }
        self.configurations = configurations
    }

    public func updateConfigurations(_ change: @Sendable (inout [SourceConfiguration]) throws -> Void) throws {
        var updated = configurations
        try change(&updated)
        guard updated != configurations else { return }
        try saveConfigurations(updated)
    }
}

/// Stores configurations as one JSON value in an injected `KeyValueStore`, under a key the app chooses.
///
/// Writes through one store (and its copies) run one at a time, so concurrent `upsert`s and `remove`s never lose
/// each other even when the key-value store suspends. Use one store per key.
public nonisolated struct KeyValueSourceConfigurationStore: SourceConfigurationStore {
    public let store: any KeyValueStore
    public let key: String
    private let writes = AsyncLock()

    public init(store: any KeyValueStore, key: String) {
        self.store = store
        self.key = key
    }

    public func loadConfigurations() async throws -> [SourceConfiguration] {
        guard let data = await store.data(forKey: key) else { return [] }
        return try JSONDecoder().decode([SourceConfiguration].self, from: data)
    }

    public func saveConfigurations(_ configurations: [SourceConfiguration]) async throws {
        await writes.acquire()
        defer { writes.release() }
        try await write(configurations)
    }

    public func updateConfigurations(_ change: @Sendable (inout [SourceConfiguration]) throws -> Void) async throws {
        await writes.acquire()
        defer { writes.release() }
        let current = try await loadConfigurations()
        var updated = current
        try change(&updated)
        guard updated != current else { return }
        try await write(updated)
    }

    private func write(_ configurations: [SourceConfiguration]) async throws {
        for configuration in configurations { try configuration.validateNoSecrets() }
        guard !configurations.isEmpty else {
            await store.setData(nil, forKey: key)
            return
        }
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        await store.setData(try encoder.encode(configurations), forKey: key)
    }
}

/// A lock held across suspension points: waiters get it in arrival order. It serializes read-modify-write cycles
/// whose steps `await`, which an actor alone can't, because actors are reentrant.
nonisolated final class AsyncLock: Sendable {
    private struct State {
        var isLocked = false
        var waiters: [CheckedContinuation<Void, Never>] = []
    }

    private let state = Mutex(State())

    func acquire() async {
        await withCheckedContinuation { (waiter: CheckedContinuation<Void, Never>) in
            let acquired = state.withLock { state in
                guard state.isLocked else {
                    state.isLocked = true
                    return true
                }
                state.waiters.append(waiter)
                return false
            }
            if acquired { waiter.resume() }
        }
    }

    /// Hands the lock to the next waiter, or unlocks it.
    func release() {
        let next = state.withLock { state -> CheckedContinuation<Void, Never>? in
            guard !state.waiters.isEmpty else {
                state.isLocked = false
                return nil
            }
            return state.waiters.removeFirst()
        }
        next?.resume()
    }
}
