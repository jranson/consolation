import Foundation

/// Turns what a user types into a device base URL.
///
/// Accepts `hdhomerun.local`, `hdhr-1234abc2.local`, `192.0.2.10`, `192.0.2.10:8080`, `[2001:db8::1]`,
/// a bare IPv6 address, or a full `http://` (or `https://`) URL whose path, query and fragment are dropped.
/// The result has no trailing slash, for example `http://hdhomerun.local`.
public nonisolated enum TunerHost {
    /// The base URL for `input`, or nil when it is not a usable host.
    public static func baseURL(for input: String) -> URL? {
        let trimmed = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !trimmed.contains(where: \.isWhitespace) else { return nil }
        guard let split = splitScheme(trimmed), let authority = parseAuthority(split.rest) else { return nil }
        let scheme = split.scheme
        var string = "\(scheme)://"
        if authority.isIPv6 {
            string += "[" + authority.host.replacingOccurrences(of: "%", with: "%25") + "]"
        } else {
            string += authority.host
        }
        if let port = authority.port, port != defaultPort(scheme) {
            string += ":\(port)"
        }
        return URL(string: string)
    }

    /// True for a dotted-quad IPv4 literal such as `192.0.2.10`.
    public static func isIPv4Literal(_ host: String) -> Bool {
        let octets = host.split(separator: ".", omittingEmptySubsequences: false)
        guard octets.count == 4 else { return false }
        return octets.allSatisfy { octet in
            guard (1...3).contains(octet.count), octet.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = Int(octet) else { return false }
            return value <= 255
        }
    }

    private struct Authority {
        var host: String
        var port: Int?
        var isIPv6: Bool
    }

    private static func defaultPort(_ scheme: String) -> Int { scheme == "https" ? 443 : 80 }

    /// Splits off `http://` or `https://`. Inputs without a scheme are treated as http.
    private static func splitScheme(_ input: String) -> (scheme: String, rest: Substring)? {
        guard let range = input.range(of: "://") else { return ("http", input[...]) }
        let scheme = input[..<range.lowerBound].lowercased()
        guard scheme == "http" || scheme == "https" else { return nil }
        return (scheme, input[range.upperBound...])
    }

    private static func parseAuthority(_ remainder: Substring) -> Authority? {
        let end = remainder.firstIndex { $0 == "/" || $0 == "?" || $0 == "#" } ?? remainder.endIndex
        let authority = remainder[..<end]
        guard !authority.isEmpty, !authority.contains("@") else { return nil }
        if authority.hasPrefix("[") {
            return parseBracketedIPv6(authority)
        }
        let colons = authority.count(where: { $0 == ":" })
        if colons >= 2 {
            return isIPv6Literal(authority) ? Authority(host: authority.lowercased(), isIPv6: true) : nil
        }
        var host = authority
        var port: Int?
        if colons == 1, let colon = authority.firstIndex(of: ":") {
            host = authority[..<colon]
            guard let parsed = parsePort(authority[authority.index(after: colon)...]) else { return nil }
            port = parsed
        }
        guard isHostName(host) else { return nil }
        return Authority(host: host.lowercased(), port: port, isIPv6: false)
    }

    private static func parseBracketedIPv6(_ authority: Substring) -> Authority? {
        guard let close = authority.firstIndex(of: "]") else { return nil }
        let address = authority[authority.index(after: authority.startIndex)..<close]
            .replacingOccurrences(of: "%25", with: "%")
        guard isIPv6Literal(address[...]) else { return nil }
        let rest = authority[authority.index(after: close)...]
        var port: Int?
        if !rest.isEmpty {
            guard rest.hasPrefix(":"), let parsed = parsePort(rest.dropFirst()) else { return nil }
            port = parsed
        }
        return Authority(host: address.lowercased(), port: port, isIPv6: true)
    }

    private static func parsePort(_ text: Substring) -> Int? {
        guard !text.isEmpty, text.count <= 5, text.allSatisfy({ $0.isASCII && $0.isNumber }),
              let port = Int(text), (1...65_535).contains(port) else { return nil }
        return port
    }

    /// Letters, digits, hyphens, underscores and dots, with no empty labels.
    private static func isHostName(_ host: Substring) -> Bool {
        guard !host.isEmpty, host.count <= 253 else { return false }
        let labels = host.split(separator: ".", omittingEmptySubsequences: false)
        return labels.allSatisfy { label in
            !label.isEmpty && label.count <= 63
                && label.allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-" || $0 == "_") }
        }
    }

    /// Hex digits and colons (at least two), optionally an embedded IPv4 tail and a `%zone`.
    private static func isIPv6Literal(_ text: Substring) -> Bool {
        let parts = text.split(separator: "%", maxSplits: 1, omittingEmptySubsequences: false)
        guard let address = parts.first, address.count(where: { $0 == ":" }) >= 2 else { return false }
        if parts.count == 2 {
            let zone = parts[1]
            guard !zone.isEmpty, zone.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber) }) else {
                return false
            }
        }
        return address.allSatisfy { $0.isHexDigit || $0 == ":" || $0 == "." }
    }
}
