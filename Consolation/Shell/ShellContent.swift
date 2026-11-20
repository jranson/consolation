//
//  ShellContent.swift
//  Consolation
//
//  What the panes have to show, which decides whether the menu lists them: Live TV needs a tuner, Library a library
//  server, and Now Playing something playing. App-wide, like the hidden items (`PillSettings`).
//

import Foundation

nonisolated struct ShellContent: Equatable, Sendable {
    /// Tuners added (Live TV).
    var tunerCount: Int
    /// Library servers added (Bullpen, Plex).
    var libraryCount: Int
    /// The player or YouTube's embed is playing something.
    var isPlaying: Bool

    /// Every pane has something: the default before the app's models are attached, and in tests.
    static let everything = ShellContent(tunerCount: 1, libraryCount: 1, isPlaying: true)

    /// Whether `item`'s pane has anything to show, so the menu lists it.
    func hasContent(_ item: ShellItem) -> Bool {
        switch item {
        case .liveTV: tunerCount > 0
        case .library: libraryCount > 0
        case .nowPlaying: isPlaying
        case .home, .quickPlay, .captureCard, .settings: true
        }
    }

    /// The item's name in the menu: Library is "Libraries" with more than one server.
    @MainActor func title(for item: ShellItem) -> LocalizedStringResource {
        item == .library && libraryCount > 1 ? "Libraries" : item.title
    }
}
