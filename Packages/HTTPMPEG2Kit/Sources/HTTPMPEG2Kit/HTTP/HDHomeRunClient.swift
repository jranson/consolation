import Foundation

/// Reads one device's JSON API: `discover.json`, `lineup.json`, `status.json` and `lineup_status.json`.
///
/// Every request is a `GET`; the client never POSTs (no `/lineup.post`, no scans, no favorites writes) and
/// never opens streams (see `HDHomeRunStreamClient`). It uses its own ephemeral session with no cache, created
/// on the first request, so constructing a client makes no network connection. URLs inside responses follow
/// the Host this client used and are returned as given.
public actor HDHomeRunClient {
    /// The device base URL, for example `http://hdhomerun.local` or `http://192.0.2.10`.
    public nonisolated let baseURL: URL
    public nonisolated let configuration: TunerClientConfiguration

    private let sessionConfiguration: URLSessionConfiguration
    private var session: URLSession?

    /// A client for a device base URL.
    public init(baseURL: URL, configuration: TunerClientConfiguration = TunerClientConfiguration()) {
        self.init(
            baseURL: baseURL,
            configuration: configuration,
            sessionConfiguration: configuration.makeJSONSessionConfiguration()
        )
    }

    /// A client for a host as the user typed it: `hdhomerun.local`, `hdhr-1234abc2.local`, `192.0.2.10`
    /// or `http://192.0.2.10`. Throws `.invalidHost` when it is none of those.
    public init(
        host: String,
        configuration: TunerClientConfiguration = TunerClientConfiguration()
    ) throws(HDHomeRunClientError) {
        guard let baseURL = TunerHost.baseURL(for: host) else { throw .invalidHost(host) }
        self.init(baseURL: baseURL, configuration: configuration)
    }

    /// Lets tests supply a session configuration (for example with a stub `URLProtocol`).
    init(
        baseURL: URL,
        configuration: TunerClientConfiguration,
        sessionConfiguration: sending URLSessionConfiguration
    ) {
        self.baseURL = baseURL
        self.configuration = configuration
        self.sessionConfiguration = sessionConfiguration
    }

    deinit {
        session?.invalidateAndCancel()
    }

    /// `GET /discover.json`.
    public func discover() async throws(HDHomeRunClientError) -> TunerDiscovery {
        try TunerJSON.discovery(from: await fetch("discover.json"))
    }

    /// `GET /discover.json`, then checks the DeviceID. Use it whenever a known device is reached again:
    /// a recycled address may now belong to another device.
    public func discover(expecting deviceID: TunerDeviceID) async throws(HDHomeRunClientError) -> TunerDiscovery {
        let discovery = try await discover()
        guard discovery.deviceID == deviceID else {
            throw .deviceMismatch(expected: deviceID, found: discovery.deviceID)
        }
        return discovery
    }

    /// `GET /lineup.json`.
    ///
    /// - Parameters:
    ///   - showAll: adds `show=all`: channels hidden in the device's channel editor (`Enabled: 0`) and
    ///     unsubscribed entries. The default list respects the channels the user hid.
    ///   - tuning: adds `tuning`: `Frequency`, `Modulation`, `ProgramNumber`, `TransportStreamID`, `PLPConfig`.
    public func lineup(
        showAll: Bool = false,
        tuning: Bool = false
    ) async throws(HDHomeRunClientError) -> [LineupChannel] {
        var query: [URLQueryItem] = []
        if showAll { query.append(URLQueryItem(name: "show", value: "all")) }
        if tuning { query.append(URLQueryItem(name: "tuning", value: nil)) }
        return try TunerJSON.lineup(from: await fetch("lineup.json", query: query))
    }

    /// `GET /status.json`: one entry per tuner.
    public func status() async throws(HDHomeRunClientError) -> [TunerStatus] {
        try TunerJSON.tunerStatus(from: await fetch("status.json"))
    }

    /// `GET /lineup_status.json`.
    public func lineupStatus() async throws(HDHomeRunClientError) -> LineupStatus {
        try TunerJSON.lineupStatus(from: await fetch("lineup_status.json"))
    }

    /// Cancels outstanding requests and releases the session. A later request creates a new one.
    public func invalidate() {
        session?.invalidateAndCancel()
        session = nil
    }

    /// The URL for an endpoint under `baseURL`.
    nonisolated func endpointURL(_ path: String, query: [URLQueryItem] = []) -> URL {
        let url = baseURL.appending(path: path)
        guard !query.isEmpty,
              var components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url }
        components.queryItems = query
        return components.url ?? url
    }

    private func fetch(_ path: String, query: [URLQueryItem] = []) async throws(HDHomeRunClientError) -> Data {
        let request = configuration.makeRequest(url: endpointURL(path, query: query))
        let session = currentSession()
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch {
            throw HDHomeRunClientError(transportError: error, host: baseURL.host() ?? baseURL.absoluteString)
        }
        guard let http = response as? HTTPURLResponse else { throw .invalidResponse }
        guard http.statusCode == 200 else {
            throw HDHomeRunClientError(
                status: http.statusCode, errorHeader: http.value(forHTTPHeaderField: "X-HDHomeRun-Error"))
        }
        return data
    }

    private func currentSession() -> URLSession {
        if let session { return session }
        let created = URLSession(configuration: sessionConfiguration)
        session = created
        return created
    }
}
