//
//  SettingsView.swift
//  Consolation
//
//  Settings is a pane inside the window (⌘, selects it), not a separate window.
//

import MediaSourceKit
import SwiftUI

/// A Settings section another pane can open Settings at (`ShellModel.openSettings(_:)`).
enum SettingsSection: Hashable {
    case sources
    case home
}

struct SettingsView: View {
    @Environment(ShellModel.self) private var shell
    @Environment(QuickPlayHistory.self) private var history
    @Environment(HomeSettings.self) private var homeSettings
    @Environment(LocalNetworkGate.self) private var localNetwork
    /// The first control of the section another pane opened Settings at.
    @FocusState private var focusedSection: SettingsSection?

    var body: some View {
        ScrollViewReader { proxy in
            form
                .onAppear { reveal(with: proxy) }
                .onChange(of: shell.settingsTarget) { reveal(with: proxy) }
                // The pill handing focus back (Back or Select in it on Apple TV): the first section's control.
                .onChange(of: shell.contentFocusRequest) { focusedSection = .sources }
                // For every section that reaches the network (tuners, library servers): a sheet on a row inside the
                // form doesn't present reliably.
                .localNetworkExplanation(localNetwork)
        }
    }

    private var form: some View {
        Form {
            SourcesSettingsSection(focus: $focusedSection)
            LibraryServersSettingsSection()
            HomeSettingsSection(focus: $focusedSection)
            Section("Sidebar") {
                ForEach(ShellItem.availableCases.filter(\.isHideable)) { item in
                    Toggle(isOn: Binding(
                        get: { !shell.hiddenItems.contains(item) },
                        set: { shell.setHidden(item, !$0) }
                    )) {
                        Label { Text(item.title) } icon: { Image(systemName: item.systemImage) }
                    }
                }
            }
            PlaybackSettingsSection()
            MultiViewSettingsSection()
            Section("Privacy") {
                Toggle("Save Quick Play history", isOn: Binding(
                    get: { history.isEnabled }, set: { history.isEnabled = $0 }
                ))
                Button("Clear Quick Play History", role: .destructive) { history.clear() }
                    .disabled(history.entries.isEmpty)
                Text("""
                    \(AppIdentifier.name) makes no network connections until you add a source or play a URL, and \
                    then connects \
                    only to the tuners, servers and URLs you choose. No analytics, no tracking.
                    """)
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }
            DiagnosticsSettingsSection()
            AboutSettingsSection()
        }
        .formStyle(.grouped)
        .frame(maxWidth: 680)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .navigationTitle("Settings")
    }

    /// Brings the requested section into view once its rows exist. Apple TV scrolls to it first (the list makes
    /// rows only near what is on screen, and focus can't go to a row that doesn't exist yet), then gives its first
    /// control focus (scrolling after that could recycle the focused row); the Mac scrolls and focuses (focus works
    /// only with keyboard navigation on); iPhone and iPad only scroll, so no keyboard comes up. Only another pane's
    /// action sets a target, never moving through the pill, so this may take focus from the pill.
    private func reveal(with proxy: ScrollViewProxy) {
        guard let target = shell.settingsTarget else { return }
        shell.settingsTarget = nil
        Task { @MainActor in
            await Task.yield()
            #if os(tvOS)
            scroll(to: target, with: proxy)
            await Task.yield()
            focusedSection = target
            // The pane that asked was just removed with the focus in it, and the focus engine may still be placing
            // focus at its default (the pill). Ask once more after it settled.
            try? await Task.sleep(for: .milliseconds(300))
            if focusedSection != target, shell.selection == .settings { focusedSection = target }
            #else
            withAnimation { scroll(to: target, with: proxy) }
            #if os(macOS)
            focusedSection = target
            #endif
            #endif
        }
    }

    private func scroll(to target: SettingsSection, with proxy: ScrollViewProxy) {
        switch target {
        case .sources: proxy.scrollTo(SettingsSection.sources, anchor: .top)
        case .home:
            // Home's rows are identified by their shelf kinds.
            if let first = homeSettings.shelves.first?.kind { proxy.scrollTo(first, anchor: .top) }
        }
    }
}

private struct PlaybackSettingsSection: View {
    @Environment(PlaybackPreferences.self) private var preferences

    var body: some View {
        @Bindable var prefs = preferences
        Section {
            ValueStepper(title: "Release the tuner after pausing for", value: $prefs.tunerReleaseMinutes,
                         range: PlaybackPreferences.tunerReleaseRange) { "\($0) min" }
            Picker("Time-shift buffer", selection: $prefs.bufferLimit) {
                Text("Limit by time").tag(PlaybackPreferences.BufferLimit.time)
                Text("Limit by size").tag(PlaybackPreferences.BufferLimit.size)
            }
            if prefs.bufferLimit == .time {
                ValueStepper(title: "Buffer length", value: $prefs.bufferMinutes, range: 5...240, step: 5) {
                    "\($0) min"
                }
            } else {
                ValueStepper(title: "Buffer size", value: $prefs.bufferMegabytes, range: 256...16_384, step: 256) {
                    "\($0) MB"
                }
            }
            Picker("Keep the buffer in", selection: $prefs.bufferStorage) {
                Text("Temporary storage").tag(PlaybackPreferences.BufferStorage.disk)
                Text("Memory").tag(PlaybackPreferences.BufferStorage.memory)
            }
        } header: {
            Text("Playback")
        } footer: {
            Text("Pausing live TV keeps recording into the time-shift buffer until the tuner is released.")
        }
    }
}
