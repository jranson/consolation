//
//  ShellItem.swift
//  Consolation
//

import SwiftUI

/// The panes the pill switches between. Raw values are persisted, so don't rename them.
nonisolated enum ShellItem: String, CaseIterable, PillItem, Codable {
    case home
    case liveTV
    case quickPlay
    case library
    case nowPlaying
    /// Today's capture card viewer, just above Settings. Mac and iPad only (`CaptureCardSupport`).
    case captureCard
    case settings

    var id: String { rawValue }

    var title: LocalizedStringResource {
        switch self {
        case .home: "Home"
        case .liveTV: "Live TV"
        case .quickPlay: "Quick Play"
        case .library: "Library"
        case .nowPlaying: "Now Playing"
        case .captureCard: "Capture Card"
        case .settings: "Settings"
        }
    }

    var systemImage: String {
        switch self {
        case .home: "house"
        case .liveTV: "antenna.radiowaves.left.and.right"
        case .quickPlay: "link"
        case .library: "square.stack"
        case .nowPlaying: "play.rectangle.on.rectangle"
        case .captureCard: CaptureCardSupport.systemImage
        case .settings: "gearshape"
        }
    }

    var placement: PillPlacement {
        switch self {
        case .captureCard, .settings: .trailing
        case .home, .liveTV, .quickPlay, .library, .nowPlaying: .main
        }
    }

    /// Home, Now Playing and Settings are always shown; the others can be hidden in Settings.
    var isHideable: Bool {
        switch self {
        case .liveTV, .quickPlay, .library, .captureCard: true
        case .home, .nowPlaying, .settings: false
        }
    }

    /// Whether this device has the pane at all: Capture Card needs a Mac or an iPad.
    @MainActor var isAvailable: Bool {
        self != .captureCard || CaptureCardSupport.isAvailable
    }

    /// Every item this device has, in pill order.
    @MainActor static var availableCases: [ShellItem] {
        allCases.filter(\.isAvailable)
    }

    /// Fixed per item (they follow Consolation's order, where ⌘3 is Capture Card), so hiding never renumbers.
    var shortcutKey: KeyEquivalent? {
        switch self {
        case .home: "1"
        case .liveTV: "2"
        case .quickPlay: "4"
        case .library: "5"
        case .nowPlaying: "6"
        case .captureCard: "3"
        case .settings: ","
        }
    }
}
