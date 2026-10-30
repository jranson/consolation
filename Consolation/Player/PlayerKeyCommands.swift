//
//  PlayerKeyCommands.swift
//  Consolation
//
//  Keyboard and remote input for the player. Keeps Consolation's keys (Space/K, M, Esc) and adds channel keys.
//

import PlaybackKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

extension View {
    /// Space/K play-pause, ↑/↓ channel up/down, "-" previous channel, M mute, Esc back. On tvOS: the remote's
    /// Play/Pause, up/down and Back (Menu) buttons.
    /// `onSelect`: the remote's Select on Apple TV (it shows the controls there).
    /// `isEnabled` false: the player takes no focus or keys (multi-view's tiles have them).
    func playerKeyCommands(session: PlayerSession, isEnabled: Bool = true, onBack: @escaping () -> Void,
                           onSelect: @escaping () -> Void = {}) -> some View {
        modifier(PlayerKeyCommandsModifier(session: session, isEnabled: isEnabled, onBack: onBack, onSelect: onSelect))
    }
}

private struct PlayerKeyCommandsModifier: ViewModifier {
    let session: PlayerSession
    let isEnabled: Bool
    let onBack: () -> Void
    let onSelect: () -> Void

    func body(content: Content) -> some View {
        #if os(tvOS)
        // Always the same button, only disabled (in multi-view, and while focus is in the controls): rebuilding the
        // chrome without it made the error card's Retry focusable for a moment, and focus looped between them.
        remoteButton(content)
            .disabled(!isEnabled)
        #else
        keyboard(content)
        #endif
    }

    #if os(tvOS)
    private func remoteButton(_ content: Content) -> some View {
        // A button, so Select arrives as its primary action (a tap gesture on a focusable view misses clicks on a
        // real Siri Remote).
        Button(action: onSelect) { content }
            .buttonStyle(PlayerSurfaceButtonStyle())
            .focusEffectDisabled()
            .accessibilityIdentifier("player.video")
            .onPlayPauseCommand { session.playPauseFromRemote() }
            .onMoveCommand { direction in
                switch direction {
                case .up: session.channelUp()
                case .down: session.channelDown()
                default: session.showControlsBriefly()
                }
            }
            .onExitCommand(perform: onBack)
    }
    #else
    private func keyboard(_ content: Content) -> some View {
        content
            .focusable(isEnabled)
            .focusEffectDisabled()
            .onKeyPress(keys: [.space, "k"]) { _ in
                session.togglePause()
                return .handled
            }
            .onKeyPress(.upArrow) {
                session.channelUp()
                return .handled
            }
            .onKeyPress(.downArrow) {
                session.channelDown()
                return .handled
            }
            .onKeyPress("-") {
                session.playPreviousChannel()
                return .handled
            }
            .onKeyPress("m") {
                session.engine?.isMuted.toggle()
                session.showControlsBriefly()
                return .handled
            }
            .onKeyPress(.escape) {
                onBack()
                return .handled
            }
            .onKeyPress(characters: CharacterSet(charactersIn: "0123456789.")) { press in
                guard let character = press.characters.first else { return .ignored }
                session.enterDigit(character)
                return .handled
            }
            .onKeyPress(.return) {
                guard !session.enteredDigits.isEmpty else { return .ignored }
                session.commitDigits()
                return .handled
            }
            .onKeyPress("c") {
                session.toggleCaptions()
                return .handled
            }
            .onKeyPress("i") {
                session.statsVisible.toggle()
                return .handled
            }
            .onKeyPress(.leftArrow) {
                session.engine?.skip(by: PlayerControls.backStep)
                session.showControlsBriefly()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                session.engine?.skip(by: PlayerControls.forwardStep)
                session.showControlsBriefly()
                return .handled
            }
            #if os(macOS)
            .onKeyPress("f") {
                NSApp.keyWindow?.toggleFullScreen(nil)
                return .handled
            }
            #endif
    }
    #endif
}

#if os(tvOS)
/// The video as a remote focus target that draws nothing of its own.
private struct PlayerSurfaceButtonStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
    }
}
#endif
