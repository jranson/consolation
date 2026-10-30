//
//  BackInput.swift
//  Consolation
//
//  "Back" from a hardware keyboard's Esc (iPad and iPhone) and a game controller's B (iPad, iPhone and Mac). iOS
//  has no `onExitCommand`, so Esc is a key command that works whatever has focus; the player keeps its own Esc
//  handling while it has focus. B comes from the app's one set of controller handlers (GameControllers), which
//  calls the active window's action when Home's Etagere didn't take the press. Apple TV's remote and controllers go
//  through `onExitCommand` instead.
//

import SwiftUI

extension View {
    /// Calls `action` for Esc (iPad and iPhone, when `handlesEscape`) and, while `window` is the active window, for
    /// a game controller's B that no Etagere took. Nothing on Apple TV.
    func backInput(window: UUID, handlesEscape: Bool, action: @escaping () -> Void) -> some View {
        #if os(tvOS)
        self
        #else
        modifier(BackInputModifier(window: window, handlesEscape: handlesEscape, action: action))
        #endif
    }
}

#if !os(tvOS)
private struct BackInputModifier: ViewModifier {
    let window: UUID
    let handlesEscape: Bool
    let action: () -> Void
    @Environment(GameControllers.self) private var controllers
    @Environment(\.appearsActive) private var appearsActive

    func body(content: Content) -> some View {
        content
            #if os(iOS)
            .background {
                if handlesEscape {
                    // A key command needs a control to hang on; this one is invisible and never focusable.
                    Button("Back", action: action)
                        .keyboardShortcut(.escape, modifiers: [])
                        .opacity(0)
                        .frame(width: 0, height: 0)
                        .accessibilityHidden(true)
                }
            }
            #endif
            .onChange(of: appearsActive, initial: true) { _, active in
                if active {
                    controllers.setBackAction(for: window, action)
                } else {
                    controllers.clearBackAction(for: window)
                }
            }
            .onDisappear { controllers.clearBackAction(for: window) }
    }
}
#endif
