import Foundation
import Network

/// Browses Bonjour for relay hosts of one service type and keeps a `RelayDirectory` current. Browsing starts only
/// when `start()` is called; `stop()` ends it and forgets every host.
public nonisolated final class StreamRelayBrowser: @unchecked Sendable {
    // @unchecked: `browser` is only touched on `queue`.
    public let directory: RelayDirectory
    private let serviceType: String
    private let queue = DispatchQueue(label: "HTTPMPEG2Kit.StreamRelayBrowser")
    private let onChange: (@Sendable ([RelayHost]) -> Void)?
    private var browser: NWBrowser?

    /// - Parameters:
    ///   - serviceType: the Bonjour type, for example `_example-tv._tcp`.
    ///   - onChange: the hosts after every change (on the browser's queue).
    public init(serviceType: String, directory: RelayDirectory,
                onChange: (@Sendable ([RelayHost]) -> Void)? = nil) {
        self.serviceType = serviceType
        self.directory = directory
        self.onChange = onChange
    }

    public func start() {
        queue.async { [self] in
            guard browser == nil else { return }
            let parameters = NWParameters()
            parameters.includePeerToPeer = false
            let browser = NWBrowser(for: .bonjourWithTXTRecord(type: serviceType, domain: nil), using: parameters)
            browser.browseResultsChangedHandler = { [weak self] results, _ in self?.update(results) }
            browser.stateUpdateHandler = { [weak self] state in
                if case .failed = state { self?.update([]) }
            }
            self.browser = browser
            browser.start(queue: queue)
        }
    }

    public func stop() {
        queue.async { [self] in
            browser?.cancel()
            browser = nil
            update([])
        }
    }

    private func update(_ results: Set<NWBrowser.Result>) {
        directory.replace(results.compactMap(Self.host(from:)))
        onChange?(directory.hosts)
    }

    /// A browse result as a host, when it carries a valid advertisement.
    static func host(from result: NWBrowser.Result) -> RelayHost? {
        guard case .service(let name, _, _, _) = result.endpoint,
              case .bonjour(let record) = result.metadata,
              let advertisement = RelayAdvertisement(txtEntries: record.dictionary) else { return nil }
        return RelayHost(name: name, endpoint: result.endpoint, advertisement: advertisement)
    }
}
