//
//  TileRoles.swift
//  PlayerKit
//
//  Each tile's decode tier and audio from the state. Tiles behind the foreground run I+P.
//

import PlaybackKit

/// How one tile's engine should run.
nonisolated public struct TileRole: Hashable, Sendable {
    public var tier: DecodeTier
    public var playsAudio: Bool

    public init(tier: DecodeTier, playsAudio: Bool) {
        self.tier = tier
        self.playsAudio = playsAudio
    }
}

nonisolated public enum TileRoles {
    /// Roles for every tile.
    /// - Single or foreground tile: every picture at field rate, with audio.
    /// - Visible grid tiles: every picture with the cheap bob deinterlace; only the audible one has sound.
    /// - Tiles behind the foreground: I and P pictures only, silent.
    /// - Mini or hidden player: only the audible tile decodes; the others are suspended (still reading, so their
    ///   streams and tuners stay healthy).
    /// - When the system prefers reduced resource use, every tile but the primary (audible) one drops one step.
    public static func assign(state: MultiViewState, presentation: PlayerPresentation, audioFollowsFocus: Bool,
                              reducedResources: Bool = false) -> [TileID: TileRole] {
        let audible = state.audibleTile(followsFocus: audioFollowsFocus)
        var roles: [TileID: TileRole] = [:]
        for tile in state.tiles {
            let isAudible = tile == audible
            var tier = tier(for: tile, state: state, presentation: presentation, isAudible: isAudible)
            if reducedResources, !isAudible { tier = degraded(tier) }
            roles[tile] = TileRole(tier: tier, playsAudio: isAudible)
        }
        return roles
    }

    /// One step cheaper: field rate → frame rate (bob) → I+P → I only → suspended.
    public static func degraded(_ tier: DecodeTier) -> DecodeTier {
        switch tier {
        case .full(fieldRate: true): .full(fieldRate: false)
        case .full(fieldRate: false): .reduced
        case .reduced: .keyframesOnly
        case .keyframesOnly, .suspended: .suspended
        }
    }

    private static func tier(for tile: TileID, state: MultiViewState, presentation: PlayerPresentation,
                             isAudible: Bool) -> DecodeTier {
        if presentation != .full {
            return isAudible ? .full(fieldRate: true) : .suspended
        }
        switch state.mode {
        case .single:
            return .full(fieldRate: true)
        case .grid:
            return .full(fieldRate: false)
        case .foreground(let front):
            return tile == front ? .full(fieldRate: true) : .reduced
        }
    }
}
