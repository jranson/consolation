import Foundation
import Network
import Synchronization

/// A relay host found on the local network.
public nonisolated struct RelayHost: Sendable, Hashable {
    /// The advertised instance name, usually the device's name.
    public let name: String
    /// Where to connect: a Bonjour service endpoint (resolved at connect time), or a host and port in tests.
    public let endpoint: NWEndpoint
    public let advertisement: RelayAdvertisement

    public init(name: String, endpoint: NWEndpoint, advertisement: RelayAdvertisement) {
        self.name = name
        self.endpoint = endpoint
        self.advertisement = advertisement
    }

    public var instanceID: String { advertisement.instanceID }
}

/// The relay hosts currently known, and which of them recently failed. Thread-safe; `StreamRelayBrowser` keeps it
/// up to date, and players ask it for a host before they tune.
public nonisolated final class RelayDirectory: Sendable {
    private struct State {
        var hosts: [RelayHost] = []
        var unreachableUntil: [String: ContinuousClock.Instant] = [:]
    }

    /// Never returned: this device's own instance.
    public let ownInstanceID: String
    private let state = Mutex(State())

    public init(ownInstanceID: String) {
        self.ownInstanceID = ownInstanceID
    }

    /// Every known host except this device, ordered by name.
    public var hosts: [RelayHost] {
        state.withLock { $0.hosts }
    }

    /// Replaces the known hosts (a fresh browse result).
    public func replace(_ hosts: [RelayHost]) {
        let others = hosts.filter { $0.instanceID != ownInstanceID }.sorted { $0.name < $1.name }
        state.withLock { $0.hosts = others }
    }

    /// A host relaying `channel` that hasn't failed recently, or nil.
    public func host(serving channel: ChannelKey) -> RelayHost? {
        let now = ContinuousClock.now
        return state.withLock { state in
            state.unreachableUntil = state.unreachableUntil.filter { $0.value > now }
            return state.hosts.first { host in
                host.advertisement.channels.contains(channel) && state.unreachableUntil[host.instanceID] == nil
            }
        }
    }

    /// Skips `host` for `duration`, for example after a connection to it failed, so the next attempt tunes instead.
    public func markUnreachable(_ host: RelayHost, for duration: Duration) {
        let until = ContinuousClock.now + duration
        state.withLock { $0.unreachableUntil[host.instanceID] = until }
    }
}
