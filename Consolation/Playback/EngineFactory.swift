//
//  EngineFactory.swift
//  Consolation
//
//  Chooses the engine for what the user wants to play. HDHomeRun and other raw MPEG-TS never go to AVPlayer.
//

import Foundation
import HTTPMPEG2Kit
import MediaSourceKit
import PlaybackKit
import PlayerKit

struct EngineFactory {
    let preferences: PlaybackPreferences
    /// Owns every tuner connection. Channels play through a broker subscription, so the engine never sees a URL.
    let broker: TunerBroker

    /// About 19.4 Mbps, the most an ATSC 1.0 channel carries, to size a time-based buffer.
    static let liveBytesPerMinute = 19_400_000 / 8 * 60
    /// Memory buffers stay small, whatever the setting.
    static let maxMemoryBuffer = 512 << 20

    /// - Parameters:
    ///   - tile: the multi-view tile the engine plays in; each tile has its own tuner subscription.
    ///   - isAdded: a tile added to multi-view, which must leave the reserved tuners free.
    func makeEngine(for item: PlayingItem, tile: TileID? = nil, isAdded: Bool = false) -> any PlaybackEngine {
        switch item {
        case .channel(let channel):
            // Called again for every reconnect; each source subscribes anew and the broker replaces the old
            // stream. The tuner path is MediaSourceKit's subscription adapter; a channel never goes through
            // `HDHomeRunSource.playback(for:)`.
            let broker = broker
            let request = Self.tuneRequest(for: channel, purpose: isAdded ? .tile : .watch)
            // The first tile is the player; each added tile has its own slot, so one tile's reconnect or flip
            // closes only its own stream before opening the next.
            let slot: SubscriberSlot = isAdded ? tile.map { .tile($0.rawValue) } ?? .player : .player
            return TransportStreamEngine(makeSource: {
                ChannelSubscriptionByteSource(broker: broker, request: request, slot: slot)
            }, timeShift: isAdded ? Self.tileTimeShift(timeShift) : timeShift)
        case .url(let url):
            return makeEngine(for: url)
        case .media(let media):
            let shift = isAdded ? Self.tileTimeShift(timeShift) : timeShift
            return media.input.makeEngine(timeShift: shift)
        }
    }

    /// The broker request for a lineup channel: its `ChannelKey` and every device that carries it, in configuration
    /// order (the broker fails over through them).
    static func tuneRequest(for channel: LiveChannel, purpose: TunePurpose = .watch) -> TuneRequest {
        let key = ChannelKey(stringValue: channel.key)
            ?? ChannelKey(source: "Antenna", guideNumber: channel.guideNumber)
        let routes = channel.routes.isEmpty ? [DeviceChannelRef(url: channel.streamURL)] : channel.routes
        return TuneRequest(channel: key, routes: routes, purpose: purpose)
    }

    private func makeEngine(for url: URL) -> any PlaybackEngine {
        let kind = URLKindDetector.detect(url)
        if kind == .transportStream {
            let needsRawClient = RawHTTPByteSource.isNeeded(for: url)
            return TransportStreamEngine(makeSource: { () -> any ByteSource in
                needsRawClient ? RawHTTPByteSource(url: url) : HTTPByteSource(url: url)
            }, timeShift: timeShift)
        }
        return AVPlayerEngine(url: url, kind: kind.avPlayerInputKind ?? .file)
    }

    /// Added multi-view tiles keep a smaller buffer (each tile has its own), at most 1 GB.
    static let tileBufferLimit = 1 << 30

    static func tileTimeShift(_ configuration: TimeShiftConfiguration) -> TimeShiftConfiguration {
        var tile = configuration
        tile.capacityBytes = min(configuration.capacityBytes, tileBufferLimit)
        return tile
    }

    private var timeShift: TimeShiftConfiguration {
        let bytes: Int
        switch preferences.bufferLimit {
        case .time: bytes = preferences.bufferMinutes * Self.liveBytesPerMinute
        case .size: bytes = preferences.bufferMegabytes << 20
        }
        switch preferences.bufferStorage {
        case .disk: return TimeShiftConfiguration(storage: .temporaryFile, capacityBytes: bytes)
        case .memory: return TimeShiftConfiguration(storage: .memory, capacityBytes: min(bytes, Self.maxMemoryBuffer))
        }
    }
}
