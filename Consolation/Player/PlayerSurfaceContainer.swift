//
//  PlayerSurfaceContainer.swift
//  Consolation
//
//  The one place the playing video is shown, one tile or several (PlayerKit's MultiViewPlayer). It never moves to
//  another view: it animates its frame between the full Now Playing area and the mini player in the lower right,
//  and the tiles animate inside it, so a video is never re-hosted (re-hosting during transitions left the player
//  black). A new channel just swaps the tile's engine display view inside the same surface.
//

import PlaybackKit
import PlayerKit
import SwiftUI

struct PlayerSurfaceContainer: View {
    @Environment(PlayerSession.self) private var session
    @Environment(ShellModel.self) private var shell
    @Environment(PlaybackPreferences.self) private var preferences

    /// True for the lower-right mini player, false for the full Now Playing area.
    let isMini: Bool

    static let miniSize = CGSize(width: 320, height: 180)
    static let miniInset: CGFloat = 20
    static let miniCornerRadius: CGFloat = 14

    var body: some View {
        GeometryReader { proxy in
            if !session.multiView.isEmpty, session.videoWindow == shell.id {
                let rect = frame(in: proxy.size)
                surface
                    .clipShape(.rect(cornerRadius: isMini ? Self.miniCornerRadius : 0))
                    .overlay {
                        if isMini {
                            RoundedRectangle(cornerRadius: Self.miniCornerRadius).strokeBorder(.white.opacity(0.18))
                            MiniPlayerChrome()
                        }
                    }
                    .frame(width: rect.width, height: rect.height)
                    .position(x: rect.midX, y: rect.midY)
                    // The full player's own chrome takes input for one stream; the tiles take it in multi-view.
                    .allowsHitTesting(isMini || session.isMultiView)
            } else if session.isActive, !isMini {
                PlayingElsewhere(fills: shell.fillsView, window: shell.id)
            }
        }
        .ignoresSafeArea()
        .animation(.smooth(duration: 0.35), value: isMini)
        // The first window to show the player or the mini player takes the video, and so does a window still open
        // when the one showing it closes.
        .onChange(of: session.isActive && session.videoWindow == nil, initial: true) { _, unclaimed in
            if unclaimed { session.showVideo(in: shell.id, fills: shell.fillsView) }
        }
        .onChange(of: preferences.audioFollowsFocus, initial: true) { _, follows in
            session.multiView.audioFollowsFocus = follows
        }
        .onChange(of: session.multiView.audibleTile) { session.audibleTileChanged() }
        // Select in the pill (Apple TV), → or Return (Mac): in multi-view focus goes to the session's tile.
        .onChange(of: shell.contentFocusRequest) {
            if session.isMultiView, !isMini { session.multiView.requestFocus() }
        }
    }

    /// Every tile's video in one view that never re-hosts them (PlayerKit), or, while the Mac's floating window has
    /// the video, a note with a way to bring it back.
    @ViewBuilder private var surface: some View {
        ZStack {
            MultiViewPlayer(session: session.multiView, isInputEnabled: tileInputEnabled, handlers: handlers,
                            onDisplayReady: { _, view in session.displayReady(view) },
                            tileOverlay: { tile, context in TileOverlayView(tile: tile, context: context) })
                .modifier(MultiViewPlayerKeys(session: session))
                #if os(tvOS)
                // The tiles are one focus section: the focus engine looks for the next tile among them first.
                .focusSection()
                #endif
            if session.isFloating {
                Color.black
                VStack(spacing: 8) {
                    Image(systemName: "pip").font(.system(size: isMini ? 22 : 40))
                    if !isMini { Text("Playing in Picture in Picture").font(.headline) }
                    Button(isMini ? "Back" : "Bring Back") { session.isFloating = false }
                }
                .foregroundStyle(.white.opacity(0.8))
            }
        }
    }

    /// The tiles take input unless the controls, a panel or the number pad has it, or (Mac and iPad keyboards) the
    /// pill. On Apple TV the tiles stay focusable while the pill has focus: the focus engine needs them as the place a
    /// swipe right or Select in the pill moves to (otherwise focus gets stuck in the pill).
    private var tileInputEnabled: Bool {
        guard !isMini, !session.controlsHaveFocus, session.tilePicker == nil, !session.numberPadVisible else {
            return false
        }
        #if os(tvOS)
        return true
        #else
        return !shell.pillHasFocus
        #endif
    }

    private var handlers: MultiViewInputHandlers {
        MultiViewInputHandlers(
            showControls: { _ in
                #if os(tvOS)
                session.requestControlsFocus()
                #else
                session.showControlsBriefly()
                #endif
            },
            leavePlayer: {
                #if os(tvOS)
                shell.focusPill()
                #else
                shell.selection = shell.lastBrowsePane
                #endif
            },
            playPause: { session.togglePause() }
        )
    }

    private func frame(in size: CGSize) -> CGRect {
        guard isMini else { return CGRect(origin: .zero, size: size) }
        let mini = Self.miniSize
        return CGRect(x: size.width - mini.width - Self.miniInset, y: size.height - mini.height - Self.miniInset,
                      width: mini.width, height: mini.height)
    }
}

/// Now Playing in a window that doesn't show the video (another window of the app has it).
private struct PlayingElsewhere: View {
    @Environment(PlayerSession.self) private var session
    let fills: Bool
    let window: UUID

    var body: some View {
        ZStack {
            Color.black
            VStack(spacing: 10) {
                Image(systemName: "rectangle.on.rectangle").font(.system(size: 40))
                Text("Playing in Another Window").font(.headline)
                Button("Show Here") { session.showVideo(in: window, fills: fills) }
                    .buttonStyle(.borderedProminent)
            }
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

/// Mac and iPad keyboards in multi-view: the tiles hold keyboard focus (arrows, Return, Esc), so the player's other
/// keys are handled here, around them: Space/K play-pause, M mute, C captions, I stats. Apple TV has no keys.
private struct MultiViewPlayerKeys: ViewModifier {
    let session: PlayerSession

    func body(content: Content) -> some View {
        #if os(tvOS)
        content
        #else
        content
            .onKeyPress(keys: [.space, "k"]) { _ in handled { session.togglePause() } }
            .onKeyPress("m") {
                handled {
                    session.engine?.isMuted.toggle()
                    session.showControlsBriefly()
                }
            }
            .onKeyPress("c") { handled { session.toggleCaptions() } }
            .onKeyPress("i") { handled { session.statsVisible.toggle() } }
        #endif
    }

    #if !os(tvOS)
    private func handled(_ action: () -> Void) -> KeyPress.Result {
        guard session.isMultiView else { return .ignored }
        action()
        return .handled
    }
    #endif
}
