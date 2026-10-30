//
//  RootViewTelevision.swift
//  Consolation
//
//  Apple TV's menu in the root view (TVShellMenu.swift draws it): when it is open, which item has focus, choosing an
//  item, and where focus starts at launch. Back in a pane opens the menu; Back in the open menu is left to the
//  system, which leaves the app.
//

import SwiftUI

extension RootView {
    /// Apple TV uses the collapsible menu instead of the pill.
    var isTelevisionMenu: Bool {
        #if os(tvOS)
        true
        #else
        false
        #endif
    }

    /// Apple TV: the menu is open (it has focus, or Back asked for it and it is appearing). The content takes no
    /// focus meanwhile. Always false elsewhere.
    var isMenuOpen: Bool {
        #if os(tvOS)
        !menuClosing && (pillFocus != nil || pillSummoned)
        #else
        false
        #endif
    }
}

#if os(tvOS)
extension RootView {
    /// The collapsed header in a pane (nothing in the player), or the open menu over the dimmed content.
    @ViewBuilder func televisionMenu(inPlayer: Bool) -> some View {
        ZStack(alignment: .topLeading) {
            if isMenuOpen {
                Color.black.opacity(0.45)
                    .ignoresSafeArea()
                    .allowsHitTesting(false)
                    .transition(.opacity)
                TVMenu(items: shell.visibleItems, selection: shell.selection,
                       badged: session.isActive ? [.nowPlaying] : [], focus: $pillFocus, onChoose: choose)
                    .padding(.leading, Self.tvPillInset)
                    .focusSection()
                    .onAppear {
                        Task { @MainActor in pillFocus = shell.selection }
                    }
                    // Appears with a fade, but leaves at once: see `menuClosing`.
                    .transition(.asymmetric(insertion: .opacity, removal: .identity))
            } else if !inPlayer {
                TVMenuHeader(selection: shell.selection)
                    .padding(.leading, Self.tvPillInset)
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .ignoresSafeArea(.container, edges: .leading)
        .animation(.smooth(duration: 0.25), value: isMenuOpen)
    }

    /// Select in the open menu: switch to `item` and close the menu, moving focus into the pane. A pane with nothing
    /// to focus keeps the menu open (focus has nowhere else to go).
    func choose(_ item: ShellItem) {
        withAnimation(.smooth(duration: 0.3)) { shell.selection = item }
        guard paneTakesFocus(item) else {
            pillFocus = item
            return
        }
        menuClosing = true
        pillSummoned = false
        pillFocus = nil
        Task { @MainActor in
            // The new pane takes focus once it is on screen.
            try? await Task.sleep(for: .milliseconds(150))
            shell.focusContent()
        }
    }

    /// Whether the pane for `item` has something that takes focus.
    func paneTakesFocus(_ item: ShellItem) -> Bool {
        switch item {
        // Apple TV has no Capture Card pane; it shows Home if ever selected.
        case .home, .quickPlay, .library, .settings, .captureCard: true
        case .liveTV: !liveTV.visibleChannels.isEmpty
        case .nowPlaying: session.isActive
        }
    }

    /// Opens the menu when the pane on screen has nothing to take focus and the menu isn't open.
    func openMenuIfStranded() {
        guard !isMenuOpen, !paneTakesFocus(shell.selection) else { return }
        shell.focusPill()
    }

    /// At launch focus goes into the restored pane, or into the menu when the pane has nothing to focus.
    func focusAtLaunch() async {
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled, !isMenuOpen else { return }
        if paneTakesFocus(shell.selection) {
            shell.focusContent()
        } else {
            shell.focusPill()
        }
    }
}
#endif
