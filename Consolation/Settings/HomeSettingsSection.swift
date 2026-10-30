//
//  HomeSettingsSection.swift
//  Consolation
//
//  Settings › Home: which shelves Home shows and in what order, and how the Etagere lays them out. Changes apply at
//  once to Home in every window.
//

import EtagereKit
import MediaSourceKit
import SwiftUI

struct HomeSettingsSection: View {
    @Environment(HomeSettings.self) private var settings
    /// "Edit Home" opens Settings here, with the first shelf's switch focused.
    let focus: FocusState<SettingsSection?>.Binding

    var body: some View {
        Section {
            ForEach(Array(settings.shelves.enumerated()), id: \.element.kind) { index, setting in
                // The rows' IDs are their kinds; Settings scrolls to the first one for "Edit Home".
                HomeShelfRow(setting: setting, index: index, count: settings.shelves.count,
                             focus: index == 0 ? focus : nil)
            }
        } header: {
            Text("Home")
        } footer: {
            Text("""
                Quick Play History is off by default: stream addresses can carry passwords or tokens, and Home is \
                the screen others see most. While it's off, videos played from Quick Play stay out of Continue \
                Watching too.
                """)
        }
        HomeLayoutSettings()
    }
}

/// One shelf: its switch, and buttons that move it up or down (a list's drag-to-reorder doesn't exist on Apple TV
/// and needs edit mode on iPhone and iPad).
private struct HomeShelfRow: View {
    @Environment(HomeSettings.self) private var settings
    let setting: HomeShelfSetting
    let index: Int
    let count: Int
    let focus: FocusState<SettingsSection?>.Binding?

    var body: some View {
        let title = setting.kind.settingsTitle
        HStack {
            Toggle(isOn: Binding(get: { setting.isEnabled }, set: { settings.setEnabled(setting.kind, $0) })) {
                Text(title)
            }
            .modifier(OptionalFocus(focus: focus, value: .home))
            Button {
                withAnimation { settings.move(fromOffsets: [index], toOffset: index - 1) }
            } label: {
                Image(systemName: "chevron.up")
            }
            .disabled(index == 0)
            .accessibilityLabel(Text("Move \(Text(title)) Up"))
            Button {
                withAnimation { settings.move(fromOffsets: [index], toOffset: index + 2) }
            } label: {
                Image(systemName: "chevron.down")
            }
            .disabled(index == count - 1)
            .accessibilityLabel(Text("Move \(Text(title)) Down"))
        }
        .buttonStyle(.borderless)
    }
}

private struct OptionalFocus: ViewModifier {
    let focus: FocusState<SettingsSection?>.Binding?
    let value: SettingsSection

    func body(content: Content) -> some View {
        if let focus {
            content.focused(focus, equals: value)
        } else {
            content
        }
    }
}

/// Alignments, vertical navigation, card size and the seam.
private struct HomeLayoutSettings: View {
    @Environment(HomeSettings.self) private var settings

    var body: some View {
        @Bindable var settings = settings
        Section {
            Picker("Shelf alignment", selection: $settings.shelfAlignment) {
                Text("Leading").tag(EtagereHorizontalAlignment.leading)
                Text("Center").tag(EtagereHorizontalAlignment.center)
                Text("Trailing").tag(EtagereHorizontalAlignment.trailing)
            }
            Picker("Vertical navigation", selection: $settings.verticalMode) {
                Text("Ring").tag(EtagereVerticalMode.ring)
                Text("Cursor").tag(EtagereVerticalMode.cursor)
            }
            Picker("Vertical alignment", selection: $settings.verticalAlignment) {
                Text("Top").tag(EtagereVerticalAlignment.top)
                Text("Center").tag(EtagereVerticalAlignment.center)
                Text("Bottom").tag(EtagereVerticalAlignment.bottom)
            }
            Picker("Card size", selection: $settings.cardSize) {
                Text("Small").tag(HomeCardSize.small)
                Text("Medium").tag(HomeCardSize.medium)
                Text("Large").tag(HomeCardSize.large)
            }
            Toggle("Show the cycle seam", isOn: $settings.showsSeam)
        } header: {
            Text("Home Layout")
        } footer: {
            Text("""
                Ring turns the shelves like the cards, and Home takes every direction until you press Back or \
                Esc. Cursor keeps the shelves in place and moves between them. The seam marks where a row starts \
                over.
                """)
        }
    }
}

extension HomeShelfKind {
    /// The shelf's name in Settings › Home.
    var settingsTitle: LocalizedStringResource {
        switch self {
        case .favorites: "Favorites"
        case .liveChannels: "Live TV Channels"
        case .recordingNow: "Recording Now"
        case .recentRecordings: "Recent Recordings"
        case .continueWatching: "Continue Watching"
        case .quickPlayHistory: "Quick Play History"
        case .library: "Library"
        }
    }
}
