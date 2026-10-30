//
//  HomeSettings.swift
//  Consolation
//
//  Settings › Home: which shelves Home shows and in what order, and how its Etagere lays them out. Quick Play History
//  is off by default, because stream URLs often carry tokens and Home is the screen others see most. Kept in
//  UserDefaults like other settings, as short strings (tvOS has little room).
//

import EtagereKit
import Foundation
import MediaSourceKit
import Observation

@Observable
final class HomeSettings {
    private static let storageKey = AppIdentifier.scoped("home.shelves")
    private static let alignmentKey = AppIdentifier.scoped("home.shelfAlignment")
    private static let verticalModeKey = AppIdentifier.scoped("home.verticalMode")
    private static let verticalAlignmentKey = AppIdentifier.scoped("home.verticalAlignment")
    private static let cardSizeKey = AppIdentifier.scoped("home.cardSize")
    private static let seamKey = AppIdentifier.scoped("home.showsSeam")
    private let defaults: UserDefaults

    /// Every shelf in its order, each on or off.
    private(set) var shelves: [HomeShelfSetting] {
        didSet {
            guard shelves != oldValue else { return }
            if let data = try? JSONEncoder().encode(shelves) { defaults.set(data, forKey: Self.storageKey) }
        }
    }

    /// Where each shelf's Anchor Spot sits: leading by default.
    var shelfAlignment: EtagereHorizontalAlignment {
        didSet { defaults.set(shelfAlignment.rawValue, forKey: Self.alignmentKey) }
    }

    /// Up and down turn a ring of shelves (mode 1, the default) or move a cursor between fixed shelves (mode 2).
    var verticalMode: EtagereVerticalMode {
        didSet { defaults.set(verticalMode.rawValue, forKey: Self.verticalModeKey) }
    }

    /// Where the Active Shelf sits vertically: top by default.
    var verticalAlignment: EtagereVerticalAlignment {
        didSet { defaults.set(verticalAlignment.rawValue, forKey: Self.verticalAlignmentKey) }
    }

    var cardSize: HomeCardSize {
        didSet { defaults.set(cardSize.rawValue, forKey: Self.cardSizeKey) }
    }

    /// The bar between each ring's last and first card, and in mode 1 between the last and first shelf.
    var showsSeam: Bool {
        didSet { defaults.set(showsSeam, forKey: Self.seamKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let saved = defaults.data(forKey: Self.storageKey)
            .flatMap { try? JSONDecoder().decode([HomeShelfSetting].self, from: $0) }
        shelves = Self.normalized(saved ?? HomeShelfConfiguration.default.shelves)
        shelfAlignment = Self.load(Self.alignmentKey, from: defaults) ?? .leading
        verticalMode = Self.load(Self.verticalModeKey, from: defaults) ?? .ring
        verticalAlignment = Self.load(Self.verticalAlignmentKey, from: defaults) ?? .top
        cardSize = Self.load(Self.cardSizeKey, from: defaults) ?? .medium
        showsSeam = defaults.object(forKey: Self.seamKey) as? Bool ?? true
    }

    private static func load<Value: RawRepresentable<String>>(_ key: String, from defaults: UserDefaults) -> Value? {
        guard let raw = defaults.string(forKey: key) else { return nil }
        return Value(rawValue: raw)
    }

    /// What the composer takes.
    var configuration: HomeShelfConfiguration { HomeShelfConfiguration(shelves: shelves) }

    func isEnabled(_ kind: HomeShelfKind) -> Bool {
        shelves.first { $0.kind == kind }?.isEnabled ?? false
    }

    /// Shows or hides a shelf. A library section not listed yet is pinned at the end.
    func setEnabled(_ kind: HomeShelfKind, _ isEnabled: Bool) {
        if let index = shelves.firstIndex(where: { $0.kind == kind }) {
            shelves[index].isEnabled = isEnabled
        } else if isEnabled {
            shelves.append(HomeShelfSetting(kind: kind))
        }
    }

    /// Reorders shelves, as a list's `onMove` does.
    func move(fromOffsets source: IndexSet, toOffset destination: Int) {
        let moving = source.filter(shelves.indices.contains).map { shelves[$0] }
        var remaining = shelves.indices.filter { !source.contains($0) }.map { shelves[$0] }
        let position = destination - source.filter { $0 < destination }.count
        remaining.insert(contentsOf: moving, at: min(max(position, 0), remaining.count))
        shelves = remaining
    }

    /// Removes a pinned library section from Home. Built-in shelves can only be turned off.
    func unpin(_ kind: HomeShelfKind) {
        guard case .library = kind else { return }
        shelves.removeAll { $0.kind == kind }
    }

    func reset() {
        shelves = HomeShelfConfiguration.default.shelves
    }

    /// Each shelf once, and every built-in shelf present: one a later version adds joins at its default place
    /// with its default switch.
    static func normalized(_ saved: [HomeShelfSetting]) -> [HomeShelfSetting] {
        var seen: Set<HomeShelfKind> = []
        var result = saved.filter { seen.insert($0.kind).inserted }
        let defaults = HomeShelfConfiguration.default.shelves
        for (index, setting) in defaults.enumerated() where !seen.contains(setting.kind) {
            let before = defaults[..<index].map(\.kind)
            let position = result.lastIndex { before.contains($0.kind) }.map { $0 + 1 } ?? 0
            result.insert(setting, at: position)
        }
        return result
    }
}
