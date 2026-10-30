//
//  MediaProbe.swift
//  PlaybackKit
//
//  Network probes that read codec, range and frame-rate facts from init segments and segment heads, for the
//  DASH translator and the HLS multivariant repair. Each probe is a few small GETs to the stream's own origin;
//  failures return nothing rather than throwing, because the caller can still play without them.
//

import Foundation

nonisolated enum MediaProbe {
    static let initSegmentLimit = 2 << 20
    static let segmentHeadLength = 256 << 10
    static let playlistHeadLength = 256 << 10
    static let manifestLimit = 16 << 20

    /// The tracks of the init segment at `url`.
    @concurrent
    static func initTracks(url: URL, range: ClosedRange<Int>?,
                           fetcher: any MediaResourceFetching) async -> [MediaTrackInfo] {
        let limit = range.map { min($0.count, initSegmentLimit) } ?? initSegmentLimit
        guard let data = try? await fetcher.fetch(url, range: range, maxBytes: limit) else { return [] }
        return ISOInitSegment.tracks(in: data)
    }

    /// The frame rate of `track`, measured from the first fragment of the media segment at `url`.
    @concurrent
    static func frameRate(segmentURL url: URL, range: ClosedRange<Int>?, track: MediaTrackInfo,
                          fetcher: any MediaResourceFetching) async -> Double? {
        guard let timescale = track.timescale else { return nil }
        let start = range?.lowerBound ?? 0
        let end = min(range?.upperBound ?? Int.max, start + segmentHeadLength - 1)
        guard end >= start,
              let data = try? await fetcher.fetch(url, range: start...end, maxBytes: segmentHeadLength) else {
            return nil
        }
        return ISOFragment.frameRate(in: data, trackID: track.trackID, timescale: timescale,
                                     defaultDuration: track.defaultSampleDuration)
    }

    /// The init-segment tracks of an HLS media playlist. With `measureFrameRate`, the video track's frame rate is
    /// read from the first segment.
    @concurrent
    static func mediaPlaylistTracks(url: URL, fetcher: any MediaResourceFetching,
                                    measureFrameRate: Bool) async -> [MediaTrackInfo] {
        guard let data = try? await fetcher.fetch(url, range: 0...(playlistHeadLength - 1),
                                                  maxBytes: playlistHeadLength) else { return [] }
        guard let text = Self.completeLines(data) else { return [] }
        let references = HLSMediaPlaylistReferences(text: text, baseURL: url)
        guard let initURL = references.initURL else { return [] }
        var tracks = await initTracks(url: initURL, range: references.initRange, fetcher: fetcher)
        if measureFrameRate, let index = tracks.firstIndex(where: { $0.kind == .video }),
           let segmentURL = references.firstSegmentURL {
            tracks[index].frameRate = await frameRate(segmentURL: segmentURL, range: references.firstSegmentRange,
                                                      track: tracks[index], fetcher: fetcher)
        }
        return tracks
    }

    /// Text up to the last complete line of a possibly truncated UTF-8 playlist head.
    static func completeLines(_ data: Data) -> String? {
        if let text = String(bytes: data, encoding: .utf8) { return text }
        guard let newline = data.lastIndex(of: 0x0A) else { return nil }
        return String(bytes: data[..<newline], encoding: .utf8)
    }
}

/// Fetches an MPD, probes the selected Representations' init segments and translates it to HLS.
public nonisolated enum DASHPresentationLoader {
    /// Upper bound on Representations probed for one MPD.
    static let maxProbes = 16

    @concurrent
    public static func load(mpdURL: URL, fetcher: any MediaResourceFetching,
                            policy: DASHToHLSTranslator.VariantPolicy = .bestPerAdaptationSet) async throws
        -> HLSPresentation {
        let data = try await fetcher.fetch(mpdURL, range: nil, maxBytes: MediaProbe.manifestLimit)
        do {
            let manifest = try DASHManifest(data: data, manifestURL: mpdURL)
            let translator = DASHToHLSTranslator(manifest: manifest, policy: policy)
            let selection = try translator.selection()
            let probes = await probe(selection, fetcher: fetcher)
            return try translator.translate(selection: selection, probes: probes)
        } catch {
            throw PlaybackErrorMapping.playbackError(from: error)
        }
    }

    /// Init-segment facts by Representation ID.
    @concurrent
    static func probe(_ selection: DASHSelection,
                      fetcher: any MediaResourceFetching) async -> [String: MediaTrackInfo] {
        let representations = Array(selection.representationsToProbe.prefix(maxProbes))
        let periodDuration = selection.periodDuration
        return await withTaskGroup(of: (String, MediaTrackInfo?).self) { group in
            for rep in representations {
                group.addTask {
                    (rep.id, await probe(rep, periodDuration: periodDuration, fetcher: fetcher))
                }
            }
            var result: [String: MediaTrackInfo] = [:]
            for await (id, info) in group {
                result[id] = info
            }
            return result
        }
    }

    @concurrent
    private static func probe(_ rep: DASHRepresentation, periodDuration: Double?,
                              fetcher: any MediaResourceFetching) async -> MediaTrackInfo? {
        guard let initURL = try? rep.initializationURL() else { return nil }
        let tracks = await MediaProbe.initTracks(url: initURL, range: nil, fetcher: fetcher)
        guard var track = tracks.first(where: { $0.kind != .other }) else { return nil }
        if track.kind == .video, rep.frameRate == nil,
           let first = try? rep.segments(periodDuration: periodDuration).first {
            track.frameRate = await MediaProbe.frameRate(segmentURL: first.url, range: nil, track: track,
                                                         fetcher: fetcher)
        }
        return track
    }
}
