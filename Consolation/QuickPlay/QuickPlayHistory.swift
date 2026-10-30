//
//  QuickPlayHistory.swift
//  Consolation
//
//  URLs played from Quick Play. Stays on this device, can be turned off and cleared, and is never logged.
//

import Foundation
import Observation

struct QuickPlayEntry: Codable, Hashable, Identifiable {
    let url: URL
    var lastPlayed: Date

    var id: URL { url }

    /// The URL without its query string, which can carry tokens. Shown until the user expands the entry.
    var displayString: String {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false) else { return url.absoluteString }
        let hadQuery = parts.query != nil
        parts.query = nil
        parts.fragment = nil
        let base = parts.string ?? url.absoluteString
        return hadQuery ? base + "?…" : base
    }
}

@Observable
final class QuickPlayHistory {
    static let maxEntries = 100

    private static let documentName = "quick-play-history"
    /// Where builds before per-platform storage kept the entries.
    private static let legacyEntriesKey = AppIdentifier.scoped("quickPlay.history")
    private static let enabledKey = AppIdentifier.scoped("quickPlay.saveHistory")
    private let documents: any DocumentStore
    private let defaults: UserDefaults

    private(set) var entries: [QuickPlayEntry] = []

    /// Settings › Privacy › "Save Quick Play history". Turning it off clears the history.
    var isEnabled: Bool {
        didSet {
            defaults.set(isEnabled, forKey: Self.enabledKey)
            if !isEnabled { clear() }
        }
    }

    init(documents: any DocumentStore = DocumentStores.platformDefault(), defaults: UserDefaults = .standard) {
        self.documents = documents
        self.defaults = defaults
        isEnabled = defaults.object(forKey: Self.enabledKey) as? Bool ?? true
        documents.migrate(named: Self.documentName, fromDefaultsKey: Self.legacyEntriesKey, in: defaults) {
            $0 as? Data
        }
        entries = documents.load([QuickPlayEntry].self, named: Self.documentName) ?? []
    }

    /// Records a URL once it actually played (first frame), moving it to the top.
    func record(_ url: URL, at date: Date = .now) {
        guard isEnabled else { return }
        entries.removeAll { $0.url == url }
        entries.insert(QuickPlayEntry(url: url, lastPlayed: date), at: 0)
        if entries.count > Self.maxEntries { entries.removeLast(entries.count - Self.maxEntries) }
        save()
    }

    func remove(_ entry: QuickPlayEntry) {
        entries.removeAll { $0.id == entry.id }
        save()
    }

    func clear() {
        entries.removeAll()
        save()
    }

    private func save() {
        documents.save(entries.isEmpty ? nil : entries, named: Self.documentName)
    }
}
