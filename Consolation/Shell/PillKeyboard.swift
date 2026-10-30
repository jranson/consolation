//
//  PillKeyboard.swift
//  Consolation
//
//  Mac: the pill as a keyboard target. Esc in Home's Etagere (or controller B in a pane) moves keyboard focus to the
//  pill; there ↑ and ↓ change the selection and → or Return move focus back into the pane. Only from that request until
//  focus leaves the pill is there anything to focus, so clicks, Tab and the pill's look stay as they were for anyone
//  not using the keyboard this way.
//

import SwiftUI

extension View {
    /// Makes the pill a keyboard target on the Mac when the shell asks (`ShellModel.focusPill()`). Nothing
    /// elsewhere: Apple TV, iPad and iPhone focus the pill's items themselves.
    func pillKeyboardFocus() -> some View {
        #if os(macOS)
        modifier(PillKeyboardFocus())
        #else
        self
        #endif
    }
}

#if os(macOS)
/// An invisible focus target behind the pill takes the keys, so the pill's own buttons keep their focus behavior
/// (Full Keyboard Access, clicks) exactly as before; it exists only while the pill is the keyboard target.
private struct PillKeyboardFocus: ViewModifier {
    @Environment(ShellModel.self) private var shell
    @Environment(\.layoutDirection) private var layoutDirection
    /// From the shell's request until focus leaves the pill.
    @State private var isTarget = false
    @FocusState private var isFocused: Bool

    func body(content: Content) -> some View {
        content
            .background {
                if isTarget {
                    Color.clear
                        .focusable()
                        .focused($isFocused)
                        .focusEffectDisabled()
                        .accessibilityHidden(true)
                        .onKeyPress(keys: [.upArrow, .downArrow, .leftArrow, .rightArrow, .return]) { press in
                            handle(press.key) ? .handled : .ignored
                        }
                        .task {
                            // Focus once the target is on screen; if focus didn't come, there is no target.
                            await Task.yield()
                            isFocused = true
                            try? await Task.sleep(for: .milliseconds(300))
                            if !Task.isCancelled, !isFocused { isTarget = false }
                        }
                }
            }
            .onChange(of: shell.pillFocusRequest) {
                if isTarget { isFocused = true } else { isTarget = true }
            }
            .onChange(of: isFocused) { _, focused in
                shell.pillHasFocus = focused
                if !focused { isTarget = false }
            }
    }

    /// ↑ and ↓ change the selection; → (← in right-to-left layouts) or Return enter the pane.
    private func handle(_ key: KeyEquivalent) -> Bool {
        let towardPane: KeyEquivalent = layoutDirection == .rightToLeft ? .leftArrow : .rightArrow
        switch key {
        case .upArrow: shell.selectAdjacentItem(by: -1)
        case .downArrow: shell.selectAdjacentItem(by: 1)
        case .return, towardPane: enterPane()
        default: return false
        }
        return true
    }

    private func enterPane() {
        isTarget = false
        shell.focusContent()
    }
}
#endif
