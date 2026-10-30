//
//  MultiViewPanels.swift
//  Consolation
//
//  The player's multi-view panels: PlayerKit's arrangement panel (long press, right-click, ⇧⌘A or the controls'
//  Arrange button), the Add Tile / Replace picker, and the short notice when a tile can't be added.
//

import PlayerKit
import SwiftUI

struct MultiViewPanels: View {
    @Environment(PlayerSession.self) private var session
    @Environment(PlaybackPreferences.self) private var preferences

    var body: some View {
        @Bindable var session = session
        @Bindable var prefs = preferences
        ZStack {
            if session.multiView.overlays.last == .arrangement {
                Color.black.opacity(0.35)
                    .ignoresSafeArea()
                    .onTapGesture { session.multiView.dismiss(.arrangement) }
                ArrangementPanel(session: session.multiView, audioFollowsFocus: $prefs.audioFollowsFocus,
                                 actions: actions) { $0.item.title }
                    .frame(maxWidth: 720)
                    .padding(40)
                    #if os(tvOS)
                    .focusSection()
                    #endif
                    .transition(.opacity.combined(with: .scale(scale: 0.96)))
            }
        }
        .animation(.smooth(duration: 0.25), value: session.multiView.overlays)
        .sheet(item: $session.tilePicker) { request in
            TilePickerView(request: request)
        }
    }

    private var actions: ArrangementActions {
        ArrangementActions(
            addTile: { session.tilePicker = .add },
            replace: { session.tilePicker = .replace($0) },
            exitMultiView: { tile in
                session.multiView.dismiss(.arrangement)
                session.exitMultiView(keeping: tile)
            }
        )
    }
}

/// A short message over the top of the player.
struct PlayerNotice: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.circle")
            .font(.callout.weight(.semibold))
            .padding(.horizontal, 16)
            .padding(.vertical, 10)
            .glassEffect(.regular, in: .capsule)
            .padding(.top, 28)
            .allowsHitTesting(false)
            .accessibilityIdentifier("player.notice")
    }
}
