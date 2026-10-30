//
//  PillSettings.swift
//  Consolation
//
//  The sidebar items the user hid in Settings: one setting for the whole app, shared by every window's shell.
//

import Foundation
import Observation

@Observable
final class PillSettings {
    private static let hiddenKey = AppIdentifier.scoped("shell.hiddenItems")

    private let defaults: UserDefaults

    /// Items the user hid in Settings.
    private(set) var hiddenItems: Set<ShellItem> {
        didSet { defaults.set(hiddenItems.map(\.rawValue).sorted(), forKey: Self.hiddenKey) }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hidden = (defaults.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(ShellItem.init(rawValue:))
        hiddenItems = Set(hidden.filter(\.isHideable))
    }

    /// The items the pill shows, in order.
    var visibleItems: [ShellItem] {
        ShellItem.availableCases.filter { !hiddenItems.contains($0) }
    }

    func setHidden(_ item: ShellItem, _ hidden: Bool) {
        guard item.isHideable else { return }
        if hidden { hiddenItems.insert(item) } else { hiddenItems.remove(item) }
    }
}
