//
//  QuickPlayHistory.swift
//  Consolation
//
//  URLs played from Quick Play. Stays on this device, can be turned off and cleared, and is never logged. A local
//  file's entry keeps a bookmark, so the sandboxed app can read the file again in a later run.
//

import Foundation
import Observation

struct QuickPlayEntry: Codable, Hashable, Identifiable {
    let url: URL
    var lastPlayed: Date
    /// For a local file the user chose: reopens it in a later run (`LocalFileAccess`).
    var bookmark: Data?

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
    /// Paths of the local files this run can read, so access to each starts once.
    @ObservationIgnored private var accessedPaths: Set<String> = []

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
        restoreFileAccess()
    }

    /// Records a URL once it actually played (first frame), moving it to the top. A local file keeps a bookmark made
    /// now, while the app can read it, or the one it had.
    func record(_ url: URL, at date: Date = .now) {
        guard isEnabled else { return }
        let previous = entries.first { $0.url == url }
        entries.removeAll { $0.url == url }
        let bookmark = url.isFileURL ? LocalFileAccess.bookmark(for: url) ?? previous?.bookmark : nil
        entries.insert(QuickPlayEntry(url: url, lastPlayed: date, bookmark: bookmark), at: 0)
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

    /// Starts access to a local file the user picked or dropped, once per run. Works with history off too.
    func allowReading(_ url: URL) {
        guard url.isFileURL, accessedPaths.insert(url.path(percentEncoded: false)).inserted else { return }
        LocalFileAccess.startAccess(url)
    }

    private func save() {
        documents.save(entries.isEmpty ? nil : entries, named: Self.documentName)
    }

    // MARK: - Local files

    private struct SavedBookmark: Sendable {
        let url: URL
        let bookmark: Data
    }

    /// Restores access to the history's local files off the main actor, so they play again from Quick Play or Home.
    private func restoreFileAccess() {
        let saved = entries.compactMap { entry in entry.bookmark.map { SavedBookmark(url: entry.url, bookmark: $0) } }
        guard !saved.isEmpty else { return }
        Task { [weak self] in
            let restored = await Self.restore(saved)
            self?.applyRestored(restored)
        }
    }

    @concurrent private static func restore(_ saved: [SavedBookmark]) async -> [URL: LocalFileAccess.Restored] {
        var restored: [URL: LocalFileAccess.Restored] = [:]
        for entry in saved {
            if let access = LocalFileAccess.restore(entry.bookmark) { restored[entry.url] = access }
        }
        return restored
    }

    /// Notes which files this run can read, and moves an entry whose file moved (a stale bookmark) to its new place.
    private func applyRestored(_ restored: [URL: LocalFileAccess.Restored]) {
        var changed = false
        for (saved, access) in restored {
            accessedPaths.insert(access.url.path(percentEncoded: false))
            guard let refreshed = access.refreshedBookmark,
                  let index = entries.firstIndex(where: { $0.url == saved }) else { continue }
            let moved = access.url.standardizedFileURL
            if moved != saved, entries.contains(where: { $0.url == moved }) {
                entries.remove(at: index)
            } else {
                entries[index] = QuickPlayEntry(url: moved, lastPlayed: entries[index].lastPlayed, bookmark: refreshed)
            }
            changed = true
        }
        if changed { save() }
    }
}
