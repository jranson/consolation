//
//  DASHManifest.swift
//  PlaybackKit
//
//  A parsed MPEG-DASH MPD, holding what the MPD-to-HLS translator needs. Attribute inheritance
//  (Period > AdaptationSet > Representation) and BaseURL resolution are already applied.
//
//  Supported: static MPDs with SegmentTemplate (SegmentTimeline or @duration). Multi-period content is parsed but only
//  the first Period is translated; SegmentBase, SegmentList and dynamic MPDs are recognised and rejected.
//

import Foundation

public nonisolated struct DASHManifest: Equatable, Sendable {
    public nonisolated enum PresentationType: String, Equatable, Sendable {
        case staticPresentation = "static"
        case dynamic
    }

    public var presentationType: PresentationType
    /// `@mediaPresentationDuration` in seconds.
    public var mediaPresentationDuration: Double?
    /// `@minBufferTime` in seconds.
    public var minBufferTime: Double?
    public var periods: [DASHPeriod]

    public init(presentationType: PresentationType, mediaPresentationDuration: Double?, minBufferTime: Double?,
                periods: [DASHPeriod]) {
        self.presentationType = presentationType
        self.mediaPresentationDuration = mediaPresentationDuration
        self.minBufferTime = minBufferTime
        self.periods = periods
    }

    /// Parses an MPD. `manifestURL` is where it was fetched from; relative BaseURLs and templates resolve against it.
    public init(data: Data, manifestURL: URL) throws(DASHManifestError) {
        self = try DASHManifestParser.parse(data: data, manifestURL: manifestURL)
    }

    /// The duration of `period`: its `@duration`, else up to the next Period's start or the presentation's end.
    public func duration(of period: DASHPeriod) -> Double? {
        if let duration = period.duration { return duration }
        let start = period.start ?? 0
        if let index = periods.firstIndex(of: period), index + 1 < periods.count,
           let nextStart = periods[index + 1].start {
            return nextStart - start
        }
        return mediaPresentationDuration.map { $0 - start }
    }
}

public nonisolated struct DASHPeriod: Equatable, Sendable {
    public var id: String?
    /// `@start` in seconds.
    public var start: Double?
    /// `@duration` in seconds.
    public var duration: Double?
    public var adaptationSets: [DASHAdaptationSet]

    public init(id: String?, start: Double?, duration: Double?, adaptationSets: [DASHAdaptationSet]) {
        self.id = id
        self.start = start
        self.duration = duration
        self.adaptationSets = adaptationSets
    }
}

public nonisolated struct DASHAdaptationSet: Equatable, Sendable {
    public nonisolated enum ContentType: String, Equatable, Sendable {
        case video
        case audio
        case text
        case other
    }

    public var id: String?
    public var contentType: ContentType
    /// `@lang` (RFC 5646).
    public var language: String?
    /// True when a `Role` with value `main` is present.
    public var isMain: Bool
    public var representations: [DASHRepresentation]

    public init(id: String?, contentType: ContentType, language: String?, isMain: Bool,
                representations: [DASHRepresentation]) {
        self.id = id
        self.contentType = contentType
        self.language = language
        self.isMain = isMain
        self.representations = representations
    }
}

public nonisolated struct DASHRepresentation: Equatable, Sendable {
    public var id: String
    public var bandwidth: Int
    public var mimeType: String?
    /// `@codecs` as written in the MPD; often incomplete (`hvc1`), see `DASHToHLSTranslator`.
    public var codecs: String?
    public var width: Int?
    public var height: Int?
    public var frameRate: Double?
    public var audioSamplingRate: Int?
    /// From `AudioChannelConfiguration`.
    public var audioChannels: Int?
    /// From an Essential or Supplemental property `urn:mpeg:mpegB:cicp:TransferCharacteristics`.
    public var transferCharacteristics: Int?
    /// The fully resolved BaseURL every template of this Representation is relative to.
    public var baseURL: URL
    public var segmentTemplate: DASHSegmentTemplate?
    /// Set when the Representation is addressed with `SegmentBase` or `SegmentList`, which are not supported yet.
    public var unsupportedAddressing: String?

    public init(id: String, bandwidth: Int, baseURL: URL) {
        self.id = id
        self.bandwidth = bandwidth
        self.baseURL = baseURL
    }
}

public nonisolated struct DASHSegmentTemplate: Equatable, Sendable {
    public var timescale: Int64
    public var media: String?
    public var initialization: String?
    public var startNumber: Int
    /// `@duration` in timescale units, for templates without a SegmentTimeline.
    public var duration: Int64?
    public var presentationTimeOffset: Int64
    public var timeline: [DASHTimelineEntry]?

    public init(timescale: Int64 = 1, media: String? = nil, initialization: String? = nil, startNumber: Int = 1,
                duration: Int64? = nil, presentationTimeOffset: Int64 = 0, timeline: [DASHTimelineEntry]? = nil) {
        self.timescale = timescale
        self.media = media
        self.initialization = initialization
        self.startNumber = startNumber
        self.duration = duration
        self.presentationTimeOffset = presentationTimeOffset
        self.timeline = timeline
    }
}

/// One `S` element: `@t` (optional), `@d` and `@r` (-1 repeats until the next `@t` or the end of the Period).
public nonisolated struct DASHTimelineEntry: Equatable, Sendable {
    public var time: Int64?
    public var duration: Int64
    public var repeatCount: Int

    public init(time: Int64?, duration: Int64, repeatCount: Int) {
        self.time = time
        self.duration = duration
        self.repeatCount = repeatCount
    }
}

/// One media segment after template expansion.
public nonisolated struct DASHSegment: Equatable, Sendable {
    public var number: Int
    /// Start time in timescale units, as used by `$Time$`.
    public var time: Int64
    /// Duration in seconds.
    public var duration: Double
    public var url: URL
}

public nonisolated enum DASHManifestError: Error, Equatable, Sendable {
    /// The XML could not be parsed; the line is where the parser stopped.
    case malformedXML(line: Int)
    /// The document's root element is not `MPD`.
    case notAnMPD
    case noPeriods
    /// The document exceeds a safety limit (elements, timeline entries or segments).
    case tooLarge
    /// A feature that is recognised but not supported yet, such as a dynamic MPD or `SegmentBase`.
    case unsupported(String)
    /// A Representation has neither a SegmentTimeline nor a usable `@duration`, or no media template.
    case missingSegmentInformation(representationID: String)
    /// A template expanded to something that isn't a URL.
    case invalidURL(representationID: String)
    /// No audio or video Representation could be translated.
    case noPlayableRepresentations
}
