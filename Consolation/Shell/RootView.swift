//
//  RootView.swift
//  Consolation
//
//  The pill on the leading edge, the selected pane, and the mini player while something plays elsewhere.
//

import PlaybackKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct RootView: View {
    @Environment(ShellModel.self) var shell
    @Environment(PlayerSession.self) var session
    @Environment(QuickPlayHistory.self) private var history
    @Environment(LiveTVModel.self) var liveTV
    @Environment(\.scenePhase) var scenePhase
    /// tvOS, iPad and iPhone: the pill item with focus, if the pill has it.
    @FocusState var pillFocus: ShellItem?
    /// Back asked for the pill while it wasn't on screen; it shows and takes focus as it appears.
    @State var pillSummoned = false
    /// Apple TV: an item was just chosen, so the menu is closing: it is gone at once (a fading menu's buttons can still
    /// take focus, and tvOS gives it straight back to its first item).
    @State var menuClosing = false
    /// Updates the system's Now Playing info (Control Center, media keys, lock screen).
    let nowPlayingUpdate: () -> Void

    var body: some View {
        GeometryReader { proxy in
            let layout = ShellLayout.forWidth(proxy.size.width)
            content(layout: layout)
                .environment(\.shellLayout, layout)
        }
        .animation(.smooth(duration: 0.3), value: shell.selection)
        .animation(.smooth(duration: 0.3), value: session.isActive)
        .onChange(of: session.item) { _, _ in nowPlayingUpdate() }
        #if !os(macOS)
        // The Mac's pill is one keyboard target of its own (`pillKeyboardFocus()`).
        .onChange(of: pillFocus) { _, focused in shell.pillHasFocus = focused != nil }
        .onChange(of: shell.pillFocusRequest) { _, _ in
            // The pill may not be on screen (Apple TV, playing with the controls hidden; Apple TV's menu is never on
            // screen until asked): bring it first and focus it once it appears, or focus would have nowhere to go.
            menuClosing = false
            if showsPill, !isTelevisionMenu { pillFocus = shell.selection } else { pillSummoned = true }
        }
        .onChange(of: pillFocus) { _, focused in
            if focused != nil { pillSummoned = false }
        }
        #endif
        #if os(tvOS)
        // Apple TV starts in the restored pane, with the menu collapsed (or open, when the pane has nothing to focus).
        .task { await focusAtLaunch() }
        // Coming back to the app (tvOS suspends rather than quits it), or playback stopping, on a pane with nothing to
        // focus (Now Playing with nothing playing) opens the menu: with focus nowhere, Back would leave the app and the
        // menu couldn't be reached.
        .onChange(of: scenePhase) { _, phase in
            if phase == .active { openMenuIfStranded() }
        }
        .onChange(of: session.isActive) { openMenuIfStranded() }
        #endif
        // iPad and iPhone: Esc (hardware keyboard); iPad, iPhone and Mac: B (game controller) that Home's Etagere
        // didn't take. Back: the player returns to the last pane, and a pane moves focus to the pill.
        .backInput(window: shell.id, handlesEscape: shell.selection != .nowPlaying) {
            if shell.selection == .nowPlaying {
                shell.selection = shell.lastBrowsePane
            } else {
                shell.focusPill()
            }
        }
        .onChange(of: shell.selection, initial: true) { _, newValue in
            // Opening the player in a window brings the video to it.
            if newValue == .nowPlaying, session.isActive {
                session.showVideo(in: shell.id, fills: shell.fillsView)
                session.showControlsBriefly()
            }
            if session.videoWindow == shell.id { session.isFullScreen = newValue == .nowPlaying }
        }
        .onChange(of: session.videoWindow) { _, window in
            if window == shell.id { session.isFullScreen = shell.selection == .nowPlaying }
        }
        // Hiding the pane on screen (in this window's Settings or another's) goes Home.
        .onChange(of: shell.hiddenItems) { _, hidden in
            if hidden.contains(shell.selection) { shell.selection = .home }
        }
        #if !os(tvOS)
        .onPreferenceChange(CaptureChromeHiddenKey.self) { hidden in
            Task { @MainActor in shell.captureChromeHidden = hidden }
        }
        .appSheets(shell: shell)
        #endif
        .onChange(of: session.engine?.state) { _, newState in
            if newState == .playing, case .url(let url) = session.item { history.record(url) }
            PlaybackDisplayWakeLock.setActive(newState == .playing)
            nowPlayingUpdate()
        }
        #if os(macOS)
        .floatingVideoWindow(session: session, window: shell.id)
        .onReceive(NSWorkspace.shared.notificationCenter.publisher(for: NSWorkspace.willSleepNotification)) { _ in
            session.stop()
        }
        #endif
        #if os(tvOS)
        .focusTrace()
        .onPlayPauseCommand {
            // Play/Pause dismisses the mini player on Apple TV. Home's Etagere hears it first and asks the same rule.
            if ShellModel.playPauseDismissesMiniPlayer(isPlaying: session.isActive, selection: shell.selection) {
                session.stop()
            }
        }
        #endif
    }

    @ViewBuilder private func content(layout: ShellLayout) -> some View {
        @Bindable var shell = shell
        let inPlayer = shell.selection == .nowPlaying
        // The player and the Capture Card viewer fill the window; the pill floats over them.
        let fillsWindow = inPlayer || shell.selection == .captureCard
        ZStack(alignment: layout == .compact ? .bottom : .leading) {
            pane
                // tvOS: the pane is its own focus section.
                .paneFocusSection()
                .padding(.leading, fillsWindow || layout != .regular ? 0 : layout.pillInset)
                .padding(.top, fillsWindow || layout != .television ? 0 : Self.tvHeaderInset)
                .padding(.bottom, fillsWindow || layout != .compact ? 0 : 76)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                #if os(tvOS)
                // Back in a pane opens the menu (Apple Music's pattern). While the menu is open the content takes no
                // focus, so only up and down move, within the menu.
                .onExitCommand { shell.focusPill() }
                .disabled(isMenuOpen)
                #endif
            // One video surface for the whole app: full size in Now Playing, the mini player elsewhere.
            PlayerSurfaceContainer(isMini: !inPlayer)
                .disabled(isMenuOpen)
            // The player's chrome goes with the video; another window's Now Playing shows only where it plays.
            if inPlayer, session.videoWindow == shell.id || !session.isActive {
                NowPlayingChrome()
                    .disabled(isMenuOpen)
            }
            #if os(tvOS)
            televisionMenu(inPlayer: inPlayer)
            #else
            if showsPill {
                PillSidebar(items: shell.visibleItems, selection: $shell.selection,
                            axis: layout == .compact ? .horizontal : .vertical,
                            badged: session.isActive ? [.nowPlaying] : [], focus: pillFocusBinding,
                            showsFocusRing: pillShowsFocusRing)
                    .pillKeyboardFocus()
                    .padding(layout == .compact ? .bottom : .leading, 12)
                    .onAppear {
                        guard pillSummoned else { return }
                        Task { @MainActor in pillFocus = shell.selection }
                    }
                    .transition(.opacity)
            }
            #endif
        }
    }

    /// tvOS drives selection from pill focus; iPad and iPhone move keyboard focus there on Esc. The Mac selects
    /// by click and ⌘-number, and its pill takes keyboard focus as a whole (`pillKeyboardFocus()`).
    private var pillFocusBinding: FocusState<ShellItem?>.Binding? {
        #if os(tvOS) || os(iOS)
        $pillFocus
        #else
        nil
        #endif
    }

    /// Mac: the pill draws its own focus ring while it is the keyboard target.
    private var pillShowsFocusRing: Bool {
        #if os(macOS)
        shell.pillHasFocus
        #else
        false
        #endif
    }

    /// In the player and the Capture Card viewer, the pill is part of the auto-hiding chrome, and comes when Back
    /// asks for it.
    private var showsPill: Bool {
        if pillFocus != nil || shell.pillHasFocus || pillSummoned { return true }
        switch shell.selection {
        case .nowPlaying: return session.controlsVisible || !session.isActive
        case .captureCard: return !shell.captureChromeHidden
        default: return true
        }
    }

    /// Apple TV: the menu's distance from the screen's leading and top edges, and the space the collapsed header
    /// takes above each pane.
    static let tvPillInset: CGFloat = 48
    static let tvHeaderInset: CGFloat = 96

    @ViewBuilder private var pane: some View {
        switch shell.selection {
        case .home: HomeView()
        case .liveTV: LiveTVView()
        case .quickPlay: QuickPlayView()
        case .library: LibraryView()
        case .nowPlaying: NowPlayingView()
        case .captureCard: captureCardPane
        case .settings: SettingsView()
        }
    }

    @ViewBuilder private var captureCardPane: some View {
        #if os(tvOS)
        HomeView()
        #else
        CaptureCardPane()
        #endif
    }
}

private extension View {
    @ViewBuilder
    func paneFocusSection() -> some View {
        #if os(tvOS)
        frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading).focusSection()
        #else
        self
        #endif
    }
}
