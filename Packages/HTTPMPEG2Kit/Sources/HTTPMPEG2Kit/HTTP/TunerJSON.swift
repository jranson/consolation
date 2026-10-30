import Foundation

/// Decoders for the device's JSON payloads. `HDHomeRunClient` uses these; they are public so hosts can
/// decode cached payloads and test fixtures the same way.
///
/// Arrays are lenient: an entry that cannot be decoded (for example a channel without `GuideNumber`) is
/// dropped instead of failing the whole payload. Anything that is not JSON of the right overall shape
/// throws `HDHomeRunClientError.decoding`.
public nonisolated enum TunerJSON {
    /// `discover.json`.
    public static func discovery(from data: Data) throws(HDHomeRunClientError) -> TunerDiscovery {
        try decode(TunerDiscovery.self, from: data, endpoint: "discover.json")
    }

    /// `lineup.json`, with any `show=` or `tuning` options.
    public static func lineup(from data: Data) throws(HDHomeRunClientError) -> [LineupChannel] {
        try decode(LossyArray<LineupChannel>.self, from: data, endpoint: "lineup.json").elements
    }

    /// `status.json`.
    public static func tunerStatus(from data: Data) throws(HDHomeRunClientError) -> [TunerStatus] {
        try decode(LossyArray<TunerStatus>.self, from: data, endpoint: "status.json").elements
    }

    /// `lineup_status.json`.
    public static func lineupStatus(from data: Data) throws(HDHomeRunClientError) -> LineupStatus {
        try decode(LineupStatus.self, from: data, endpoint: "lineup_status.json")
    }

    static func decode<Value: Decodable>(
        _ type: Value.Type, from data: Data, endpoint: String
    ) throws(HDHomeRunClientError) -> Value {
        do {
            return try JSONDecoder().decode(type, from: data)
        } catch let error as DecodingError {
            throw .decoding("\(endpoint): \(summary(of: error))")
        } catch {
            throw .decoding("\(endpoint): \(error.localizedDescription)")
        }
    }

    /// A one-line description of a decoding failure, for logs. Never includes payload values.
    private static func summary(of error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let keys = context.codingPath.map(\.stringValue).joined(separator: ".")
            return keys.isEmpty ? "top level" : keys
        }
        switch error {
        case .typeMismatch(_, let context):
            return "type mismatch at \(path(context))"
        case .valueNotFound(_, let context):
            return "missing value at \(path(context))"
        case .keyNotFound(let key, let context):
            return "missing key \(key.stringValue) at \(path(context))"
        case .dataCorrupted(let context):
            return "malformed data at \(path(context))"
        @unknown default:
            return "unreadable data"
        }
    }
}
