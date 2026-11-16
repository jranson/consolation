import Foundation

/// A link to a video on a hosting service that plays only in the service's own embedded player, never through our
/// engines (no stream extraction). Today: YouTube's watch, share (`youtu.be`), Shorts, live and embed links on the
/// `www.`, `m.` and `music.` hosts and the privacy-enhanced embed host, with `t=`/`start=` times and `list=`
/// playlists. Lookalike hosts (`youtube.com.example.net`, `notyoutube.com`) are refused.
///
/// Pure: reading a link never connects anywhere. The embed that plays it is the app's (`HostedVideo` there).
public nonisolated struct HostedVideoLink: Hashable, Sendable, Codable {
    /// The service's video identifier: 11 characters from `A–Z a–z 0–9 _ -`.
    public let videoID: String
    /// Where playback starts, in whole seconds, when the link names a time.
    public let startSeconds: Int?
    /// The playlist the link opened the video from, when it names one.
    public let playlistID: String?

    public init(videoID: String, startSeconds: Int? = nil, playlistID: String? = nil) {
        self.videoID = videoID
        self.startSeconds = startSeconds
        self.playlistID = playlistID
    }

    /// The link `url` names, or nil when it isn't a video link on a recognized host.
    public init?(url: URL) {
        guard let scheme = url.scheme?.lowercased(), ["http", "https"].contains(scheme),
              let host = url.host(percentEncoded: false)?.lowercased(), Self.hosts.contains(host),
              let components = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return nil }
        let segments = components.path.split(separator: "/").map(String.init)
        let query = Self.queryValues(components.queryItems ?? [])
        let candidate: String?
        if host == Self.shareHost {
            candidate = segments.count == 1 ? segments[0] : nil
        } else if segments == ["watch"] {
            candidate = query["v"]
        } else if segments.count == 2, Self.idPaths.contains(segments[0].lowercased()) {
            candidate = segments[1]
        } else {
            candidate = nil
        }
        guard let videoID = candidate, Self.isVideoID(videoID) else { return nil }
        let fragmentTime = components.fragment.flatMap { Self.fragmentTime($0) }
        let time = query["t"] ?? query["start"] ?? fragmentTime
        self.init(videoID: videoID, startSeconds: time.flatMap(Self.seconds),
                  playlistID: query["list"].flatMap { Self.isPlaylistID($0) ? $0 : nil })
    }

    /// Whether `url` is a link this type reads.
    public static func recognizes(_ url: URL) -> Bool {
        HostedVideoLink(url: url) != nil
    }

    // MARK: - Reading links

    static let shareHost = "youtu.be"
    static let hosts: Set<String> = [
        "youtube.com", "www.youtube.com", "m.youtube.com", "music.youtube.com",
        "youtube-nocookie.com", "www.youtube-nocookie.com", shareHost
    ]
    /// Paths whose second segment is the video: `/shorts/<id>`, `/live/<id>`, `/embed/<id>`, the old `/v/<id>`.
    static let idPaths: Set<String> = ["shorts", "live", "embed", "v"]
    static let idCharacters = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZ" + "abcdefghijklmnopqrstuvwxyz" + "0123456789_-")
    /// The longest time accepted: a day. A larger or malformed time starts at the beginning.
    static let maxStart = 86_400

    static func isVideoID(_ text: String) -> Bool {
        text.count == 11 && text.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    static func isPlaylistID(_ text: String) -> Bool {
        (2...64).contains(text.count) && text.unicodeScalars.allSatisfy(idCharacters.contains)
    }

    /// The first value of each query item.
    private static func queryValues(_ items: [URLQueryItem]) -> [String: String] {
        var values: [String: String] = [:]
        for item in items {
            guard let value = item.value, !value.isEmpty, values[item.name] == nil else { continue }
            values[item.name] = value
        }
        return values
    }

    /// `t=90` in a fragment (`#t=1m30s`).
    private static func fragmentTime(_ fragment: String) -> String? {
        let pairs = fragment.split(separator: "&").map { $0.split(separator: "=", maxSplits: 1) }
        return pairs.first { $0.count == 2 && $0[0] == "t" }.map { String($0[1]) }
    }

    /// `90`, `90s`, `1m30s` or `1h2m3s` in seconds; nil when malformed, zero or over a day.
    static func seconds(_ text: String) -> Int? {
        if let plain = Int(text) { return (1...maxStart).contains(plain) ? plain : nil }
        var total = 0
        var digits = ""
        var lastUnit = Int.max
        for character in text.lowercased() {
            if character.isASCII, character.isNumber {
                digits.append(character)
                continue
            }
            let unit: Int
            switch character {
            case "h": unit = 3_600
            case "m": unit = 60
            case "s": unit = 1
            default: return nil
            }
            // Units go largest first, each once.
            guard unit < lastUnit, digits.count <= 5, let value = Int(digits) else { return nil }
            total += value * unit
            lastUnit = unit
            digits = ""
        }
        guard digits.isEmpty, (1...maxStart).contains(total) else { return nil }
        return total
    }
}
