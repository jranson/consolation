//
//  MultiViewSession.swift
//  PlayerKit
//
//  The tiles of the player and their engines. Owns the state machine, creates engines through the host's factory,
//  checks the tile budget and the host's capacity before adding a tile, and after every change gives each engine its
//  role (decode tier and audio). Generic over the host's item type.
//

import CoreGraphics
import Observation
import PlaybackKit

@Observable
public final class MultiViewSession<Item: Hashable & Sendable> {
    /// Makes (but does not start) the engine for an item. The tile ID lets the host key per-tile resources (a tuner
    /// subscriber slot, for example).
    public typealias EngineFactory = (Item, TileID) -> any PlaybackEngine

    /// Tiles in grid order.
    public internal(set) var tiles: [PlayerTile<Item>] = []
    /// Nil while nothing plays.
    public internal(set) var state: MultiViewState?
    /// How big the player is; the mini and hidden player decode only the audible tile.
    public var presentation: PlayerPresentation = .full {
        didSet { if presentation != oldValue { stateChanged() } }
    }
    /// "Audio follows focus" (the host's setting). Off: grid audio stays on the last foreground tile.
    public var audioFollowsFocus: Bool {
        didSet { if audioFollowsFocus != oldValue { stateChanged() } }
    }
    /// The system asks apps to use fewer resources (OS 27; `MultiViewPlayer` reports it).
    public var prefersReducedResourceUsage = false {
        didSet { if prefersReducedResourceUsage != oldValue { applyRoles() } }
    }
    public var budget: TileBudget
    /// The player's size, reported by `MultiViewPlayer`; decides the grid shape and the compact cap.
    public var containerSize: CGSize = .zero
    /// Bumped by `requestFocus()`; `MultiViewPlayer` then moves focus to the focused (or front) tile.
    public private(set) var focusRequest = 0

    @ObservationIgnored let makeEngine: EngineFactory
    @ObservationIgnored let capacity: (any TileCapacityProviding<Item>)?
    @ObservationIgnored let timing: AudioFocusTiming
    @ObservationIgnored let isUnavailable: (PlaybackError) -> Bool
    /// The tile whose audio plays at full volume now.
    @ObservationIgnored var soundingTile: TileID?
    /// Where a pending audio move is going, and the task doing it.
    @ObservationIgnored var audioTarget: TileID?
    @ObservationIgnored var audioTask: Task<Void, Never>?
    /// Bumped by every audio move and cancel, so a superseded move never touches the engines.
    @ObservationIgnored var audioGeneration = 0

    /// - Parameters:
    ///   - capacity: the host's tuner (or other source) check; nil allows everything within the budget.
    ///   - isUnavailable: which engine failures mean "no capacity right now" (shown as unavailable with Retry).
    public init(budget: TileBudget = .platformDefault, audioFollowsFocus: Bool = true,
                capacity: (any TileCapacityProviding<Item>)? = nil, timing: AudioFocusTiming = .standard,
                isUnavailable: @escaping (PlaybackError) -> Bool = { _ in false },
                makeEngine: @escaping EngineFactory) {
        self.budget = budget
        self.audioFollowsFocus = audioFollowsFocus
        self.capacity = capacity
        self.timing = timing
        self.isUnavailable = isUnavailable
        self.makeEngine = makeEngine
    }

    // MARK: - Reading

    public var isEmpty: Bool { tiles.isEmpty }
    public var mode: MultiViewMode? { state?.mode }
    public var isMultiView: Bool { tiles.count > 1 }
    public var overlays: [PlayerOverlay] { state?.overlays ?? [] }

    public func tile(_ id: TileID) -> PlayerTile<Item>? {
        tiles.first { $0.id == id }
    }

    /// The tile whose audio plays (or is about to): the host's system Now Playing primary.
    public var audibleTile: TileID? { state?.audibleTile(followsFocus: audioFollowsFocus) }
    public var audibleEngine: (any PlaybackEngine)? { audibleTile.flatMap { tile($0)?.engine } }

    /// The grid shape for the current tiles and size.
    public var gridShape: GridShape {
        MultiViewGeometry.shape(count: tiles.count, container: containerSize)
    }

    /// Why no tile can be added now (the budget), or nil.
    public var addTileLimitReason: String? {
        let limit = budget.limit(containerWidth: containerSize.width)
        return tiles.count < limit ? nil : MultiViewError.tileLimit(limit).message
    }

    // MARK: - Starting and stopping

    /// Plays `item` alone, stopping anything that was playing.
    @discardableResult
    public func start(_ item: Item) -> TileID {
        stopAll()
        let id = TileID()
        let engine = makeEngine(item, id)
        adoptFirst(PlayerTile(id: id, item: item, engine: engine, isUnavailable: isUnavailable))
        engine.start()
        return id
    }

    /// Makes an engine that is already playing the first tile, without restarting it (the app's single stream
    /// becoming multi-view). Anything the session was playing stops.
    @discardableResult
    public func adopt(engine: any PlaybackEngine, item: Item) -> TileID {
        stopAll()
        let id = TileID()
        adoptFirst(PlayerTile(id: id, item: item, engine: engine, isUnavailable: isUnavailable))
        return id
    }

    private func adoptFirst(_ tile: PlayerTile<Item>) {
        tiles = [tile]
        state = MultiViewState(tile: tile.id)
        soundingTile = tile.id
        normalizeAudio()
        applyRoles()
    }

    /// Stops every engine (releasing every stream and tuner) and empties the session.
    public func stopAll() {
        cancelAudio(normalizing: false)
        for tile in tiles { tile.engine.stop() }
        tiles = []
        state = nil
        soundingTile = nil
    }

    // MARK: - Navigation

    /// A direction from the d-pad, swipe or keys (grid: focus; foreground: ← → cycle, ↑ back to the grid). False
    /// when nothing changed.
    @discardableResult
    public func focus(_ direction: TileDirection) -> Bool {
        let shape = gridShape
        return mutate { $0.move(direction, shape: shape) } ?? false
    }

    /// Grid: focuses `tile` (the tvOS focus engine moved there, or a click).
    @discardableResult
    public func focus(tile: TileID) -> Bool {
        mutate { $0.focus(tile) } ?? false
    }

    /// Click, Select, tap or Return: grid → foreground; foreground or single → controls (the host shows them).
    @discardableResult
    public func select(_ tile: TileID) -> SelectOutcome {
        mutate { $0.select(tile) } ?? .ignored
    }

    /// Foreground: the next or previous tile comes forward.
    @discardableResult
    public func cycleForeground(forward: Bool) -> Bool {
        mutate { $0.cycleForeground(forward: forward) } ?? false
    }

    /// Pops the innermost layer. False when nothing is left; the host then leaves the player.
    public func back() -> Bool {
        mutate { $0.back() } ?? false
    }

    /// Asks `MultiViewPlayer` to give focus to the session's focused (or front) tile, for example when the host's
    /// sidebar hands focus back to the player.
    public func requestFocus() {
        focusRequest += 1
    }

    public func present(_ overlay: PlayerOverlay) {
        mutate { $0.present(overlay) }
    }

    public func dismiss(_ overlay: PlayerOverlay) {
        mutate { $0.dismiss(overlay) }
    }

    /// Swaps `tile` with its neighbor in reading order (-1 left, +1 right).
    @discardableResult
    public func moveTile(_ tile: TileID, by offset: Int) -> Bool {
        let moved = mutate { $0.moveTile(tile, by: offset) } ?? false
        if moved { tiles = orderedTiles() }
        return moved
    }

    // MARK: - Internals

    /// Applies `change` to the state, then the roles and audio. Nil while nothing plays.
    @discardableResult
    func mutate<Result>(_ change: (inout MultiViewState) -> Result) -> Result? {
        guard var newState = state else { return nil }
        let result = change(&newState)
        if newState != state {
            state = newState
            stateChanged()
        }
        return result
    }

    /// The tiles in the state's order.
    func orderedTiles() -> [PlayerTile<Item>] {
        guard let state else { return tiles }
        return state.tiles.compactMap { id in tiles.first { $0.id == id } }
    }

    func stateChanged() {
        applyRoles()
        syncAudio()
    }

    /// Gives every engine its decode tier (audio is `syncAudio`'s job).
    func applyRoles() {
        guard let state else { return }
        let roles = TileRoles.assign(state: state, presentation: presentation, audioFollowsFocus: audioFollowsFocus,
                                     reducedResources: prefersReducedResourceUsage)
        for tile in tiles {
            guard let role = roles[tile.id], tile.engine.decodeTier != role.tier else { continue }
            tile.engine.setDecodeTier(role.tier)
        }
    }
}
