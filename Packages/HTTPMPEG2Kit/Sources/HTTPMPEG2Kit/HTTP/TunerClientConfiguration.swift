import Foundation

/// Settings the host app passes to the tuner clients. Nothing here names the app.
public nonisolated struct TunerClientConfiguration: Sendable, Hashable {
    /// Sent as `User-Agent`, for example `MyApp/1.0`. Nil keeps the system default.
    public var userAgent: String?
    /// Idle timeout for JSON requests.
    public var requestTimeout: Duration
    /// Upper bound for a JSON request, including any wait for connectivity.
    public var resourceTimeout: Duration
    /// Let JSON requests wait for connectivity (for example while the Local Network prompt is showing)
    /// instead of failing at once. Bounded by `resourceTimeout`.
    public var waitsForConnectivity: Bool
    /// Idle timeout for streams: the wait for response headers and the longest gap between chunks.
    /// ATSC 3.0 first bytes take about 1.8 s and DRM rejections about 3.2 s.
    public var streamTimeout: Duration

    public init(
        userAgent: String? = nil,
        requestTimeout: Duration = .seconds(5),
        resourceTimeout: Duration = .seconds(30),
        waitsForConnectivity: Bool = true,
        streamTimeout: Duration = .seconds(10)
    ) {
        self.userAgent = userAgent
        self.requestTimeout = requestTimeout
        self.resourceTimeout = resourceTimeout
        self.waitsForConnectivity = waitsForConnectivity
        self.streamTimeout = streamTimeout
    }

    /// An ephemeral, cache-less, cookie-less session configuration for JSON requests.
    func makeJSONSessionConfiguration() -> URLSessionConfiguration {
        let configuration = Self.makeBaseSessionConfiguration()
        configuration.timeoutIntervalForRequest = requestTimeout.timeInterval
        configuration.timeoutIntervalForResource = max(resourceTimeout.timeInterval, requestTimeout.timeInterval)
        configuration.waitsForConnectivity = waitsForConnectivity
        return configuration
    }

    /// An ephemeral, cache-less session configuration for one live stream.
    func makeStreamSessionConfiguration() -> URLSessionConfiguration {
        let configuration = Self.makeBaseSessionConfiguration()
        configuration.timeoutIntervalForRequest = streamTimeout.timeInterval
        configuration.waitsForConnectivity = false
        configuration.httpMaximumConnectionsPerHost = 1
        return configuration
    }

    /// A GET request with the configured User-Agent. The clients never send anything but GET.
    func makeRequest(url: URL) -> URLRequest {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalAndRemoteCacheData)
        request.httpMethod = "GET"
        if let userAgent {
            request.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        }
        return request
    }

    private static func makeBaseSessionConfiguration() -> URLSessionConfiguration {
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.urlCredentialStorage = nil
        return configuration
    }
}

extension Duration {
    /// The duration in seconds, for Foundation APIs.
    nonisolated var timeInterval: TimeInterval {
        let parts = components
        return TimeInterval(parts.seconds) + TimeInterval(parts.attoseconds) / 1e18
    }
}
