import Foundation

/// Fetches a server's small JSON documents (catalogs, feeds, channel lists). Injected so tests run without the
/// network.
public nonisolated protocol RemoteDocumentFetching: Sendable {
    /// The body of a GET of `url`, at most `RemoteDocumentFetcher.maxBytes`. A response outside 200–299 throws
    /// `RemoteDocumentError.status`, with the server's Problem Details when it sent them.
    func document(at url: URL, accept: String) async throws -> Data
}

/// Why a document couldn't be read.
public nonisolated enum RemoteDocumentError: Error, Hashable, Sendable {
    case status(Int, ProblemDetails?)
    /// Bigger than the cap: a catalog never is.
    case tooLarge
    /// The request never got an answer (the message is the system's).
    case unreachable(String)
    /// The body isn't what the source expected.
    case malformed(String)
}

/// `RemoteDocumentFetching` over one ephemeral `URLSession`: no cookies, no cache, a 15 s timeout and an 8 MB cap.
/// A source that needs a credential passes it in `headers`. Redirects to another origin are refused, so a header
/// meant for one server never reaches another.
public nonisolated final class RemoteDocumentFetcher: NSObject, RemoteDocumentFetching, URLSessionTaskDelegate,
    Sendable {
    public static let maxBytes = 8 << 20

    private let headers: [String: String]
    private let session: URLSession

    public init(headers: [String: String] = [:], userAgent: String? = nil) {
        var all = headers
        if let userAgent { all["User-Agent"] = userAgent }
        self.headers = all
        let configuration = URLSessionConfiguration.ephemeral
        configuration.urlCache = nil
        configuration.httpCookieStorage = nil
        configuration.httpShouldSetCookies = false
        configuration.timeoutIntervalForRequest = 15
        configuration.waitsForConnectivity = false
        session = URLSession(configuration: configuration)
        super.init()
    }

    deinit {
        session.invalidateAndCancel()
    }

    public func document(at url: URL, accept: String) async throws -> Data {
        var request = URLRequest(url: url, cachePolicy: .reloadIgnoringLocalCacheData, timeoutInterval: 15)
        request.setValue(accept, forHTTPHeaderField: "Accept")
        for (name, value) in headers { request.setValue(value, forHTTPHeaderField: name) }
        let bytes: URLSession.AsyncBytes
        let response: URLResponse
        do {
            (bytes, response) = try await session.bytes(for: request, delegate: self)
        } catch {
            throw RemoteDocumentError.unreachable(error.localizedDescription)
        }
        defer { bytes.task.cancel() }
        if response.expectedContentLength > Int64(Self.maxBytes) { throw RemoteDocumentError.tooLarge }
        var data = Data()
        do {
            for try await byte in bytes {
                guard data.count < Self.maxBytes else { throw RemoteDocumentError.tooLarge }
                data.append(byte)
            }
        } catch let error as RemoteDocumentError {
            throw error
        } catch {
            throw RemoteDocumentError.unreachable(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? 200
        guard (200..<300).contains(status) else {
            throw RemoteDocumentError.status(status, try? JSONDecoder().decode(ProblemDetails.self, from: data))
        }
        return data
    }

    /// Redirects stay on the origin asked for, so a header meant for one server never reaches another.
    public func urlSession(_ session: URLSession, task: URLSessionTask,
                           willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest)
        async -> URLRequest? {
        guard let original = task.originalRequest?.url, let target = request.url else { return nil }
        let sameOrigin = original.scheme?.lowercased() == target.scheme?.lowercased()
            && original.host()?.lowercased() == target.host()?.lowercased() && original.port == target.port
        return sameOrigin ? request : nil
    }
}
