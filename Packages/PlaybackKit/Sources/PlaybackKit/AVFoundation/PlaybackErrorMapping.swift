//
//  PlaybackErrorMapping.swift
//  PlaybackKit
//
//  Maps AVFoundation, CoreMedia, URL-loading and manifest errors to PlaybackError. The domain and code kept are
//  the innermost (most specific) ones, so CoreMedia codes such as -12927 reach Copy Details. Details never
//  contain a URL's query string or fragment.
//

import Foundation

nonisolated enum PlaybackErrorMapping {
    static let httpDomain = "HTTPStatus"
    static let manifestDomain = "PlaybackKit.Manifest"
    static let avFoundationDomain = "AVFoundationErrorDomain"
    static let coreMediaDomain = "CoreMediaErrorDomain"

    /// AVPlayer's rejections of an HLS multivariant playlist that a repaired playlist can fix.
    static let multivariantRejectionCodes: Set<Int> = [-12927, -12646, -1002]

    /// AVPlayer's refusal of a multivariant playlist after filtering out every variant, as it does with HDR-only
    /// playlists on a display that can't show HDR: AVFoundation -11868 (no compatible alternates) or CoreMedia -17223
    /// ("Cannot open"). The engine then plays the media playlists directly.
    static func isHDRVariantRejection(_ error: any Error) -> Bool {
        chain(error).contains { error in
            (error.domain == avFoundationDomain && error.code == -11868)
                || (error.domain == coreMediaDomain && error.code == -17223)
        }
    }

    /// The error for an HDR stream that couldn't play on a display without HDR, even through tone mapping. Keeps
    /// the underlying domain, code and detail for Copy Details.
    static func hdrDisplayRequired(from error: (any Error)?) -> PlaybackError {
        let mapped = playbackError(from: error)
        let detail = mapped.detail.isEmpty
            ? "The display can't show HDR, and the system couldn't convert this stream for it." : mapped.detail
        return PlaybackError(kind: .unsupportedFormat, title: "This HDR stream needs an HDR display", detail: detail,
                             domain: mapped.domain, code: mapped.code)
    }

    static var tooLarge: PlaybackError {
        PlaybackError(kind: .source, title: "The stream's manifest is too large",
                      detail: "A playlist or manifest exceeded the size limit.", domain: manifestDomain, code: 1)
    }

    /// The error and its `NSUnderlyingErrorKey` chain, outermost first.
    static func chain(_ error: any Error) -> [NSError] {
        var result = [error as NSError]
        while result.count < 8, let next = result[result.count - 1].userInfo[NSUnderlyingErrorKey] as? NSError {
            result.append(next)
        }
        return result
    }

    /// True when any error in the chain is one of AVPlayer's multivariant-playlist rejections.
    static func isMultivariantRejection(_ error: any Error) -> Bool {
        chain(error).contains { multivariantRejectionCodes.contains($0.code) }
    }

    static func playbackError(from error: (any Error)?, title: String? = nil) -> PlaybackError {
        guard let error else {
            return PlaybackError(kind: .source, title: title ?? "Playback failed")
        }
        if let playbackError = error as? PlaybackError {
            return playbackError
        }
        if let manifestError = error as? DASHManifestError {
            return playbackError(from: manifestError)
        }
        let errors = chain(error)
        let innermost = errors[errors.count - 1]
        let kind = kind(for: errors)
        let codes = errors.map { "\($0.domain) \($0.code)" }.joined(separator: " / ")
        let detail = redactingQueries("\(codes). \(errors[0].localizedDescription)")
        return PlaybackError(kind: kind, title: title ?? defaultTitle(for: kind, errors: errors), detail: detail,
                             domain: innermost.domain, code: innermost.code)
    }

    static func playbackError(from error: DASHManifestError) -> PlaybackError {
        let detail: String
        var kind = PlaybackError.Kind.source
        switch error {
        case .malformedXML(let line): detail = "The MPD is not well-formed XML (line \(line))."
        case .notAnMPD: detail = "The document is not an MPD."
        case .noPeriods: detail = "The MPD has no Period."
        case .tooLarge: detail = "The MPD exceeds a size limit."
        case .unsupported(let feature):
            detail = "Not supported yet: \(feature)."
            kind = .unsupportedFormat
        case .missingSegmentInformation: detail = "A Representation has no usable segment template."
        case .invalidURL: detail = "A segment template does not form a valid URL."
        case .noPlayableRepresentations:
            detail = "The MPD has no audio or video that can be played."
            kind = .unsupportedFormat
        }
        return PlaybackError(kind: kind, title: "Can't play this DASH stream", detail: detail,
                             domain: manifestDomain, code: nil)
    }

    private static func kind(for errors: [NSError]) -> PlaybackError.Kind {
        for error in errors.reversed() {
            switch error.domain {
            case NSURLErrorDomain:
                return error.code == NSURLErrorCancelled ? .cancelled : .network
            case avFoundationDomain where [-11828, -11829, -11838, -11848].contains(error.code):
                return .unsupportedFormat
            case avFoundationDomain where [-11821, -11833, -11839].contains(error.code):
                return .decoder
            case coreMediaDomain where error.code == -12847:
                return .unsupportedFormat
            default:
                continue
            }
        }
        return .source
    }

    private static func defaultTitle(for kind: PlaybackError.Kind, errors: [NSError]) -> String {
        if errors.contains(where: { multivariantRejectionCodes.contains($0.code) }) {
            return "The stream's playlist was rejected"
        }
        switch kind {
        case .network: return "Can't reach the stream"
        case .unsupportedFormat: return "This stream's format isn't supported"
        case .decoder: return "Can't decode this stream"
        case .renderer: return "Can't show this stream"
        case .cancelled: return "Playback was cancelled"
        case .source: return "Can't play this stream"
        }
    }

    /// Removes the query string and fragment from every URL in `text`.
    static func redactingQueries(_ text: String) -> String {
        text.replacing(/([A-Za-z][A-Za-z0-9+.\-]*:\/\/[^\s?#]*)[?#][^\s]*/) { match in match.output.1 }
    }
}
