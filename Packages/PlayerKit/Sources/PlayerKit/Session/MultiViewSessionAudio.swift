//
//  MultiViewSessionAudio.swift
//  PlayerKit
//
//  Which engine plays audio. Exactly one tile sounds at a time. In the grid, with "Audio follows focus" on, audio moves
//  to the focused tile after a 400 ms dwell (another move restarts it), and only once that tile shows its first
//  picture; every move is a 150 ms crossfade of the engines' volumes (old 1 → 0, new 0 → 1). Silent tiles skip audio
//  decoding (`playsAudio` false).
//

import PlaybackKit

extension MultiViewSession {
    /// Starts, keeps or cancels the audio move the state asks for.
    func syncAudio() {
        guard let state else {
            cancelAudio(normalizing: false)
            return
        }
        if let sounding = soundingTile, tile(sounding) == nil { soundingTile = nil }
        var target = state.audibleTile(followsFocus: audioFollowsFocus)
        var dwell: Duration?
        if case .grid(let focused) = state.mode, audioFollowsFocus, focused != target {
            target = focused
            dwell = timing.dwell
        }
        if target == audioTarget { return }
        cancelAudio(normalizing: true)
        guard target != soundingTile else { return }
        moveAudio(to: target, after: dwell)
    }

    /// Stops a pending or running audio move. Normalizing puts the sounding tile back at full volume and silences
    /// the rest.
    func cancelAudio(normalizing: Bool) {
        audioTask?.cancel()
        audioTask = nil
        audioTarget = nil
        audioGeneration &+= 1
        if normalizing { normalizeAudio() }
    }

    /// The sounding tile plays at full volume; every other tile is silent.
    func normalizeAudio() {
        for tile in tiles {
            let engine = tile.engine
            if tile.id == soundingTile {
                if engine.volume != 1 { engine.volume = 1 }
                if !engine.playsAudio { engine.playsAudio = true }
            } else if engine.playsAudio {
                engine.playsAudio = false
            }
        }
    }

    private func moveAudio(to target: TileID, after dwell: Duration?) {
        audioTarget = target
        audioGeneration &+= 1
        let generation = audioGeneration
        let timing = timing
        audioTask = Task { [weak self] in
            do {
                if let dwell { try await timing.sleep(dwell) }
                try await self?.waitForFirstFrame(of: target, generation: generation)
                try await self?.crossfade(to: target, committingFocus: dwell != nil, generation: generation)
            } catch {
                // Cancelled (whoever cancelled settled the audio) or the tile never showed a picture.
                self?.audioMoveFailed(generation: generation)
            }
        }
    }

    /// Throws when a newer move or a cancel replaced this one.
    private func checkCurrent(_ generation: Int) throws {
        if Task.isCancelled || generation != audioGeneration { throw CancellationError() }
    }

    private func audioMoveFailed(generation: Int) {
        guard generation == audioGeneration, audioTarget != nil else { return }
        audioTask = nil
        audioTarget = nil
        normalizeAudio()
    }

    /// Waits until the tile shows a picture (audio stays on the old tile meanwhile). Throws if it stops first or
    /// takes longer than the timeout.
    private func waitForFirstFrame(of target: TileID, generation: Int) async throws {
        var waited = Duration.zero
        try checkCurrent(generation)
        while let tile = tile(target), !tile.isShowingVideo {
            try checkCurrent(generation)
            guard !tile.hasStopped, waited < timing.firstFrameTimeout else { throw CancellationError() }
            try await timing.sleep(timing.firstFramePoll)
            waited += timing.firstFramePoll
        }
        guard tile(target) != nil else { throw CancellationError() }
    }

    private func crossfade(to target: TileID, committingFocus: Bool, generation: Int) async throws {
        try checkCurrent(generation)
        guard let newEngine = tile(target)?.engine else { throw CancellationError() }
        if committingFocus {
            // Audio followed focus: from now on the grid's audible tile is this one.
            var newState = state
            newState?.commitAudioFocus(target)
            if let newState, newState != state { state = newState }
        }
        let oldEngine = soundingTile.flatMap { tile($0)?.engine }
        for tile in tiles where tile.id != target && tile.id != soundingTile && tile.engine.playsAudio {
            tile.engine.playsAudio = false
        }
        newEngine.volume = oldEngine == nil ? 1 : 0
        newEngine.playsAudio = true
        if oldEngine != nil {
            let steps = timing.crossfadeSteps
            for step in 1...steps {
                try await timing.sleep(timing.crossfade / steps)
                try checkCurrent(generation)
                let level = Float(step) / Float(steps)
                oldEngine?.volume = 1 - level
                newEngine.volume = level
            }
        }
        oldEngine?.playsAudio = false
        soundingTile = target
        audioTarget = nil
        audioTask = nil
        applyRoles()
    }

    /// Waits for the pending audio move (tests).
    func settleAudio() async {
        while let task = audioTask {
            await task.value
            if audioTask == task { break }
        }
    }
}
