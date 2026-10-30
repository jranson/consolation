//
//  SourceStore.swift
//  Consolation
//
//  The sources the user added. Nothing touches the network until at least one source exists (privacy promise).
//

import Foundation
import MediaSourceKit
import Observation

/// A user-added HDHomeRun, as entered. The device ID, name and lineup Source are filled in after the first
/// successful contact.
struct HDHomeRunSourceConfig: Codable, Hashable, Identifiable {
    var id: UUID
    /// What the user typed: "hdhomerun.local", "hdhr-1234abcd.local" or an IP address.
    var host: String
    var deviceID: String?
    var friendlyName: String?
    /// `lineup_status.json` `Source` (`Antenna`, `Cable`): which logical live source the tuner feeds.
    var lineupSource: String?

    init(host: String, id: UUID = UUID()) {
        self.id = id
        self.host = host
    }

    var displayName: String { friendlyName ?? host }
}

/// A user-added Bullpen server: its identity (`bullpen:<uuid>`, from `GET /api/v1/server`), the address it was
/// reached at, and its name. No secrets.
struct BullpenSourceConfig: Codable, Hashable, Identifiable {
    /// The server's `SourceID` raw value, so a server reached at a new address is still one source.
    var id: String
    /// The base URL, ending in `/` (`http://192.0.2.10:7992/`).
    var address: String
    var name: String

    var sourceID: SourceID { SourceID(raw: id) }
}

/// A user-added Plex Media Server: its identity (`plex:<machineIdentifier>`), address and name. Its token, when it
/// has one, is in the Keychain (`SourceCredentials`), never here.
struct PlexSourceConfig: Codable, Hashable, Identifiable {
    var id: String
    /// The base URL (`http://192.0.2.10:32400/`).
    var address: String
    var name: String
    /// False when the server allows this device's network without a token.
    var usesToken: Bool

    var sourceID: SourceID { SourceID(raw: id) }
}

@Observable
final class SourceStore {
    private static let documentName = "sources-hdhomerun"
    private static let bullpenDocumentName = "sources-bullpen"
    private static let plexDocumentName = "sources-plex"
    /// Where builds before per-platform storage kept the list.
    private static let legacyKey = AppIdentifier.scoped("sources.hdhomerun")
    private let documents: any DocumentStore

    private(set) var hdHomeRuns: [HDHomeRunSourceConfig] = []
    /// Bullpen servers, in the order they were added.
    private(set) var bullpens: [BullpenSourceConfig] = []
    /// Plex servers, in the order they were added.
    private(set) var plexServers: [PlexSourceConfig] = []

    init(documents: any DocumentStore = DocumentStores.platformDefault(), defaults: UserDefaults = .standard) {
        self.documents = documents
        documents.migrate(named: Self.documentName, fromDefaultsKey: Self.legacyKey, in: defaults) { $0 as? Data }
        hdHomeRuns = documents.load([HDHomeRunSourceConfig].self, named: Self.documentName) ?? []
        bullpens = documents.load([BullpenSourceConfig].self, named: Self.bullpenDocumentName) ?? []
        plexServers = documents.load([PlexSourceConfig].self, named: Self.plexDocumentName) ?? []
    }

    var hasLiveTVSource: Bool { !hdHomeRuns.isEmpty }

    /// Adds a host unless it's already there (case-insensitive). Returns the stored config.
    @discardableResult
    func addHDHomeRun(host rawHost: String) -> HDHomeRunSourceConfig? {
        let host = rawHost.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !host.isEmpty else { return nil }
        if let existing = hdHomeRuns.first(where: { $0.host.caseInsensitiveCompare(host) == .orderedSame }) {
            return existing
        }
        let config = HDHomeRunSourceConfig(host: host)
        hdHomeRuns.append(config)
        save()
        return config
    }

    func update(_ config: HDHomeRunSourceConfig) {
        guard let index = hdHomeRuns.firstIndex(where: { $0.id == config.id }) else { return }
        hdHomeRuns[index] = config
        save()
    }

    func remove(_ config: HDHomeRunSourceConfig) {
        hdHomeRuns.removeAll { $0.id == config.id }
        save()
    }

    /// Adds a server, or updates the address and name of one already added (the same server ID).
    func addBullpen(_ config: BullpenSourceConfig) {
        if let index = bullpens.firstIndex(where: { $0.id == config.id }) {
            guard bullpens[index] != config else { return }
            bullpens[index] = config
        } else {
            bullpens.append(config)
        }
        saveBullpens()
    }

    func remove(_ config: BullpenSourceConfig) {
        bullpens.removeAll { $0.id == config.id }
        saveBullpens()
    }

    /// Adds a server, or updates one already added (the same machine identifier).
    func addPlex(_ config: PlexSourceConfig) {
        if let index = plexServers.firstIndex(where: { $0.id == config.id }) {
            guard plexServers[index] != config else { return }
            plexServers[index] = config
        } else {
            plexServers.append(config)
        }
        savePlexServers()
    }

    func remove(_ config: PlexSourceConfig) {
        plexServers.removeAll { $0.id == config.id }
        savePlexServers()
    }

    private func savePlexServers() {
        documents.save(plexServers.isEmpty ? nil : plexServers, named: Self.plexDocumentName)
    }

    private func saveBullpens() {
        documents.save(bullpens.isEmpty ? nil : bullpens, named: Self.bullpenDocumentName)
    }

    private func save() {
        documents.save(hdHomeRuns.isEmpty ? nil : hdHomeRuns, named: Self.documentName)
    }
}
