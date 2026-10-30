//
//  HLSMultivariantPlaylist.swift
//  PlaybackKit
//
//  A line-preserving model of an HLS multivariant ("master") playlist and of attribute lists (RFC 8216 §4.2),
//  enough to find the variants and rewrite tags without disturbing anything else.
//

import Foundation

/// One `NAME=value` pair; `rawValue` is exactly as written, so quoted strings keep their quotes.
public nonisolated struct HLSAttribute: Equatable, Sendable {
    public var name: String
    public var rawValue: String
}

public nonisolated struct HLSAttributeList: Equatable, Sendable {
    static let maxAttributes = 256

    public private(set) var attributes: [HLSAttribute]

    public init(parsing text: Substring) {
        var attributes: [HLSAttribute] = []
        var index = text.startIndex
        while index < text.endIndex, attributes.count < Self.maxAttributes,
              let equals = text[index...].firstIndex(of: "=") {
            let name = text[index..<equals].trimmingCharacters(in: .whitespaces)
            let valueStart = text.index(after: equals)
            var valueEnd = text[valueStart...].firstIndex(of: ",") ?? text.endIndex
            if valueStart < text.endIndex, text[valueStart] == "\"" {
                let afterQuote = text.index(after: valueStart)
                valueEnd = text[afterQuote...].firstIndex(of: "\"").map { text.index(after: $0) } ?? text.endIndex
            }
            attributes.append(HLSAttribute(name: name, rawValue: String(text[valueStart..<valueEnd])))
            guard let comma = text[valueEnd...].firstIndex(of: ",") else { break }
            index = text.index(after: comma)
        }
        self.attributes = attributes
    }

    /// The value of `name`, without quotes.
    public subscript(name: String) -> String? {
        guard let raw = attributes.first(where: { $0.name == name })?.rawValue else { return nil }
        guard raw.count >= 2, raw.hasPrefix("\""), raw.hasSuffix("\"") else { return raw }
        return String(raw.dropFirst().dropLast())
    }

    public func contains(_ name: String) -> Bool {
        attributes.contains { $0.name == name }
    }

    /// Replaces `name`'s value, or appends it.
    public mutating func set(_ name: String, rawValue: String) {
        if let index = attributes.firstIndex(where: { $0.name == name }) {
            attributes[index].rawValue = rawValue
        } else {
            attributes.append(HLSAttribute(name: name, rawValue: rawValue))
        }
    }

    public var text: String {
        attributes.map { "\($0.name)=\($0.rawValue)" }.joined(separator: ",")
    }
}

public nonisolated struct HLSMultivariantPlaylist: Equatable, Sendable {
    static let maxLines = 100_000

    public nonisolated struct Variant: Equatable, Sendable {
        public var attributes: HLSAttributeList
        /// As written in the playlist; may be relative.
        public var uri: String
        /// Index of the `EXT-X-STREAM-INF` line in `lines`.
        public var tagLine: Int
    }

    public private(set) var lines: [String]
    public private(set) var variants: [Variant]
    /// `EXT-X-MEDIA` attribute lists.
    public private(set) var renditions: [HLSAttributeList]

    /// Parses playlist text; nil when it doesn't start with `#EXTM3U` or is absurdly long.
    public init?(text: String) {
        let lines = text.split(omittingEmptySubsequences: false, whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        guard lines.count <= Self.maxLines,
              lines.first(where: { !$0.isEmpty })?.trimmingPrefix("\u{FEFF}").hasPrefix("#EXTM3U") == true else {
            return nil
        }
        var variants: [Variant] = []
        var renditions: [HLSAttributeList] = []
        for (index, line) in lines.enumerated() {
            if line.hasPrefix("#EXT-X-STREAM-INF:") {
                let attributes = HLSAttributeList(parsing: line.dropFirst("#EXT-X-STREAM-INF:".count))
                let uri = lines[(index + 1)...].first { !$0.isEmpty && !$0.hasPrefix("#") }
                if let uri {
                    variants.append(Variant(attributes: attributes, uri: uri, tagLine: index))
                }
            } else if line.hasPrefix("#EXT-X-MEDIA:") {
                renditions.append(HLSAttributeList(parsing: line.dropFirst("#EXT-X-MEDIA:".count)))
            }
        }
        self.lines = lines
        self.variants = variants
        self.renditions = renditions
    }

    /// True for a multivariant playlist; false for a media playlist.
    public var isMultivariant: Bool { !variants.isEmpty }

    /// The audio rendition AVPlayer would pick for `group`: DEFAULT=YES, else the first with a URI.
    public func defaultAudioRendition(group: String) -> HLSAttributeList? {
        let candidates = renditions.filter { $0["TYPE"] == "AUDIO" && $0["GROUP-ID"] == group && $0["URI"] != nil }
        return candidates.first { $0["DEFAULT"] == "YES" } ?? candidates.first
    }
}

/// The init segment and first media segment of an HLS media playlist, for probing.
nonisolated struct HLSMediaPlaylistReferences: Equatable, Sendable {
    var initURL: URL?
    var initRange: ClosedRange<Int>?
    var firstSegmentURL: URL?
    var firstSegmentRange: ClosedRange<Int>?

    init(text: String, baseURL: URL) {
        var pendingRange: ClosedRange<Int>?
        for rawLine in text.split(whereSeparator: \.isNewline).prefix(HLSMultivariantPlaylist.maxLines) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("#EXT-X-MAP:"), initURL == nil {
                let attributes = HLSAttributeList(parsing: line.dropFirst("#EXT-X-MAP:".count))
                initURL = attributes["URI"].flatMap { URL(string: $0, relativeTo: baseURL)?.absoluteURL }
                initRange = attributes["BYTERANGE"].flatMap(Self.byteRange)
            } else if line.hasPrefix("#EXT-X-BYTERANGE:") {
                pendingRange = Self.byteRange(String(line.dropFirst("#EXT-X-BYTERANGE:".count)))
            } else if !line.isEmpty, !line.hasPrefix("#") {
                firstSegmentURL = URL(string: line, relativeTo: baseURL)?.absoluteURL
                firstSegmentRange = pendingRange
                return
            }
        }
    }

    /// `length[@offset]`; a missing offset means 0 (we only read the first segment).
    static func byteRange(_ text: String) -> ClosedRange<Int>? {
        let parts = text.split(separator: "@")
        guard !parts.isEmpty, parts.count <= 2, let length = Int(parts[0]), length > 0, length <= 1 << 30 else {
            return nil
        }
        let offset = parts.count == 2 ? Int(parts[1]) : 0
        guard let offset, offset >= 0, offset <= Int.max - length else { return nil }
        return offset...(offset + length - 1)
    }
}
