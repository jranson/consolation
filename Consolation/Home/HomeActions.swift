//
//  HomeActions.swift
//  Consolation
//
//  What Home's "go" does: on a card, how the press ended; on an empty shelf's placeholder, which fitting action runs.
//  Pure, so the rules are tested without views.
//

import Foundation
import MediaSourceKit

/// How "go" on a Home card ended.
enum GoResult: Equatable {
    /// Playing, and the window opened the player.
    case opened
    /// Playing; the window had moved to another pane while the card resolved, so it stayed there.
    case playing
    /// A later "go", or playback started elsewhere, won meanwhile: this press did nothing.
    case superseded
    /// No configured source has the item now (its tuners didn't answer, or no longer list it).
    case unavailable
}

/// What "go" on an empty shelf's placeholder does.
enum EmptyShelfAction: Equatable {
    /// Settings at one of its sections: Settings › Sources when there is nothing to show from.
    case settings(SettingsSection)
    /// Another pane: the Live TV pane when a tuner is added but nothing is marked favorite yet, Quick Play for an
    /// empty history.
    case pane(ShellItem)
    /// The system's Local Network setting: without it the app can't reach its tuners.
    case localNetworkSettings

    /// The action for the shelf `shelfID` (a `HomeShelfKind.stableID`), from the live TV sources' state.
    static func forShelf(_ shelfID: String, hasLiveTVSource: Bool, liveTVStatus: SourceStatus) -> EmptyShelfAction {
        switch HomeShelfKind(stableID: shelfID) {
        case .favorites, .liveChannels:
            guard hasLiveTVSource else { return .settings(.sources) }
            return liveTVStatus == .localNetworkDenied ? .localNetworkSettings : .pane(.liveTV)
        case .quickPlayHistory:
            return .pane(.quickPlay)
        case .recordingNow, .recentRecordings, .continueWatching, .library, nil:
            // No DVR or library source yet (or it failed): they are set up in Settings › Sources.
            return .settings(.sources)
        }
    }
}
