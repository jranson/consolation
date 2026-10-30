//
//  MultiViewSessionTiles.swift
//  PlayerKit
//
//  Adding, replacing, retrying and removing tiles, Exit Multi-view, and the PiP snapshot and restore. Adding asks
//  the budget first, then the host's capacity provider; removing a tile stops its engine, which closes its stream
//  and frees its tuner at once.
//

import CoreGraphics
import PlaybackKit

public extension MultiViewSession {
    /// Whether `item` could be added (or, with `replacing`, put in that tile) now: the budget, then the host's
    /// capacity. The Add Tile picker uses this to grey out items with a reason, or to show a warning first.
    func admission(for item: Item, replacing: TileID? = nil) async -> TileAdmission {
        if replacing == nil, let reason = addTileLimitReason { return .denied(reason: reason) }
        let others = tiles.filter { $0.id != replacing }.map(\.item)
        guard let capacity else { return .allowed(cost: .cpuOnly, warning: nil) }
        return await capacity.admission(for: item, alongside: others)
    }

    /// Adds a tile for `item` and starts it: single → grid with the new tile focused (audio moves once it shows
    /// a picture and focus rests on it). With nothing playing, it plays alone.
    @discardableResult
    func add(_ item: Item) async throws(MultiViewError) -> TileID {
        guard state != nil else { return start(item) }
        try checkBudget()
        if case .denied(let reason) = await admission(for: item) { throw .unavailable(reason: reason) }
        // The check awaited: another tile may have been added meanwhile.
        try checkBudget()
        guard state != nil else { return start(item) }
        let id = TileID()
        let engine = makeEngine(item, id)
        engine.playsAudio = false
        tiles.append(PlayerTile(id: id, item: item, engine: engine, isUnavailable: isUnavailable))
        mutate { $0.add(id) }
        engine.start()
        return id
    }

    /// Plays `item` in `tile`'s place, keeping its position, focus and audio. The old engine stops first, so its
    /// tuner is free for the new one.
    func replace(_ tileID: TileID, with item: Item) async throws(MultiViewError) {
        guard tile(tileID) != nil else { throw .unknownTile }
        if case .denied(let reason) = await admission(for: item, replacing: tileID) {
            throw .unavailable(reason: reason)
        }
        guard let tile = tile(tileID) else { throw .unknownTile }
        restartEngine(of: tile, with: item)
    }

    /// Plays `item` in `tile`'s place now, without asking the capacity provider: a channel the user flipped to in
    /// that tile, for example. The old engine stops first. False for an unknown tile.
    @discardableResult
    func replaceNow(_ tileID: TileID, with item: Item) -> Bool {
        guard let tile = tile(tileID) else { return false }
        restartEngine(of: tile, with: item)
        return true
    }

    /// Stops every engine (freeing every stream and tuner) but keeps the tiles and their arrangement, so the player
    /// looks the same until `restartEngines()` (the app going to the background and back).
    func stopEngines() {
        cancelAudio(normalizing: false)
        for tile in tiles { tile.engine.stop() }
    }

    /// Starts every tile again with a new engine for its item.
    func restartEngines() {
        for tile in tiles { restartEngine(of: tile, with: tile.item) }
    }

    /// Starts `tile`'s item again with a new engine (the tile's Retry, for example after "Tuner unavailable").
    func retry(_ tileID: TileID) async throws(MultiViewError) {
        guard let item = tile(tileID)?.item else { throw .unknownTile }
        try await replace(tileID, with: item)
    }

    /// Removes `tile` and stops its engine. When one tile remains it fills the player. False for the last tile
    /// (stop the session instead) or an unknown one.
    @discardableResult
    func remove(_ tileID: TileID) -> Bool {
        guard tiles.count > 1, let tile = tile(tileID) else { return false }
        tile.engine.stop()
        tiles.removeAll { $0.id == tileID }
        if soundingTile == tileID { soundingTile = nil }
        if audioTarget == tileID { cancelAudio(normalizing: false) }
        mutate { $0.remove(tileID) }
        return true
    }

    /// Exit Multi-view: keeps `keeping` (default: the foreground or focused tile), which fills the player, and stops
    /// every other engine, freeing their tuners. Returns the kept tile.
    @discardableResult
    func exitMultiView(keeping: TileID? = nil) -> TileID? {
        guard var newState = state else { return nil }
        let removed = Set(newState.exitMultiView(keeping: keeping))
        for tile in tiles where removed.contains(tile.id) { tile.engine.stop() }
        tiles.removeAll { removed.contains($0.id) }
        if let sounding = soundingTile, removed.contains(sounding) { soundingTile = nil }
        if let target = audioTarget, removed.contains(target) { cancelAudio(normalizing: false) }
        state = newState
        stateChanged()
        return newState.focusedTile
    }

    /// The items and arrangement, for "Restore Multi-view" after Picture in Picture.
    func snapshot() -> MultiViewSnapshot<Item>? {
        guard let state else { return nil }
        return MultiViewSnapshot(items: tiles.map(\.item), focusedIndex: state.index(of: state.focusedTile) ?? 0,
                                 wasForeground: state.mode.foregroundTile != nil)
    }

    /// Re-adds the snapshot's items around the tiles still playing (matching items are reused, not restarted), puts
    /// them back in order and restores focus. Returns the items that could not be added, with the reason.
    @discardableResult
    func restore(_ snapshot: MultiViewSnapshot<Item>) async -> [(item: Item, error: MultiViewError)] {
        var available = tiles
        var placed: [TileID?] = []
        var failures: [(item: Item, error: MultiViewError)] = []
        for item in snapshot.items {
            if let index = available.firstIndex(where: { $0.item == item }) {
                placed.append(available.remove(at: index).id)
                continue
            }
            do {
                placed.append(try await add(item))
            } catch {
                placed.append(nil)
                failures.append((item, error))
            }
        }
        let leftovers = available.map(\.id).filter { id in tiles.contains { $0.id == id } }
        let order = placed.compactMap { $0 }.filter { id in tiles.contains { $0.id == id } } + leftovers
        mutate { $0.reorder(order) }
        tiles = orderedTiles()
        let focused = snapshot.items.indices.contains(snapshot.focusedIndex) ? placed[snapshot.focusedIndex] : nil
        if let focused, tiles.count > 1 {
            mutate { $0.show(snapshot.wasForeground ? .foreground(focused) : .grid(focused: focused)) }
        }
        return failures
    }
}

extension MultiViewSession {
    func checkBudget() throws(MultiViewError) {
        let limit = budget.limit(containerWidth: containerSize.width)
        guard tiles.count < limit else { throw .tileLimit(limit) }
    }

    /// Swaps in a new engine for `tile`. It inherits the tile's role and, if the tile was sounding, the audio.
    func restartEngine(of tile: PlayerTile<Item>, with item: Item) {
        tile.engine.stop()
        let engine = makeEngine(item, tile.id)
        let sounds = soundingTile == tile.id
        if audioTarget == tile.id { cancelAudio(normalizing: false) }
        engine.playsAudio = sounds
        if sounds { engine.volume = 1 }
        tile.item = item
        tile.engine = engine
        applyRoles()
        engine.start()
        syncAudio()
    }
}
