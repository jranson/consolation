//
//  ShellCommands.swift
//  Consolation
//
//  Menus for the pill's panes and the player, so every shortcut is discoverable: the menu bar on macOS, the
//  hardware keyboard's ⌘ overlay on iPad.
//

#if !os(tvOS)
import PlayerKit
import SwiftUI

struct ShellCommands: Commands {
    /// The shell of the window in front; nil with no window.
    @FocusedValue(ShellModel.self) private var shell
    let session: PlayerSession

    var body: some Commands {
        CommandGroup(replacing: .appSettings) {
            Button("Settings…") { shell?.selection = .settings }
                .keyboardShortcut(",", modifiers: .command)
                .disabled(shell == nil)
        }
        CommandGroup(after: .newItem) {
            Button("Open Location…") { shell?.selection = .quickPlay }
                .keyboardShortcut("l", modifiers: .command)
                .disabled(shell == nil)
        }
        CommandMenu("Go") {
            ForEach(ShellItem.availableCases.filter { $0 != .settings }) { item in
                if let key = item.shortcutKey {
                    Button { shell?.selection = item } label: { Text(item.title) }
                        .keyboardShortcut(key, modifiers: .command)
                        .disabled(shell?.hiddenItems.contains(item) ?? true)
                }
            }
        }
        CommandMenu("Playback") {
            Button("Play/Pause") { session.togglePause() }
                .disabled(!session.isActive)
            Button("Channel Up") { session.channelUp() }
                .keyboardShortcut(.upArrow, modifiers: .command)
                .disabled(session.currentChannel == nil)
            Button("Channel Down") { session.channelDown() }
                .keyboardShortcut(.downArrow, modifiers: .command)
                .disabled(session.currentChannel == nil)
            Button("Previous Channel") { session.playPreviousChannel() }
                .disabled(session.previousChannel == nil)
            Divider()
            Button("Add to Multi-view…") {
                shell?.selection = .nowPlaying
                session.tilePicker = .add
            }
            .keyboardShortcut("n", modifiers: [.command, .shift])
            .disabled(!session.isActive || shell == nil)
            Button("Arrange Multi-view…") {
                shell?.selection = .nowPlaying
                session.multiView.present(.arrangement)
            }
            .keyboardShortcut("a", modifiers: [.command, .shift])
            .disabled(!session.isMultiView || shell == nil)
            Button("Exit Multi-view") { session.exitMultiView() }
                .keyboardShortcut("m", modifiers: [.command, .shift])
                .disabled(!session.isMultiView)
            if session.multiViewSnapshot != nil {
                Button("Restore Multi-view") { session.restoreMultiView() }
                    .disabled(session.isMultiView)
            }
            Divider()
            Button("Stop") { session.stop() }
                .keyboardShortcut(".", modifiers: .command)
                .disabled(!session.isActive)
        }
    }
}
#endif
