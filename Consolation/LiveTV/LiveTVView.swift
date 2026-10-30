//
//  LiveTVView.swift
//  Consolation
//
//  The Live TV pane: source banner, the "View:" pill, and the channel column next to the (future) guide grid.
//

import SwiftUI

struct LiveTVView: View {
    @Environment(LiveTVModel.self) private var model
    @Environment(PlaybackPreferences.self) private var preferences
    @Environment(PlayerSession.self) private var session
    @Environment(ShellModel.self) private var shell
    @Environment(\.shellLayout) private var layout

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            header
            LiveTVStatusBanner(status: model.status) { shell.selection = .settings }
            if layout == .compact {
                compactBody
            } else {
                wideBody
            }
        }
        .padding(layout.contentPadding)
        // Apple TV: moving through the pill (selection follows focus) never starts a refresh.
        .task { await model.paneAppeared(after: ShellModel.paneRefreshDelay) }
        .onDisappear { model.stopTunerStatus() }
        .onChange(of: preferences.showsATSC3Channels, initial: true) { _, shows in model.showsATSC3 = shows }
    }

    @ViewBuilder private var header: some View {
        if layout == .compact {
            VStack(alignment: .leading, spacing: 10) {
                Text("Live TV").font(.largeTitle.bold())
                LiveTVViewPill()
            }
        } else {
            HStack(alignment: .firstTextBaseline) {
                Text("Live TV").font(.largeTitle.bold())
                Spacer()
                LiveTVViewPill()
            }
        }
    }

    /// Channel column beside the guide grid (a time header over "No Grid Data Available" until a guide exists).
    private var wideBody: some View {
        HStack(alignment: .top, spacing: 0) {
            channelColumn
                .frame(width: layout == .television ? 620 : 300)
            Divider()
            VStack(spacing: 0) {
                GuideTimeHeader()
                Divider()
                Spacer()
                Text("No Grid Data Available").font(.title3).foregroundStyle(.secondary)
                Spacer()
                if !model.tuners.isEmpty {
                    TunerUsagePanel(devices: model.devices, ours: model.ours(on:))
                        .padding(16)
                }
            }
            .frame(maxWidth: .infinity)
        }
        .background(.background.secondary, in: .rect(cornerRadius: 12))
    }

    /// Narrow screens: the channel list takes the full width; the grid note and tuners sit below it.
    private var compactBody: some View {
        VStack(alignment: .leading, spacing: 8) {
            channelColumn
                .background(.background.secondary, in: .rect(cornerRadius: 12))
            Text("No Grid Data Available").font(.footnote).foregroundStyle(.secondary)
            if !model.tuners.isEmpty {
                TunerUsagePanel(devices: model.devices, ours: model.ours(on:))
            }
        }
    }

    private var channelColumn: some View {
        let addToMultiView: ((LiveChannel) -> Void)? = session.isActive ? { self.addToMultiView($0) } : nil
        return ChannelColumn(channels: model.visibleChannels, emptyMessage: emptyMessage,
                      onPlay: { channel in
                          session.play(channel, within: model.visibleChannels)
                          shell.selection = .nowPlaying
                      },
                      onToggleFavorite: { model.toggleFavorite($0) },
                      onAddToMultiView: addToMultiView)
    }

    /// While something plays: the channel joins it as a multi-view tile, and the player opens.
    private func addToMultiView(_ channel: LiveChannel) {
        let channels = model.visibleChannels
        Task {
            await session.addToMultiView(.channel(channel), channels: channels)
            shell.selection = .nowPlaying
        }
    }

    private var emptyMessage: String? {
        guard case .ready = model.status, model.visibleChannels.isEmpty else { return nil }
        return model.viewMode == .favoritesOnly ? "No favorites yet" : "No channels"
    }
}

/// "View:  ♥ Only | ♥ First | By Channel"
struct LiveTVViewPill: View {
    @Environment(LiveTVModel.self) private var model

    var body: some View {
        @Bindable var model = model
        HStack(spacing: 8) {
            Text("View:").foregroundStyle(.secondary)
            Picker("View", selection: $model.viewMode) {
                ForEach(LiveTVViewMode.allCases) { mode in
                    // Segmented controls drop images (a Label's icon or an inline SF Symbol) on every platform,
                    // so the heart is a text character here.
                    Text(mode.showsHeart ? "\u{2665} \(mode.label)" : mode.label).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()
        }
    }
}

struct LiveTVStatusBanner: View {
    let status: LiveTVSourceStatus
    let onConfigure: () -> Void

    var body: some View {
        if let message = status.bannerMessage {
            HStack(spacing: 12) {
                Image(systemName: status.bannerSymbol)
                Text(message)
                Spacer()
                if status.offersConfigure {
                    Button("Configure", action: onConfigure)
                }
            }
            .padding(12)
            .background(.orange.opacity(0.15), in: .rect(cornerRadius: 10))
        } else if let detail = status.readyDetail {
            Text(detail).font(.callout).foregroundStyle(.secondary)
        }
    }
}

struct ChannelColumn: View {
    let channels: [LiveChannel]
    let emptyMessage: String?
    let onPlay: (LiveChannel) -> Void
    let onToggleFavorite: (LiveChannel) -> Void
    /// While something plays: adds the channel as a multi-view tile.
    var onAddToMultiView: ((LiveChannel) -> Void)?
    @Environment(ShellModel.self) private var shell
    /// The channel row with focus, and the last one that had it, for the pill handing focus back (Apple TV).
    @FocusState private var focusedChannel: String?
    @State private var lastFocusedChannel: String?

    var body: some View {
        if let emptyMessage {
            VStack(spacing: 8) {
                Spacer()
                Image(systemName: "heart").font(.title)
                Text(emptyMessage).foregroundStyle(.secondary)
                Spacer()
            }
            .frame(maxWidth: .infinity)
        } else {
            List(channels) { channel in
                // A button, not a tap gesture, so the row takes focus on Apple TV and keyboard focus elsewhere.
                Button { onPlay(channel) } label: {
                    ChannelRow(channel: channel).contentShape(Rectangle())
                }
                .channelRowButtonStyle()
                .focused($focusedChannel, equals: channel.id)
                .contextMenu { favoriteMenu(for: channel) }
            }
            .listStyle(.plain)
            .onChange(of: focusedChannel) { _, channel in
                if let channel { lastFocusedChannel = channel }
            }
            // The pill handing focus back (Back or Select in it on Apple TV): the row last focused, else the first.
            .onChange(of: shell.contentFocusRequest) {
                let previous = lastFocusedChannel.flatMap { id in channels.first { $0.id == id }?.id }
                focusedChannel = previous ?? channels.first?.id
            }
            #if !os(tvOS)
            .scrollContentBackground(.hidden)
            #endif
        }
    }

    @ViewBuilder private func favoriteMenu(for channel: LiveChannel) -> some View {
        Button("Play") { onPlay(channel) }
        if let simulcast = channel.simulcast, let match = channels.first(where: { $0.guideNumber == simulcast }) {
            Button("Watch \(match.displayName) (with sound)") { onPlay(match) }
        }
        if let onAddToMultiView {
            Button("Add to Multi-view") { onAddToMultiView(channel) }
        }
        switch channel.favorite {
        case .device:
            Text("Favorite on the HDHomeRun")
        case .app:
            Button("Remove from Favorites") { onToggleFavorite(channel) }
        case .none:
            Button("Add to Favorites") { onToggleFavorite(channel) }
        }
    }
}

struct ChannelRow: View {
    let channel: LiveChannel

    var body: some View {
        HStack(spacing: 10) {
            Text(channel.guideNumber).font(.body.monospacedDigit().bold())
                .lineLimit(1)
                .frame(minWidth: 52, alignment: .leading)
                .fixedSize()
            Text(channel.name).lineLimit(1)
            Spacer()
            if channel.isProtected {
                Label("Protected (DRM)", systemImage: "lock.fill").font(.caption).foregroundStyle(.secondary)
            } else if channel.isATSC3 {
                Label("ATSC 3.0 · no audio", systemImage: "speaker.slash").font(.caption).foregroundStyle(.secondary)
            }
            if channel.isHD {
                Text("HD").font(.caption2.bold()).fixedSize().padding(.horizontal, 4).overlay(
                    RoundedRectangle(cornerRadius: 3).stroke(.secondary)
                )
            }
            Image(systemName: channel.favorite.systemImage ?? "heart")
                .foregroundStyle(channel.favorite.isFavorite ? AnyShapeStyle(.pink) : AnyShapeStyle(.clear))
                .help(channel.favorite == .device ? "Favorite on the HDHomeRun" : "Favorite")
        }
        .padding(.vertical, 4)
        .accessibilityElement(children: .combine)
    }
}

private extension View {
    /// Apple TV keeps the system's focus highlight on rows; elsewhere the row looks like plain text.
    @ViewBuilder
    func channelRowButtonStyle() -> some View {
        #if os(tvOS)
        self
        #else
        buttonStyle(.plain)
        #endif
    }
}
