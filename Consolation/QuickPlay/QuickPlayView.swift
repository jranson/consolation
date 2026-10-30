//
//  QuickPlayView.swift
//  Consolation
//
//  Play any URL (HLS, DASH, MP4, raw MPEG-TS), with a history of what played.
//

import SwiftUI

struct QuickPlayView: View {
    @Environment(QuickPlayHistory.self) private var history
    @Environment(PlayerSession.self) private var session
    @Environment(ShellModel.self) private var shell
    @Environment(LocalNetworkGate.self) private var localNetwork
    @Environment(\.shellLayout) private var layout

    @State private var urlText = ""
    @State private var inputError: String?
    @State private var confirmClear = false
    @FocusState private var fieldFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            Text("Quick Play").font(.largeTitle.bold())
            entryRow
            if let inputError {
                Label(inputError, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
            }
            historySection
        }
        .padding(layout.contentPadding)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        // Not while the pill has focus: on Apple TV, moving through the pill must not pull focus in here.
        .onAppear { if !shell.pillHasFocus { fieldFocused = true } }
        // Mac: → or Return in the pill.
        .onChange(of: shell.contentFocusRequest) { fieldFocused = true }
        .localNetworkExplanation(localNetwork)
        .confirmationDialog("Clear Quick Play history?", isPresented: $confirmClear) {
            Button("Clear History", role: .destructive) { history.clear() }
        }
    }

    private var entryRow: some View {
        HStack(spacing: 12) {
            TextField("Stream URL (HLS, DASH, MP4 or MPEG-TS)", text: $urlText)
                #if !os(tvOS)
                .textFieldStyle(.roundedBorder)
                #endif
                .focused($fieldFocused)
                .autocorrectionDisabled()
                .onSubmit(play)
                #if os(iOS)
                .textInputAutocapitalization(.never)
                .keyboardType(.URL)
                #endif
            #if !os(tvOS)
            PasteButton(payloadType: String.self) { strings in
                if let first = strings.first { urlText = first }
            }
            .labelStyle(.iconOnly)
            #endif
            Button("Play", action: play)
                .buttonStyle(.borderedProminent)
                .disabled(urlText.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        #if !os(tvOS)
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            urlText = url.absoluteString
            return true
        }
        #endif
    }

    @ViewBuilder private var historySection: some View {
        HStack {
            Text("History").font(.title3.bold())
            Spacer()
            #if !os(tvOS)
            if !history.entries.isEmpty {
                Button("Clear…") { confirmClear = true }
            }
            #endif
        }
        if !history.isEnabled {
            Text("History is off. Turn it on in Settings › Privacy.").foregroundStyle(.secondary)
        } else if history.entries.isEmpty {
            Text("URLs you play appear here.").foregroundStyle(.secondary)
        } else {
            List {
                ForEach(history.entries) { entry in
                    QuickPlayHistoryRow(entry: entry) { start(entry.url) } onRemove: { history.remove(entry) }
                        .contextMenu {
                            Button("Play") { start(entry.url) }
                            if session.isActive {
                                Button("Add to Multi-view") { addToMultiView(entry.url) }
                            }
                            #if os(tvOS)
                            // Apple TV: the row is one full-width button, so down from the URL field lands on the
                            // history; removing an entry is in this long-press menu.
                            Button("Remove from History", role: .destructive) { history.remove(entry) }
                            #endif
                        }
                }
                #if os(tvOS)
                // Apple TV: after the history, so the field's down move reaches the entries first.
                Button("Clear History…") { confirmClear = true }
                #endif
            }
            .listStyle(.plain)
        }
    }

    private func play() {
        let text = urlText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let url = URL(string: text), let scheme = url.scheme?.lowercased(),
              ["http", "https", "file"].contains(scheme), url.host() != nil || scheme == "file" else {
            inputError = "That doesn't look like an http, https or file URL."
            return
        }
        inputError = nil
        start(url)
    }

    private func addToMultiView(_ url: URL) {
        localNetwork.perform(for: url) {
            Task {
                await session.addToMultiView(.url(url))
                shell.selection = .nowPlaying
            }
        }
    }

    /// A local-network URL waits for the Local Network explanation the first time.
    private func start(_ url: URL) {
        localNetwork.perform(for: url) {
            session.play(url)
            shell.selection = .nowPlaying
        }
    }
}

private struct QuickPlayHistoryRow: View {
    let entry: QuickPlayEntry
    let onPlay: () -> Void
    let onRemove: () -> Void

    @State private var expanded = false

    var body: some View {
        #if os(tvOS)
        Button(action: onPlay) {
            Label {
                VStack(alignment: .leading, spacing: 2) {
                    Text(entry.displayString).lineLimit(1).truncationMode(.middle)
                    Text(entry.lastPlayed, style: .relative).font(.caption).foregroundStyle(.secondary)
                }
            } icon: {
                Image(systemName: "play.circle")
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .accessibilityIdentifier("quickPlay.historyItem")
        #else
        rowWithButtons
        #endif
    }

    private var rowWithButtons: some View {
        HStack(spacing: 12) {
            Button(action: onPlay) {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(expanded ? entry.url.absoluteString : entry.displayString)
                            .lineLimit(expanded ? nil : 1)
                            .truncationMode(.middle)
                        Text(entry.lastPlayed, style: .relative).font(.caption).foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "play.circle")
                }
            }
            .buttonStyle(.plain)
            Spacer()
            if entry.url.query() != nil {
                Button(expanded ? "Hide" : "Show Full URL") { expanded.toggle() }
                    .buttonStyle(.borderless)
            }
            Button(role: .destructive, action: onRemove) {
                Image(systemName: "minus.circle")
            }
            .buttonStyle(.borderless)
            .help("Remove from history")
            .accessibilityLabel("Remove from history")
        }
        .padding(.vertical, 4)
    }
}
