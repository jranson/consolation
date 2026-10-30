//
//  AppFavorites.swift
//  Consolation
//
//  Favorites kept by the app (heart.fill), on top of the device's read-only favorites (lock.heart.fill).
//  When a channel is a favorite on the device too, the device wins and the app's copy is dropped.
//

import Foundation
import Observation

@Observable
final class AppFavorites {
    private static let documentName = "favorites"
    /// Where builds before per-platform storage kept the keys.
    private static let legacyKey = AppIdentifier.scoped("liveTV.appFavorites")
    private let documents: any DocumentStore

    /// Channel keys (e.g. "hdhrch:Antenna:9.1") the user marked in the app.
    private(set) var keys: Set<String>

    init(documents: any DocumentStore = DocumentStores.platformDefault(), defaults: UserDefaults = .standard) {
        self.documents = documents
        documents.migrate(named: Self.documentName, fromDefaultsKey: Self.legacyKey, in: defaults) { legacy in
            (legacy as? [String]).flatMap { try? JSONEncoder().encode($0) }
        }
        keys = Set(documents.load([String].self, named: Self.documentName) ?? [])
    }

    func contains(_ key: String) -> Bool { keys.contains(key) }

    func toggle(_ key: String) {
        if keys.contains(key) { keys.remove(key) } else { keys.insert(key) }
        save()
    }

    /// Drops app favorites that are also device favorites, so `lock.heart.fill` always means "on the device".
    /// Call on every lineup load. Returns the keys that were dropped.
    @discardableResult
    func reconcile(deviceFavorites: Set<String>) -> Set<String> {
        let overlap = keys.intersection(deviceFavorites)
        guard !overlap.isEmpty else { return [] }
        keys.subtract(overlap)
        save()
        return overlap
    }

    /// The mark a channel shows, given whether the device marks it.
    func mark(for key: String, isDeviceFavorite: Bool) -> FavoriteMark {
        if isDeviceFavorite { return .device }
        return keys.contains(key) ? .app : .none
    }

    private func save() {
        documents.save(keys.isEmpty ? nil : keys.sorted(), named: Self.documentName)
    }
}
