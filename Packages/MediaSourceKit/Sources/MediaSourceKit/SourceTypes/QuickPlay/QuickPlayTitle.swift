import Foundation

/// The name a Quick Play item shows: the URL's last path component, unless that looks like a token (stream URLs
/// often carry one in the path), in which case the host, or "Video" without one. Home is the screen others see
/// most, so a token never becomes a card's title.
nonisolated enum QuickPlayTitle {
    static let fallback = "Video"

    /// The title for `url`, and whether it is the host (then the card needs no host subtitle as well).
    static func title(for url: URL) -> (title: String, isHost: Bool) {
        let last = url.lastPathComponent
        if !last.isEmpty, last != "/", !isTokenLike(last) { return (last, false) }
        guard let host = url.host(), !host.isEmpty else { return (fallback, false) }
        return (host, true)
    }

    /// True for a path component that looks like a credential or an opaque ID rather than a name:
    /// - base64-encoded JSON, as JWTs start (`eyJ…`);
    /// - 16 or more hex digits with nothing else but dashes (hashes, UUIDs, hex keys);
    /// - a run of letters and digits, 20 or longer, with digits and both cases (base64), or 32 or longer.
    /// It may hide an unusual file name; that card then shows the host instead.
    static func isTokenLike(_ component: String) -> Bool {
        let decoded = component.removingPercentEncoding ?? component
        if decoded.hasPrefix("eyJ"), decoded.count >= 16 { return true }
        let stem = (decoded as NSString).deletingPathExtension
        let hexDigits = stem.filter(\.isHexDigit).count
        if hexDigits >= 16, stem.allSatisfy({ $0.isHexDigit || $0 == "-" }) { return true }
        let runs = stem.split { !($0.isASCII && ($0.isLetter || $0.isNumber)) }
        return runs.contains { run in
            if run.count >= 32 { return true }
            guard run.count >= 20 else { return false }
            return run.contains(where: \.isNumber) && run.contains(where: \.isUppercase)
                && run.contains(where: \.isLowercase)
        }
    }
}
