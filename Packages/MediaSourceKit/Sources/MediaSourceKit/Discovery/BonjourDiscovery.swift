import Foundation
import Network
import Synchronization

/// One service a Bonjour browse found, resolved to an IPv4 address.
public nonisolated struct BonjourService: Hashable, Sendable {
    public var name: String
    public var txt: [String: String]
    public var host: String
    public var port: Int
}

/// Browses for a DNS-SD service type on the local network for a few seconds, only when called (the user asked to
/// find servers). The type must be declared in the app's `NSBonjourServices`; browsing a declared type needs no
/// multicast entitlement.
public nonisolated enum BonjourDiscovery {
    /// The services that answered within `duration`, each resolved to an IPv4 address and port (IPv4 keeps
    /// addresses usable in URLs; a service that can't be resolved in time is left out). Sorted by name.
    @concurrent
    public static func browse(type: String, for duration: Duration = .seconds(3)) async -> [BonjourService] {
        let found = await results(type: type, for: duration)
        return await withTaskGroup(of: BonjourService?.self) { group in
            for (endpoint, txt) in found {
                group.addTask { await resolve(endpoint, txt: txt) }
            }
            var services: [BonjourService] = []
            for await service in group { if let service { services.append(service) } }
            return services.sorted { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        }
    }

    private static func results(type: String, for duration: Duration) async -> [(NWEndpoint, [String: String])] {
        let browser = NWBrowser(for: .bonjourWithTXTRecord(type: type, domain: nil), using: .tcp)
        let latest = Mutex<Set<NWBrowser.Result>>([])
        browser.browseResultsChangedHandler = { results, _ in latest.withLock { $0 = results } }
        browser.start(queue: DispatchQueue(label: "BonjourDiscovery.browse"))
        try? await Task.sleep(for: duration)
        browser.cancel()
        return latest.withLock { $0 }.map { result in
            var txt: [String: String] = [:]
            if case .bonjour(let record) = result.metadata { txt = record.dictionary }
            return (result.endpoint, txt)
        }
    }

    /// Connects just long enough to learn the service's IPv4 address and port, then cancels.
    private static func resolve(_ endpoint: NWEndpoint, txt: [String: String]) async -> BonjourService? {
        guard case .service(let name, _, _, _) = endpoint else { return nil }
        let parameters = NWParameters.tcp
        (parameters.defaultProtocolStack.internetProtocol as? NWProtocolIP.Options)?.version = .v4
        let connection = NWConnection(to: endpoint, using: parameters)
        let finished = Mutex(false)
        return await withCheckedContinuation { (continuation: CheckedContinuation<BonjourService?, Never>) in
            let finish: @Sendable (BonjourService?) -> Void = { service in
                guard finished.withLock({ done in defer { done = true }; return !done }) else { return }
                connection.cancel()
                continuation.resume(returning: service)
            }
            connection.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    guard case .hostPort(.ipv4(let address), let port)? = connection.currentPath?.remoteEndpoint
                    else { return finish(nil) }
                    let host = address.debugDescription.split(separator: "%").first.map(String.init) ?? ""
                    finish(BonjourService(name: name, txt: txt, host: host, port: Int(port.rawValue)))
                case .failed, .cancelled:
                    finish(nil)
                default:
                    break
                }
            }
            connection.start(queue: DispatchQueue(label: "BonjourDiscovery.resolve"))
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) { finish(nil) }
        }
    }
}
