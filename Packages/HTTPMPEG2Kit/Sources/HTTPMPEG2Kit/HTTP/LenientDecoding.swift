import Foundation

// Lenient readers for device JSON. Firmware drifts from the published documentation: keys go missing,
// flags arrive as 1/0, true/false or "1", and numbers sometimes arrive as strings. None of these readers
// throws; a value of the wrong shape reads as absent.

extension KeyedDecodingContainer {
    /// A string, or a number rendered as a string. Empty strings read as absent.
    nonisolated func lenientString(_ key: Key) -> String? {
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return value.isEmpty ? nil : value
        }
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return String(value)
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key), value.isFinite {
            return String(value)
        }
        return nil
    }

    /// An integer, an integral floating-point number in range, a numeric string, or a Bool (1 or 0).
    nonisolated func lenientInt(_ key: Key) -> Int? {
        if let value = try? decodeIfPresent(Int.self, forKey: key) {
            return value
        }
        if let value = try? decodeIfPresent(Double.self, forKey: key) {
            return Int(exactly: value)
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            return Int(value.trimmingCharacters(in: .whitespaces))
        }
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value ? 1 : 0
        }
        return nil
    }

    /// A flag sent as a Bool, a number (non-zero is true) or a string ("1", "true", "yes", "0", ...).
    nonisolated func lenientBool(_ key: Key) -> Bool? {
        if let value = try? decodeIfPresent(Bool.self, forKey: key) {
            return value
        }
        if let value = lenientInt(key) {
            return value != 0
        }
        if let value = try? decodeIfPresent(String.self, forKey: key) {
            switch value.trimmingCharacters(in: .whitespaces).lowercased() {
            case "true", "yes": return true
            case "false", "no": return false
            default: return nil
            }
        }
        return nil
    }

    /// An absolute URL with a scheme and host. Anything else reads as absent.
    nonisolated func lenientURL(_ key: Key) -> URL? {
        guard let string = lenientString(key), let url = URL(string: string),
              url.scheme != nil, url.host() != nil else { return nil }
        return url
    }

    /// An array of strings; non-string elements are skipped.
    nonisolated func lenientStrings(_ key: Key) -> [String] {
        guard let values = try? decodeIfPresent([LossyValue<String>].self, forKey: key) else { return [] }
        return values.compactMap(\.value)
    }
}

/// Decodes one element of an array without failing the whole array.
nonisolated struct LossyValue<Value: Decodable>: Decodable {
    let value: Value?

    init(from decoder: any Decoder) throws {
        value = try? Value(from: decoder)
    }
}

/// An array whose malformed elements are dropped instead of failing the whole payload.
nonisolated struct LossyArray<Element: Decodable>: Decodable {
    let elements: [Element]

    init(from decoder: any Decoder) throws {
        elements = try [LossyValue<Element>](from: decoder).compactMap(\.value)
    }
}
