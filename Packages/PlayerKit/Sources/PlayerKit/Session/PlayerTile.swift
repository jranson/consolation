//
//  PlayerTile.swift
//  PlayerKit
//
//  One tile: what it plays and the engine playing it. Replacing the item swaps the engine but keeps the tile (and
//  its view), so the grid never rebuilds.
//

import Observation
import PlaybackKit

/// What a tile shows over its video, derived from the engine.
nonisolated public enum TileStatus: Equatable, Sendable {
    case starting
    case buffering
    case playing
    case paused
    case ended
    /// The source has no capacity for it right now (for example every tuner is in use); offer Retry.
    case unavailable(PlaybackError)
    case failed(PlaybackError)
}

@Observable
public final class PlayerTile<Item: Hashable & Sendable>: Identifiable {
    public let id: TileID
    public internal(set) var item: Item
    public internal(set) var engine: any PlaybackEngine
    @ObservationIgnored let isUnavailable: (PlaybackError) -> Bool

    init(id: TileID, item: Item, engine: any PlaybackEngine, isUnavailable: @escaping (PlaybackError) -> Bool) {
        self.id = id
        self.item = item
        self.engine = engine
        self.isUnavailable = isUnavailable
    }

    /// The engine's state for the tile's overlay ("Tuner unavailable" with Retry, failures, buffering).
    public var status: TileStatus {
        switch engine.state {
        case .idle, .connecting: .starting
        case .buffering: .buffering
        case .playing: .playing
        case .paused: .paused
        case .ended: .ended
        case .failed(let error):
            if isUnavailable(error) { .unavailable(error) } else { .failed(error) }
        }
    }

    /// Whether the engine has shown pictures (audio waits for this before moving to a new tile).
    var isShowingVideo: Bool {
        switch engine.state {
        case .playing, .paused: true
        default: false
        }
    }

    /// Whether the engine will never show a picture without a retry.
    var hasStopped: Bool {
        switch engine.state {
        case .failed, .ended: true
        default: false
        }
    }
}

/// Times for "Audio follows focus". Injectable, so tests run without waiting.
nonisolated public struct AudioFocusTiming: Sendable {
    /// How long focus must rest on a grid tile before its audio plays.
    public var dwell: Duration
    /// The crossfade from the old tile to the new one.
    public var crossfade: Duration
    /// Volume steps in the crossfade.
    public var crossfadeSteps: Int
    /// How long to wait for a new tile's first picture before giving up on moving audio to it.
    public var firstFrameTimeout: Duration
    /// How often to check for that first picture.
    public var firstFramePoll: Duration
    /// Sleeps; throws when the task is cancelled.
    public var sleep: @Sendable (Duration) async throws -> Void

    public init(dwell: Duration = .milliseconds(400), crossfade: Duration = .milliseconds(150),
                crossfadeSteps: Int = 10, firstFrameTimeout: Duration = .seconds(15),
                firstFramePoll: Duration = .milliseconds(100),
                sleep: @escaping @Sendable (Duration) async throws -> Void = { try await Task.sleep(for: $0) }) {
        self.dwell = dwell
        self.crossfade = crossfade
        self.crossfadeSteps = max(crossfadeSteps, 1)
        self.firstFrameTimeout = firstFrameTimeout
        self.firstFramePoll = firstFramePoll
        self.sleep = sleep
    }

    public static let standard = AudioFocusTiming()
}

/// The tiles' items and arrangement, for the app's PiP "Restore Multi-view".
nonisolated public struct MultiViewSnapshot<Item: Hashable & Sendable>: Hashable, Sendable {
    /// Items in grid order.
    public var items: [Item]
    /// The focused (grid) or front (foreground) tile's index.
    public var focusedIndex: Int
    /// Whether that tile was in front.
    public var wasForeground: Bool

    public init(items: [Item], focusedIndex: Int, wasForeground: Bool) {
        self.items = items
        self.focusedIndex = focusedIndex
        self.wasForeground = wasForeground
    }
}
