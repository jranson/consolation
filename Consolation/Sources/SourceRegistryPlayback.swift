//
//  SourceRegistryPlayback.swift
//  Consolation
//
//  "Go" on a Home card: a MediaItemID becomes what PlayerSession plays. Live channels play through the player's
//  relay-aware tuner path (EngineFactory), never through HDHomeRunSource.playback(for:), which would take a tuner
//  before tuner sharing could look for a relay. Quick Play items play their URL from the history, and library
//  items (a Bullpen recording or channel) their source's descriptor, mapped to an engine input.
//

import Foundation
import HTTPMPEG2Kit
import MediaSourceKit

/// What the player session plays for a card.
enum PlaybackTarget: Equatable {
    /// A live channel, and the channels channel up/down moves through (the lineup in guide order).
    case channel(LiveChannel, within: [LiveChannel])
    case url(URL)
    /// A library source's item (a recording, a movie, a server's channel), mapped to an engine input.
    case media(SourceMedia)
}

extension SourceRegistry {
    /// What to play for an item, or nil when no configured source has it any more. A channel resolves from the
    /// lineups already cached (no network); only when they don't list it are the lineup Source's other tuners read.
    /// - Parameter mark: the favorite mark for a channel key, given whether the device marks it.
    func playbackTarget(for id: MediaItemID,
                        mark: (String, Bool) -> FavoriteMark = { $1 ? .device : .none }) async -> PlaybackTarget? {
        if let channelKey = id.channelKey {
            let channels = await channels(of: channelKey.source, listing: channelKey.guideNumber, mark: mark)
            guard let channel = channels.first(where: { $0.key == channelKey.stringValue }) else { return nil }
            return .channel(channel, within: channels)
        }
        if let url = quickPlayURL(for: id) { return .url(url) }
        if let media = try? await libraryMedia(for: id) { return .media(media) }
        return nil
    }

    /// A library source's item, ready to play. Throws the source's error, or the mapper's when no engine plays it.
    func libraryMedia(for id: MediaItemID, start: StartPosition? = nil) async throws -> SourceMedia? {
        guard let source = librarySource(id.source) else { return nil }
        let item = try await source.item(id)
        let descriptor = try await source.playback(for: id, request: PlaybackRequest(start: start))
        let input = try PlaybackInputMapper.input(for: descriptor)
        return SourceMedia(item: id, title: item.title, subtitle: item.subtitle, isLive: descriptor.isLive,
                           input: input)
    }

    /// The URL behind a Quick Play item, from the history (the item itself never holds it).
    func quickPlayURL(for id: MediaItemID) -> URL? {
        guard id.source == quickPlay.id else { return nil }
        return history.entries.first { QuickPlaySource.itemKey(for: $0.url) == id.key }?.url
    }

    /// A lineup Source's channels across its tuners, each guide number once (named by the first tuner that lists
    /// it, with every tuner that lists it as a route), in guide order. Every cached lineup counts, whatever its age, and costs no request. The tuners with no cached
    /// lineup are read only when the cached ones don't list `guideNumber` (or with no `guideNumber`), all at once,
    /// so a tuner that doesn't answer delays "go" by one timeout at most, and never when another tuner has the
    /// channel.
    func channels(of lineupSource: String, listing guideNumber: String? = nil,
                  mark: (String, Bool) -> FavoriteMark) async -> [LiveChannel] {
        let configs = store.hdHomeRuns.filter { $0.lineupSourceName == lineupSource }
        var found: [Int: DeviceLineup] = [:]
        for (index, config) in configs.enumerated() {
            if let cached = await lineups.cachedLineup(host: config.host) { found[index] = cached }
        }
        let cached = Self.merge(found, lineupSource: lineupSource, mark: mark)
        let missing = configs.indices.filter { found[$0] == nil }
        if missing.isEmpty { return cached }
        if let guideNumber, cached.contains(where: { $0.guideNumber == guideNumber }) { return cached }
        let lineups = lineups
        let requests = missing.map { (index: $0, host: configs[$0].host, deviceID: configs[$0].tunerDeviceID) }
        let fetched = await withTaskGroup(of: (Int, DeviceLineup?).self) { group in
            for request in requests {
                group.addTask {
                    let lineup = try? await lineups.lineup(host: request.host, expecting: request.deviceID,
                                                           maxAge: nil, origin: .homeSource)
                    return (request.index, lineup)
                }
            }
            var results: [Int: DeviceLineup] = [:]
            for await (index, lineup) in group { results[index] = lineup }
            return results
        }
        found.merge(fetched) { old, _ in old }
        return Self.merge(found, lineupSource: lineupSource, mark: mark)
    }

    /// Lineups by their tuner's place in the configuration, merged in that order.
    private static func merge(_ lineups: [Int: DeviceLineup], lineupSource: String,
                              mark: (String, Bool) -> FavoriteMark) -> [LiveChannel] {
        let lists = lineups.keys.sorted().compactMap { index -> [LiveChannel]? in
            guard let lineup = lineups[index], (lineup.lineupSource ?? lineupSource) == lineupSource else { return nil }
            return LiveChannel.channels(from: lineup.channels, lineupSource: lineupSource,
                                        deviceID: lineup.discovery.deviceID,
                                        modelNumber: lineup.discovery.modelNumber, mark: mark)
        }
        return LiveChannel.merging(lists)
    }
}

extension PlayerSession {
    /// Plays a resolved card through the usual paths: channels as from the Live TV pane, URLs as from Quick Play.
    func play(_ target: PlaybackTarget) {
        switch target {
        case let .channel(channel, list): play(channel, within: list)
        case .url(let url): play(url)
        case .media(let media): play(media)
        }
    }
}
