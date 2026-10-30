//
//  SourcesSettingsSection.swift
//  Consolation
//

import HTTPMPEG2Kit
import MediaSourceKit
import SwiftUI

/// Add and remove HDHomeRun tuners by hostname or IP address, and see how each lineup Source is doing.
struct SourcesSettingsSection: View {
    @Environment(SourceStore.self) private var sources
    @Environment(SourceRegistry.self) private var registry
    @Environment(LiveTVModel.self) private var liveTV
    @Environment(LocalNetworkGate.self) private var localNetwork
    /// Settings opened at Sources (an empty Home shelf's "go") focuses the add field.
    let focus: FocusState<SettingsSection?>.Binding

    @State private var newHost = ""
    @State private var searching = false
    @State private var found: [DiscoveredTuner] = []
    @State private var searchMessage: String?

    var body: some View {
        Group {
            sourcesSection
        }
    }

    private var sourcesSection: some View {
        Section {
            ForEach(sources.hdHomeRuns) { config in
                HStack {
                    Label {
                        VStack(alignment: .leading) {
                            Text(config.displayName)
                            if config.friendlyName != nil {
                                Text(config.host).font(.caption).foregroundStyle(.secondary)
                            }
                        }
                    } icon: {
                        Image(systemName: "antenna.radiowaves.left.and.right")
                    }
                    Spacer()
                    Button("Remove", role: .destructive) {
                        sources.remove(config)
                        liveTV.refresh()
                    }
                }
            }
            // The lineup Sources' last known status, from the source registry (reading it never connects).
            ForEach(registry.liveSources, id: \.id) { source in
                LabeledContent(source.lineupSource, value: registry.status(of: source.id).settingsText)
            }
            HStack {
                TextField("Add HDHomeRun (hdhomerun.local or an IP address)", text: $newHost)
                    .autocorrectionDisabled()
                    .onSubmit(add)
                    .focused(focus, equals: .sources)
                Button("Add", action: add)
                    .disabled(newHost.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .id(SettingsSection.sources)
            if !registry.hasLiveTVSource {
                Button("Add hdhomerun.local") {
                    newHost = "hdhomerun.local"
                    add()
                }
            }
            HStack {
                // Discovery runs only when the user asks (privacy promise).
                Button(searching ? "Searching…" : "Find Tuners on This Network") { search() }
                    .disabled(searching)
                if let searchMessage { Text(searchMessage).foregroundStyle(.secondary) }
            }
            ForEach(found) { tuner in
                HStack {
                    Text("\(tuner.ipv4) · \(tuner.tunerCount.map { "\($0) tuners" } ?? "tuner")")
                    Spacer()
                    Button("Add") {
                        newHost = tuner.ipv4
                        add()
                        found.removeAll { $0.id == tuner.id }
                    }
                }
            }
        } header: {
            Text("Live TV Sources")
        } footer: {
            Text("\(AppIdentifier.name) only connects to tuners you add here.")
        }
        .task { await registry.updateStatuses() }
    }

    /// Searching and adding reach the local network: the first time, after the Local Network explanation.
    private func search() {
        localNetwork.perform(runSearch)
    }

    private func add() {
        localNetwork.perform(runAdd)
    }

    private func runSearch() {
        searching = true
        searchMessage = nil
        Task {
            do {
                let results = try await HDHomeRunDiscoveryClient().discover()
                let known = Set(sources.hdHomeRuns.compactMap(\.deviceID))
                found = results.filter { !known.contains($0.deviceID.rawValue) }
                if results.isEmpty {
                    searchMessage = "No tuners found."
                } else if found.isEmpty {
                    searchMessage = "All found tuners are added."
                }
            } catch {
                searchMessage = (error as? HDHomeRunClientError)?.message ?? error.localizedDescription
            }
            searching = false
        }
    }

    private func runAdd() {
        guard sources.addHDHomeRun(host: newHost) != nil else { return }
        newHost = ""
        liveTV.refresh()
    }
}

private extension SourceStatus {
    /// How Settings › Sources describes a lineup Source's status.
    var settingsText: String {
        switch self {
        case .unconfigured: String(localized: "Not set up")
        case .connecting: String(localized: "Connecting…")
        case .ready: String(localized: "Ready")
        case .authRequired: String(localized: "Sign in again")
        case .localNetworkDenied: String(localized: "Local Network access is off")
        case .unreachable(let reason): reason.isEmpty ? String(localized: "Can't reach the tuner") : reason
        case .degraded(let reason): reason
        }
    }
}
