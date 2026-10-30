//
//  NowPlayingView.swift
//  Consolation
//
//  The full-size player: a backdrop below the video, and the banner, controls and state overlays above it.
//

import PlaybackKit
import PlayerKit
import SwiftUI

/// The Now Playing pane's backdrop, drawn below the video (which PlayerSurfaceContainer draws above it).
struct NowPlayingView: View {
    @Environment(PlayerSession.self) private var session

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let freezeFrame = session.freezeFrame, session.tunerReleased {
                Image(decorative: freezeFrame, scale: 1)
                    .resizable()
                    .scaledToFit()
                    .opacity(0.6)
            }
            if session.engine == nil {
                if let item = session.item {
                    PlayerMessage(systemImage: "antenna.radiowaves.left.and.right", title: "Tuning \(item.title)…")
                } else {
                    PlayerMessage(systemImage: "play.rectangle.on.rectangle", title: "Nothing Playing",
                                  detail: "Choose a channel in Live TV or a URL in Quick Play.")
                }
            }
        }
    }
}

/// Everything drawn over the full-size video: state overlays, the channel banner, the auto-hiding controls, and
/// the player's keyboard and remote input.
struct NowPlayingChrome: View {
    @Environment(PlayerSession.self) private var session
    @Environment(PlaybackPreferences.self) private var preferences
    @Environment(ShellModel.self) private var shell
    @FocusState private var focused: Bool
    /// Apple TV: the controls' Play/Pause button has focus.
    @FocusState private var controlsFocused: Bool
    /// Apple TV: Select asked for the controls before they were on screen; focus them as they appear.
    @State private var focusControlsWhenShown = false

    private var videoAspect: CGFloat {
        guard let info = session.engine?.streamInfo, let width = info.width, let height = info.height,
              height > 0 else { return 16 / 9 }
        return CGFloat(width) / CGFloat(height)
    }

    var body: some View {
        ZStack {
            Color.clear.contentShape(Rectangle())
            // In multi-view each tile shows its own state (TileOverlayView).
            if let engine = session.engine, !session.isMultiView {
                PlayerStateOverlay(engine: engine, tunerReleased: session.tunerReleased)
            }
        }
        .ignoresSafeArea()
        // Multi-view: clicks and taps reach the tiles below.
        .allowsHitTesting(!session.isMultiView)
        // tvOS: the TV follows the full-screen stream's frame rate when Match Content is on.
        .displayCriteria(session.engine?.state == .playing ? DisplayMatch(info: session.engine?.streamInfo) : nil)
        .overlay {
            if preferences.captionsEnabled, showsCaptions, let captions = session.engine as? any CaptionProviding,
               !captions.captionScreen.isEmpty {
                CaptionOverlayView(screen: captions.captionScreen, videoAspectRatio: videoAspect)
                    .aspectRatio(videoAspect, contentMode: .fit)
                    .allowsHitTesting(false)
            }
        }
        .overlay(alignment: .topTrailing) {
            if session.statsVisible, let engine = session.engine {
                PlayerStatsOverlay(engine: engine, diagnostics: session.liveControls?.diagnostics)
                    .padding(.top, 40)
                    .padding(.trailing, 16)
            }
        }
        .overlay(alignment: .topLeading) {
            if !session.enteredDigits.isEmpty {
                Text(session.enteredDigits)
                    .font(.system(size: 44, weight: .bold).monospacedDigit())
                    .foregroundStyle(.white)
                    .padding(.horizontal, 18)
                    .padding(.vertical, 8)
                    .background(.black.opacity(0.6), in: .rect(cornerRadius: 12))
                    .padding(.top, 40)
                    .padding(.leading, 100)
            }
        }
        .overlay(alignment: .top) {
            if session.bannerVisible, let channel = session.currentChannel {
                ChannelBanner(channel: channel)
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        #if !os(tvOS)
        .overlay(alignment: .bottom) {
            if session.controlsVisible, session.isActive {
                PlayerControls()
                    .transition(.opacity)
            }
        }
        #endif
        .animation(.smooth(duration: 0.25), value: session.controlsVisible)
        .animation(.smooth(duration: 0.25), value: session.bannerVisible)
        #if !os(tvOS)
        // Apple TV: Select reaches the video's button instead; a tap gesture there would also make this full-screen
        // layer a focus target over multi-view's tiles.
        .onTapGesture { session.showControlsBriefly() }
        #endif
        #if os(macOS)
        .onContinuousHover { phase in
            if case .active = phase { session.showControlsBriefly() }
        }
        #endif
        // With several tiles, PlayerKit's tile input takes the keys and the remote instead.
        .playerKeyCommands(session: session, isEnabled: !session.isMultiView && !session.controlsPinned, onBack: back,
                           onSelect: showControlsFromRemote)
        // Multi-view: the chrome takes no focus at all (as a focus target over the tiles it kept the focus engine
        // from moving between them).
        .modifier(ChromeFocus(focused: $focused, isEnabled: !session.isMultiView))
        #if os(tvOS)
        // Outside the focusable video, so the remote can move focus into them (a focus section of their own).
        .overlay(alignment: .bottom) { remoteControls }
        .onChange(of: focused) { _, videoFocused in controlsFocusChanged(videoFocused: videoFocused) }
        #endif
        .onAppear {
            // Not while the pill has focus (Apple TV: moving through the pill selects Now Playing).
            if !shell.pillHasFocus { focused = true }
            if session.isActive { session.showControlsBriefly() }
        }
        // tvOS: the 123 button's number pad sits outside the focusable player so its keys can take focus.
        .overlay {
            if session.numberPadVisible { NumberPad() }
        }
        .onChange(of: session.numberPadVisible) { _, visible in
            if !visible { focused = true }
        }
        // Mac: → or Return in the pill.
        .onChange(of: shell.contentFocusRequest) { focused = true }
        // Apple TV, multi-view: Select on the front tile.
        .onChange(of: session.controlsFocusRequest) { showControlsFromRemote() }
        #if os(tvOS)
        // The tiles below take no remote input while the controls are up.
        .onChange(of: session.controlsVisible, initial: true) { _, visible in session.controlsHaveFocus = visible }
        #endif
        .overlay { MultiViewPanels() }
        .overlay(alignment: .top) {
            if let notice = session.multiViewNotice {
                PlayerNotice(text: notice).transition(.opacity)
            }
        }
        .animation(.smooth(duration: 0.25), value: session.multiViewNotice)
        // ATSC 3.0: the video plays, its AC-4 audio can't (no decoder on Apple platforms); say so while it plays.
        .overlay(alignment: .bottomLeading) {
            if let codec = session.engine?.streamInfo.unsupportedAudioCodec, !session.isMultiView {
                Label("No audio (\(codec))", systemImage: "speaker.slash")
                    .font(.callout.weight(.semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 8)
                    .glassEffect(.regular, in: .capsule)
                    .padding(28)
                    .allowsHitTesting(false)
            }
        }
        .remoteButtons { button in
            switch button {
            case .pageUp: session.channelUp()
            case .pageDown: session.channelDown()
            case .oneTwoThree: if session.currentChannel != nil { session.numberPadVisible = true }
            }
        }
    }
}

extension NowPlayingChrome {
    /// Captions belong to the target tile: shown for one stream or the tile in front, not over a grid.
    fileprivate var showsCaptions: Bool {
        !session.isMultiView || session.multiView.mode?.foregroundTile != nil
    }

    /// Apple TV: Select on the video brings the controls up and moves focus to Play/Pause; they stay up while focus
    /// is in them. Elsewhere Select doesn't reach here (taps and clicks show the controls).
    fileprivate func showControlsFromRemote() {
        guard session.isActive else { return }
        let showing = session.controlsVisible
        session.pinControls()
        if showing { controlsFocused = true } else { focusControlsWhenShown = true }
    }

    #if os(tvOS)
    @ViewBuilder fileprivate var remoteControls: some View {
        if session.controlsVisible, session.isActive {
            PlayerControls(playPauseFocus: $controlsFocused)
                .focusSection()
                // Back in the controls hides them and returns to the video; Back there goes on to the pill.
                .onExitCommand {
                    session.hideControls()
                    // The video takes focus again once it is enabled (it isn't while focus is in the controls).
                    Task { @MainActor in focused = true }
                }
                .onPlayPauseCommand { session.playPauseFromRemote() }
                .onAppear {
                    guard focusControlsWhenShown else { return }
                    focusControlsWhenShown = false
                    Task { @MainActor in controlsFocused = true }
                }
                .transition(.opacity)
        }
    }

    /// Focus left the video for the controls: keep them up. Back on the video: let them hide on their own.
    fileprivate func controlsFocusChanged(videoFocused: Bool) {
        guard session.isActive, !session.numberPadVisible else { return }
        if videoFocused {
            session.unpinControls()
            if session.controlsVisible { session.showControlsBriefly() }
        } else if session.controlsVisible, !shell.pillHasFocus {
            session.pinControls()
        }
    }
    #endif

    /// Back in the player: Apple TV moves focus to the pill (Back there leaves the app, as tvOS expects); elsewhere
    /// the player returns to the last pane.
    fileprivate func back() {
        #if os(tvOS)
        shell.focusPill()
        #else
        shell.selection = shell.lastBrowsePane
        #endif
    }
}

/// Buffering, failure and "tuner released" overlays, driven by the engine's real state.
struct PlayerStateOverlay: View {
    let engine: any PlaybackEngine
    let tunerReleased: Bool

    var body: some View {
        if tunerReleased {
            PlayerMessage(systemImage: "pause.circle", title: "Paused. The tuner was released.",
                          detail: "Press Play to tune again.")
        } else {
            switch engine.state {
            case .connecting, .buffering:
                ProgressView().controlSize(.large).tint(.white)
            case .failed(let error):
                PlayerErrorCard(error: error)
            default:
                EmptyView()
            }
        }
    }
}

struct PlayerMessage: View {
    let systemImage: String
    let title: String
    var detail: String?

    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: systemImage).font(.system(size: 44))
            Text(title).font(.title2.bold())
            if let detail, !detail.isEmpty {
                Text(detail).font(.callout).foregroundStyle(.secondary).multilineTextAlignment(.center)
            }
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 520)
    }
}

struct ChannelBanner: View {
    let channel: LiveChannel

    var body: some View {
        HStack(spacing: 14) {
            Text(channel.guideNumber).font(.title.monospacedDigit().bold())
            VStack(alignment: .leading, spacing: 2) {
                Text(channel.name).font(.headline)
                Text(channel.isHD ? "HD · Live" : "Live").font(.caption).foregroundStyle(.secondary)
            }
            if let symbol = channel.favorite.systemImage {
                Image(systemName: symbol).foregroundStyle(.pink)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 12)
        .frame(maxWidth: 420)
        .glassEffect(.regular, in: .rect(cornerRadius: 16))
        .padding(.top, 24)
        .allowsHitTesting(false)
    }
}

/// A failure with Retry and Copy Details (domain and code, never a URL's query string).
struct PlayerErrorCard: View {
    @Environment(PlayerSession.self) private var session
    let error: PlaybackError

    var body: some View {
        VStack(spacing: 14) {
            PlayerMessage(systemImage: "exclamationmark.triangle", title: error.title, detail: details)
            HStack(spacing: 12) {
                Button("Retry") { session.retry() }
                    .buttonStyle(.borderedProminent)
                #if !os(tvOS)
                Button("Copy Details") { copyDetails() }
                #endif
            }
        }
    }

    private var details: String {
        [error.detail, error.domain.map { "\($0) \(error.code ?? 0)" }]
            .compactMap { $0 }.filter { !$0.isEmpty }.joined(separator: "\n")
    }

    #if !os(tvOS)
    private func copyDetails() {
        Clipboard.copy([error.title, details, BuildInfo.copyableBlob].joined(separator: "\n"))
    }
    #endif
}

/// `.focused(binding)` while enabled; nothing otherwise.
private struct ChromeFocus: ViewModifier {
    let focused: FocusState<Bool>.Binding
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled { content.focused(focused) } else { content }
    }
}
