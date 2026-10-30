//
//  TilePickerView.swift
//  Consolation
//
//  Add Tile and Replace: the channels and Quick Play history, each checked against the tile budget and the tuners
//  first. Channels that can't fit are greyed out with the reason; one that would take the last free tuner says so.
//  While it is open the tuners' status is polled, as on the Live TV pane.
//

import HTTPMPEG2Kit
import PlayerKit
import SwiftUI

struct TilePickerView: View {
    @Environment(PlayerSession.self) private var session
    @Environment(LiveTVModel.self) private var liveTV
    @Environment(QuickPlayHistory.self) private var history
    @Environment(\.dismiss) private var dismiss
    let request: TilePickerRequest

    @State private var admissions: [PlayingItem: PlayerKit.TileAdmission] = [:]
    @State private var isChoosing = false

    private var replacing: TileID? {
        if case .replace(let tile) = request { return tile }
        return nil
    }

    private var items: [PlayingItem] {
        liveTV.channels.map(PlayingItem.channel) + history.entries.map { .url($0.url) }
    }

    var body: some View {
        NavigationStack {
            List {
                if !liveTV.devices.isEmpty {
                    Section("Tuners") {
                        ForEach(liveTV.devices) { device in
                            Text(TunerCapacityText.summary(of: device, ours: liveTV.ours(on: device)))
                                .font(.callout)
                                .foregroundStyle(.secondary)
                        }
                    }
                }
                if !liveTV.channels.isEmpty {
                    Section("Live TV") {
                        ForEach(liveTV.channels) { row(.channel($0), title: $0.displayName) }
                    }
                }
                if !history.entries.isEmpty {
                    Section("Quick Play") {
                        ForEach(history.entries) { row(.url($0.url), title: $0.displayString) }
                    }
                }
                if items.isEmpty {
                    Text("Add a tuner in Settings or play a URL in Quick Play first.").foregroundStyle(.secondary)
                }
            }
            .navigationTitle(replacing == nil ? "Add to Multi-view" : "Replace Tile")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
            }
        }
        .frame(minWidth: 420, minHeight: 480)
        .task {
            liveTV.refresh()
            liveTV.startTunerStatus()
        }
        .task(id: items) { await checkAdmissions() }
        .onDisappear { liveTV.stopTunerStatus() }
    }

    private func row(_ item: PlayingItem, title: String) -> some View {
        let admission = admissions[item]
        return Button {
            choose(item)
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                if case .denied(let reason) = admission {
                    Text(reason).font(.caption).foregroundStyle(.secondary)
                } else if case .allowed(let cost, let warning) = admission {
                    if let warning {
                        Text(warning).font(.caption).foregroundStyle(.orange)
                    } else if cost == .sharedStream {
                        Text("Shares a tuner already in use").font(.caption).foregroundStyle(.secondary)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .disabled(isChoosing || admission?.isAllowed == false)
        .accessibilityIdentifier("tilePicker.item")
    }

    /// Asks the budget and the tuners about every item, one at a time (the tuner status is cached for a second).
    private func checkAdmissions() async {
        for item in items {
            guard !Task.isCancelled else { return }
            admissions[item] = await session.multiView.admission(for: item, replacing: replacing)
        }
    }

    private func choose(_ item: PlayingItem) {
        isChoosing = true
        let channels = liveTV.channels
        Task {
            if let replacing {
                await session.replaceTile(replacing, with: item)
            } else {
                await session.addToMultiView(item, channels: channels)
            }
            dismiss()
        }
    }
}

/// "3 of 4 tuners free (1 in use by 192.0.2.44)" for one device.
enum TunerCapacityText {
    static func summary(of device: DeviceTuners, ours: Set<String>) -> String {
        let free = device.tuners.filter { !$0.isInUse }.count
        let others = device.tuners.filter { tuner in
            tuner.isInUse && !ours.contains { $0.caseInsensitiveCompare(tuner.resource) == .orderedSame }
        }
        var text = "\(device.name): \(free) of \(device.tuners.count) tuners free"
        if !others.isEmpty {
            let holders = others.map { $0.targetIP ?? $0.vctNumber ?? $0.resource }.joined(separator: ", ")
            text += " (\(others.count) in use by \(holders))"
        }
        return text
    }
}
