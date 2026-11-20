//
//  PillSettings.swift
//  Consolation
//
//  The sidebar items the user hid in Settings, and what the panes have to show (`ShellContent`): one setting for the
//  whole app, shared by every window's shell.
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

    /// Reads what the panes have to show from the app's models (`AppModel` attaches it). Reading it inside a view or
    /// an observation tracks those models, so the menu follows tuners and servers being added and playback.
    @ObservationIgnored var readContent: () -> ShellContent = { .everything }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        let hidden = (defaults.stringArray(forKey: Self.hiddenKey) ?? []).compactMap(ShellItem.init(rawValue:))
        hiddenItems = Set(hidden.filter(\.isHideable))
    }

    var content: ShellContent { readContent() }

    /// The items the pill shows, in order: those this device has, not hidden, and with something to show.
    var visibleItems: [ShellItem] {
        let content = content
        return ShellItem.availableCases.filter { !hiddenItems.contains($0) && content.hasContent($0) }
    }

    func setHidden(_ item: ShellItem, _ hidden: Bool) {
        guard item.isHideable else { return }
        if hidden { hiddenItems.insert(item) } else { hiddenItems.remove(item) }
    }
}
