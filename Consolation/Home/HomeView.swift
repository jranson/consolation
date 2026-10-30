//
//  HomeView.swift
//  Consolation
//
//  Home: the user's shelves on an Etagere. Each window keeps its own Etagere model (HomeEtagere), so switching panes
//  keeps every shelf where it was. "Go" plays the Active ShelfCard; an empty shelf's placeholder runs its fitting
//  action (Settings › Sources, the Live TV pane, the system's Local Network setting); Back, Esc or controller B leaves
//  for the pill. Card actions (Favorite, Info, Edit Home) are in the context menu, because in mode 1 the Etagere is the
//  only control on the page.
//

import EtagereKit
import HTTPMPEG2Kit
import MediaSourceKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct HomeView: View {
    @Environment(HomeModel.self) private var home
    @Environment(HomeSettings.self) private var settings
    @Environment(HomeEtagere.self) private var etagere
    @Environment(AppFavorites.self) private var favorites
    @Environment(PlayerSession.self) private var session
    @Environment(ShellModel.self) private var shell
    @Environment(GameControllers.self) private var controllers
    @Environment(\.scenePhase) private var scenePhase
    @Environment(\.openURL) private var openURL
    #if !os(tvOS)
    @Environment(CaptureSessionManager.self) private var capture
    #endif
    @FocusState private var isFocused: Bool
    @State private var containerWidth: CGFloat?
    @State private var infoCard: VideoCard?
    @State private var notice: HomeNotice?

    var body: some View {
        VideoEtagere(model: etagere.model, onActivate: play, onActivateEmptyShelf: activateEmptyShelf, onExit: leave)
        .etagereContextMenu { card in
            actions(for: card)
        } emptyShelf: { _ in
            editHome
        }
        .onEtagerePlayPause(dismissMiniPlayer)
        .etagereGamepad(controllers.gamepad, requiresFocus: GameControllers.etagereRequiresFocus)
        .focused($isFocused)
        .accessibilityIdentifier("home.etagere")
        .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { containerWidth = $0 }
        .onChange(of: settings.etagereConfiguration(containerWidth: containerWidth), initial: true) { _, new in
            etagere.configure(new)
        }
        .onChange(of: home.shelves, initial: true) { syncShelves() }
        .onChange(of: favorites.keys) { syncShelves() }
        .onChange(of: captureCardName) { syncShelves() }
        .task {
            // Apple TV: moving through the pill (selection follows focus) never starts a refresh.
            await home.appear(after: ShellModel.paneRefreshDelay)
            guard !Task.isCancelled else { return }
            etagere.finishRestoring()
        }
        .onAppear(perform: takeFocus)
        // The pill handing focus to Home: → or Return in it on the Mac, Back or Select in it on Apple TV.
        .onChange(of: shell.contentFocusRequest) { isFocused = true }
        .onDisappear {
            home.disappear()
            etagere.savePosition()
            shell.contentHoldsFocus = false
        }
        .onChange(of: scenePhase) { _, phase in
            if phase != .active { etagere.savePosition() }
        }
        .onAppTermination { etagere.savePosition() }
        #if os(tvOS)
        // Only the region that owns focus is enabled: the pill stays out of reach while the Etagere has focus, so left
        // turns a ring instead of leaving. Back clears it (`ShellModel.focusPill()`).
        .onChange(of: isFocused) { _, focused in shell.contentHoldsFocus = focused }
        #endif
        .sheet(item: $infoCard) { card in
            VideoCardInfoView(card: card)
        }
        .alert(notice?.title ?? "", isPresented: isShowingNotice, presenting: notice) { _ in
            Button("OK", role: .cancel) {}
        } message: { notice in
            Text(notice.message)
        }
    }

    // MARK: - Actions

    /// "Go": resolves the card through its source and plays it, opening the player unless the window moved on
    /// meanwhile. Says so when no source has the card now. The Capture Card card opens its pane.
    private func play(_ card: VideoCard) {
        if card.kind == .captureCard {
            shell.selection = .captureCard
            return
        }
        Task {
            guard await home.go(to: card.playable.item, in: shell, session: session) == .unavailable else { return }
            notice = .unavailable(card.title)
        }
    }

    /// "Go" on an empty shelf's placeholder: the fitting action for that shelf now.
    private func activateEmptyShelf(_ shelfID: String) {
        switch home.emptyShelfAction(for: shelfID) {
        case .settings(let section):
            shell.openSettings(section)
        case .pane(let item):
            if shell.hiddenItems.contains(item) {
                shell.openSettings(.sources)
            } else {
                shell.selection = item
            }
        case .localNetworkSettings:
            if let url = LocalNetworkSettings.url {
                openURL(url)
            } else {
                notice = .localNetwork
            }
        }
    }

    /// Apple TV's Play/Pause reaches the Etagere first: while something plays, it dismisses the mini player; otherwise
    /// the Etagere plays the Active ShelfCard.
    private func dismissMiniPlayer() -> Bool {
        guard ShellModel.playPauseDismissesMiniPlayer(isPlaying: session.isActive, selection: shell.selection) else {
            return false
        }
        session.stop()
        return true
    }

    private var isShowingNotice: Binding<Bool> {
        Binding { notice != nil } set: { if !$0 { notice = nil } }
    }

    @EtagereActionBuilder
    private func actions(for card: VideoCard) -> [EtagereAction] {
        // Favorites on the tuner are read-only; only the app's own can be toggled.
        if card.favorite != .device, let key = card.playable.item.channelKey?.stringValue {
            if card.favorite == .app {
                EtagereAction(String(localized: "Unfavorite"), systemImage: "heart.slash") { favorites.toggle(key) }
            } else {
                EtagereAction(String(localized: "Favorite"), systemImage: "heart") { favorites.toggle(key) }
            }
        }
        if session.isActive, card.kind != .captureCard {
            EtagereAction(String(localized: "Add to Multi-view"), systemImage: "plus.rectangle.on.rectangle") {
                addToMultiView(card)
            }
        }
        EtagereAction(String(localized: "Info"), systemImage: "info.circle") { infoCard = card }
        editHome
    }

    /// Adds the card as a multi-view tile and opens the player to show it.
    private func addToMultiView(_ card: VideoCard) {
        Task {
            if await home.addToMultiView(card.playable.item, session: session) {
                shell.selection = .nowPlaying
            } else {
                notice = .unavailable(card.title)
            }
        }
    }

    private var editHome: EtagereAction {
        EtagereAction(String(localized: "Edit Home"), systemImage: "slider.horizontal.3") {
            shell.openSettings(.home)
        }
    }

    /// Back, Esc or controller B in the Etagere: focus goes to the pill (on the Mac, the pill becomes the keyboard
    /// target until focus leaves it; see PillKeyboard.swift).
    private func leave() {
        shell.focusPill()
    }

    /// Mac and iPad keyboards: Home's arrows work at once. Not while the pill has focus, and not on Apple TV, where
    /// focus starts in the pill and right enters the Etagere.
    private func takeFocus() {
        #if !os(tvOS)
        if !shell.pillHasFocus { isFocused = true }
        #endif
    }

    private func syncShelves() {
        let keys = favorites.keys
        let leading = captureCardName.map { [VideoCard.captureCard(deviceName: $0)] } ?? []
        etagere.update(home.shelves, isAppFavorite: { id in
            id.channelKey.map { keys.contains($0.stringValue) } ?? false
        }, favoritesLeadingCards: leading)
    }

    /// The attached capture card's name while Home shows the Capture Card card: on a Mac or iPad, with a capture
    /// card (not a FaceTime or Continuity camera) attached and the Capture Card item not hidden in Settings.
    private var captureCardName: String? {
        #if os(tvOS)
        nil
        #else
        guard ShellItem.captureCard.isAvailable, !shell.hiddenItems.contains(.captureCard) else { return nil }
        return capture.usbCaptureDeviceEntries.first?.localizedName
        #endif
    }
}

private extension View {
    /// macOS: runs `action` when the app quits, which neither hides the pane nor moves the scene to the background.
    func onAppTermination(perform action: @escaping () -> Void) -> some View {
        #if os(macOS)
        onReceive(NotificationCenter.default.publisher(for: NSApplication.willTerminateNotification)) { _ in
            action()
        }
        #else
        self
        #endif
    }
}
