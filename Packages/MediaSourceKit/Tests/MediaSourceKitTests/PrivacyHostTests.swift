import Foundation
import Testing

/// Privacy enforcement: every host named in a hard-coded `http://` or `https://` URL in the sources of MediaSourceKit
/// and HTTPMPEG2Kit must be on the allow-list in `PRIVACY-HOSTS.txt`, next to `PRIVACY.md` at the repository root.
/// Adding a third-party endpoint therefore fails here until it is listed (and itemized in `PRIVACY.md`). Comment lines
/// (documentation examples), interpolated hosts (`http://\(host)`) and the reserved documentation names (192.0.2.x,
/// 198.51.100.x, 203.0.113.x, example.com/.net/.org) are skipped.
@Suite("Privacy hosts")
struct PrivacyHostTests {
    static let packageRoot = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()  // MediaSourceKitTests
        .deletingLastPathComponent()  // Tests
        .deletingLastPathComponent()  // MediaSourceKit
    static let repositoryRoot = packageRoot
        .deletingLastPathComponent()  // Packages
        .deletingLastPathComponent()
    /// The packages whose code may connect somewhere.
    static let scannedSources = [
        packageRoot.appending(path: "Sources", directoryHint: .isDirectory),
        repositoryRoot.appending(path: "Packages/HTTPMPEG2Kit/Sources", directoryHint: .isDirectory)
    ]

    /// The hosts after every `http://` and `https://` in `text`, lowercased, without ports or paths, skipping
    /// comment lines and reserved documentation hosts.
    static func hosts(in text: String) -> [String] {
        text.split(whereSeparator: \.isNewline)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .flatMap { hosts(inLine: $0) }
            .filter { !isDocumentationHost($0) }
    }

    private static func hosts(inLine line: Substring) -> [String] {
        var hosts: [String] = []
        var remaining = line
        while let range = remaining.range(of: "://") {
            let scheme = remaining[..<range.lowerBound].reversed().prefix { $0.isLetter }
            let afterScheme = remaining[range.upperBound...]
            if ["http", "https"].contains(String(scheme.reversed()).lowercased()) {
                let host = afterScheme.prefix { $0.isLetter || $0.isNumber || $0 == "." || $0 == "-" }
                if !host.isEmpty { hosts.append(host.lowercased()) }
            }
            remaining = afterScheme
        }
        return hosts
    }

    /// RFC 5737 addresses and RFC 2606 names, which never reach a real endpoint.
    static func isDocumentationHost(_ host: String) -> Bool {
        if ["192.0.2.", "198.51.100.", "203.0.113."].contains(where: host.hasPrefix) { return true }
        return ["example.com", "example.net", "example.org"].contains { host == $0 || host.hasSuffix("." + $0) }
    }

    /// One host per line; `#` starts a comment.
    static func allowList(_ text: String) -> Set<String> {
        Set(text.split(whereSeparator: \.isNewline).compactMap { line in
            let host = line.split(separator: "#", maxSplits: 1, omittingEmptySubsequences: false).first?
                .trimmingCharacters(in: .whitespaces).lowercased() ?? ""
            return host.isEmpty ? nil : host
        })
    }

    @Test func theScannerFindsHosts() {
        let text = #"""
            let a = "https://API.vendor.tv/v2?x=1"; let b = "HTTP://lan.vendor.tv:80/"
            let c = "http://\(host)/discover.json"; let d = URL(string: "https://192.0.2.10/")
            /// Documentation: `http://hdhomerun.local` is only an example.
            let e = "ftp://files.vendor.tv"; let f = "https://cdn.example.com/x"
            """#
        #expect(Self.hosts(in: text) == ["api.vendor.tv", "lan.vendor.tv"])
        #expect(Self.allowList("# comment\n\nplex.tv # sign-in\n  api.example.org\n") == ["plex.tv", "api.example.org"])
    }

    @Test func everyHardCodedHostIsAllowListed() throws {
        let allowList = Self.allowList(try String(
            contentsOf: Self.repositoryRoot.appending(path: "PRIVACY-HOSTS.txt"), encoding: .utf8))
        for sources in Self.scannedSources {
            let enumerator = try #require(FileManager.default.enumerator(at: sources, includingPropertiesForKeys: nil))
            var scanned = 0
            for case let file as URL in enumerator where file.pathExtension == "swift" {
                scanned += 1
                let text = try String(contentsOf: file, encoding: .utf8)
                for host in Self.hosts(in: text) where !allowList.contains(host) {
                    Issue.record("\(file.lastPathComponent) names \(host), which PRIVACY-HOSTS.txt doesn't list")
                }
            }
            #expect(scanned > 10, "\(sources.path) has Swift sources")
        }
    }
}
