//
//  ShellModel.swift
//  Consolation
//
//  One window's shell: which pane is showing, its own player view state, and restoring the last pane. Every window
//  (iPad, iPhone Duo and Mac can show several) has its own; hidden sidebar items are app-wide (`PillSettings`).
//

import Foundation
import Observation

@Observable
final class ShellModel {
    private static let selectionKey = AppIdentifier.scoped("shell.selection")

    private let defaults: UserDefaults
    private let settings: PillSettings

    /// Identifies the window, e.g. for which one shows the video (`PlayerSession.videoWindow`).
    let id = UUID()

    /// The pane on screen. Every change is saved, so the next launch (or a new window) starts there.
    var selection: ShellItem = .home {
        didSet {
            guard selection != oldValue else { return }
            if selection != .nowPlaying { lastBrowsePane = selection }
            defaults.set(selection.rawValue, forKey: Self.selectionKey)
        }
    }

    /// This window's Zoom to Fill, applied while the video shows here.
    var fillsView = false

    /// Items the user hid in Settings (for every window).
    var hiddenItems: Set<ShellItem> { settings.hiddenItems }

    /// The last pane that isn't Now Playing, used when the player is dismissed and at launch.
    private(set) var lastBrowsePane: ShellItem = .home

    /// Whether the pill has focus (on the Mac, keyboard focus after Esc). Panes don't take focus on appear while it
    /// does, so moving through the pill (selection follows focus on Apple TV, ↑ and ↓ on the Mac) never pulls focus
    /// into a pane.
    var pillHasFocus = false
    /// Bumped to ask the root view to move focus to the selected pill item (e.g. Back from the player on Apple TV).
    private(set) var pillFocusRequest = 0
    /// Bumped to ask the selected pane to take focus (on the Mac, → or Return in the pill).
    private(set) var contentFocusRequest = 0
    /// tvOS: a pane control that takes every direction (Home's Etagere) has focus. Only the region that owns focus is
    /// enabled, so the root view disables the pill meanwhile and the focus engine can never take a left swipe from it.
    /// `focusPill()` clears it.
    var contentHoldsFocus = false
    /// The Settings section to bring into view when Settings next shows ("Edit Home", an empty Home shelf's "go").
    /// Settings clears it once shown.
    var settingsTarget: SettingsSection?
    /// About or Help, opened from the menu bar over this window.
    var presentedSheet: AppSheet?
    /// The Capture Card viewer hid its chrome (video running, pointer resting): the pill hides with it.
    var captureChromeHidden = false

    func focusPill() {
        contentHoldsFocus = false
        pillFocusRequest += 1
    }

    /// Moves focus from the pill into the selected pane.
    func focusContent() {
        contentFocusRequest += 1
    }

    /// Selects the pill item `step` places after (or, negative, before) the selected one, without wrapping: ↑ and ↓
    /// in the Mac's pill.
    func selectAdjacentItem(by step: Int) {
        let items = visibleItems
        guard let index = items.firstIndex(of: selection), items.indices.contains(index + step) else { return }
        selection = items[index + step]
    }

    /// How long a pane waits after it is selected before it refreshes from the network. On Apple TV the selection
    /// follows focus through the pill, so moving through it never starts a refresh; elsewhere a pane is selected on
    /// purpose and refreshes at once.
    static var paneRefreshDelay: Duration {
        #if os(tvOS)
        .milliseconds(500)
        #else
        .zero
        #endif
    }

    /// Play/Pause on the Siri Remote outside the player: while something plays, it dismisses the mini player; otherwise
    /// it belongs to the pane (Home plays the Active ShelfCard).
    static func playPauseDismissesMiniPlayer(isPlaying: Bool, selection: ShellItem) -> Bool {
        isPlaying && selection != .nowPlaying
    }

    /// Shows Settings at one of its sections.
    func openSettings(_ section: SettingsSection) {
        settingsTarget = section
        selection = .settings
    }

    init(settings: PillSettings, defaults: UserDefaults = .standard) {
        self.settings = settings
        self.defaults = defaults
        let saved = defaults.string(forKey: Self.selectionKey).flatMap(ShellItem.init(rawValue:)) ?? .home
        selection = Self.restorable(saved, hidden: settings.hiddenItems)
        lastBrowsePane = selection
    }

    /// The items the pill shows, in order.
    var visibleItems: [ShellItem] { settings.visibleItems }

    func setHidden(_ item: ShellItem, _ hidden: Bool) {
        settings.setHidden(item, hidden)
    }

    /// Restores a window's own saved pane (iPad and iPhone Duo bring windows back with their state).
    func restore(_ rawValue: String?) {
        guard let item = rawValue.flatMap(ShellItem.init(rawValue:)) else { return }
        selection = Self.restorable(item, hidden: hiddenItems)
    }

    /// Now Playing is never restored (nothing plays at launch), and a hidden item, or one this device doesn't have,
    /// falls back to Home.
    static func restorable(_ item: ShellItem, hidden: Set<ShellItem>) -> ShellItem {
        if item == .nowPlaying || hidden.contains(item) || !item.isAvailable { return .home }
        return item
    }
}
