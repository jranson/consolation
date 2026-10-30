import Foundation

/// What the device said when it accepted a stream request.
public nonisolated struct StreamOpenInfo: Sendable, Hashable {
    /// `X-HDHomeRun-Resource`, the tuner carrying the stream, for example `tuner2`.
    public let resource: String?
    /// `Content-Type`: `video/mpeg`, or `video/mpeg;codecs="hev1"` for ATSC 3.0.
    public let contentType: String?

    public init(resource: String?, contentType: String?) {
        self.resource = resource
        self.contentType = contentType
    }

    /// `2` for `tuner2`.
    public var tunerIndex: Int? {
        guard let resource else { return nil }
        return TunerStatus(resource: resource).tunerIndex
    }

    /// The response headers of an accepted stream, or the mapped error for any other response.
    /// Only `200` is accepted: any other status, including redirects and other 2xx codes, is an error.
    static func evaluate(_ response: URLResponse) -> Result<StreamOpenInfo, HDHomeRunClientError> {
        guard let http = response as? HTTPURLResponse else { return .failure(.invalidResponse) }
        guard http.statusCode == 200 else {
            return .failure(HDHomeRunClientError(
                status: http.statusCode, errorHeader: http.value(forHTTPHeaderField: "X-HDHomeRun-Error")))
        }
        return .success(StreamOpenInfo(
            resource: http.value(forHTTPHeaderField: "X-HDHomeRun-Resource"),
            contentType: http.value(forHTTPHeaderField: "Content-Type")
        ))
    }
}
