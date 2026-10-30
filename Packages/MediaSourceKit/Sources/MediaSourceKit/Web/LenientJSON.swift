import Foundation

/// String-keyed access for servers' open-ended JSON (OPDS profile terms keyed by URIs, Plex's `MediaContainer`):
/// producers vary in what they send for a member, so every read is lenient (a wrong type reads as absent).
nonisolated struct JSONKey: CodingKey {
    let stringValue: String
    var intValue: Int? { nil }

    init(_ string: String) {
        stringValue = string
    }

    init?(stringValue: String) {
        self.stringValue = stringValue
    }

    init?(intValue: Int) {
        nil
    }
}

nonisolated extension KeyedDecodingContainer where K == JSONKey {
    func string(_ key: String) -> String? {
        (try? decodeIfPresent(String.self, forKey: JSONKey(key))).flatMap { $0 }
    }

    /// A string, or the strings of an array (`rel`, `language`, `subject`).
    func strings(_ key: String) -> [String] {
        if let one = string(key) { return [one] }
        return (try? decodeIfPresent([String].self, forKey: JSONKey(key))).flatMap { $0 } ?? []
    }

    func number(_ key: String) -> Double? {
        if let value = (try? decodeIfPresent(Double.self, forKey: JSONKey(key))).flatMap({ $0 }) { return value }
        return string(key).flatMap(Double.init)
    }

    func integer(_ key: String) -> Int? {
        number(key).flatMap { $0.isFinite ? Int(exactly: $0.rounded()) : nil }
    }

    func bool(_ key: String) -> Bool? {
        (try? decodeIfPresent(Bool.self, forKey: JSONKey(key))).flatMap { $0 }
    }

    /// An RFC 3339 date-time, or a calendar date (`published: "2026-10-11"`) at midnight UTC.
    func date(_ key: String) -> Date? {
        guard let text = string(key) else { return nil }
        return OPDSDates.parse(text)
    }

    func array<T: Decodable>(_ key: String, of type: T.Type) -> [T] {
        guard let items = try? decodeIfPresent([Lenient<T>].self, forKey: JSONKey(key)) else { return [] }
        return items.compactMap(\.value)
    }

    func nested(_ key: String) -> KeyedDecodingContainer<JSONKey>? {
        try? nestedContainer(keyedBy: JSONKey.self, forKey: JSONKey(key))
    }
}

/// One element of an array that may not decode; a bad element is dropped instead of failing the whole array.
nonisolated struct Lenient<T: Decodable>: Decodable {
    let value: T?

    init(from decoder: any Decoder) throws {
        value = try? T(from: decoder)
    }
}

/// RFC 3339 date-times and calendar dates, as OPDS and other catalogs send them.
nonisolated enum OPDSDates {
    static func parse(_ text: String) -> Date? {
        if let date = try? Date(text, strategy: .iso8601) { return date }
        if let date = try? Date(text, strategy: Date.ISO8601FormatStyle(includingFractionalSeconds: true)) {
            return date
        }
        return try? Date(text, strategy: Date.ISO8601FormatStyle().year().month().day())
    }
}
