//
//  AppWindow.swift
//  Consolation
//
//  One window of the app. iPad, iPhone Duo (two windows can share its inner display) and the Mac can show several:
//  each has its own shell (sidebar selection, Zoom to Fill) over the app's shared models, and the one stream shows
//  in whichever window shows the player (`PlayerSession.videoWindow`).
//

import SwiftUI

struct AppWindow: View {
    /// The window group's identifier, for opening another window.
    static let groupID = "main"

    @Environment(PlayerSession.self) private var session
    /// The window's own pane, so a restored window (iPad, iPhone Duo) comes back where it was.
    @SceneStorage("shell.selection") private var savedSelection: String?
    @State private var shell: ShellModel
    /// The window's Home Etagere, alive as long as the window, so switching panes keeps Home where it was.
    @State private var homeEtagere: HomeEtagere
    let nowPlayingUpdate: () -> Void

    init(settings: PillSettings, homePositions: HomePositionStore, nowPlayingUpdate: @escaping () -> Void) {
        _shell = State(initialValue: ShellModel(settings: settings))
        _homeEtagere = State(initialValue: HomeEtagere(positions: homePositions))
        self.nowPlayingUpdate = nowPlayingUpdate
    }

    var body: some View {
        RootView(nowPlayingUpdate: nowPlayingUpdate)
            .debugLaunchActions()
            .environment(shell)
            .environment(homeEtagere)
            // Menu commands act on the window in front.
            .focusedSceneValue(shell)
            .onAppear {
                shell.restore(savedSelection)
                session.windowOpened(shell.id)
                #if DEBUG && !os(tvOS)
                DebugWindows.shells.append(shell)
                #endif
            }
            .onChange(of: shell.selection) { _, selection in savedSelection = selection.rawValue }
            .onDisappear {
                session.windowClosed(shell.id)
                #if DEBUG && !os(tvOS)
                DebugWindows.shells.removeAll { $0 === shell }
                #endif
            }
    }
}
