//
//  CaptureCardPane.swift
//  Consolation
//
//  The Capture Card pane: today's capture viewer (`ContentView`), unchanged, inside the shell. The pill is part of
//  the viewer's auto-hiding chrome while video runs. Capture and the player never play at once: starting capture
//  stops the player, and playing something stops capture. Capture stops once no window shows this pane.
//

#if !os(tvOS)
import SwiftUI

struct CaptureCardPane: View {
    @Environment(CaptureSessionManager.self) private var capture
    @Environment(PlayerSession.self) private var session

    /// Windows showing this pane now (Mac and iPad can show it in several).
    private static var visibleCount = 0

    var body: some View {
        ContentView(capture: capture)
            .onAppear { Self.visibleCount += 1 }
            .onDisappear {
                Self.visibleCount = max(Self.visibleCount - 1, 0)
                if Self.visibleCount == 0, capture.state == .running { capture.stopWatching() }
            }
            .onChange(of: capture.state) { _, state in
                if state == .running, session.isActive { session.stop() }
            }
            .onChange(of: session.isActive) { _, isActive in
                if isActive, capture.state == .running { capture.stopWatching() }
            }
    }
}

/// The viewer's chrome (controls and pill) is hidden while video runs and the pointer rests.
struct CaptureChromeHiddenKey: PreferenceKey {
    static let defaultValue = false

    static func reduce(value: inout Bool, nextValue: () -> Bool) {
        value = value || nextValue()
    }
}
#endif
