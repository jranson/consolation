//
//  TVFocusCheck.swift
//  Consolation
//
//  Apple TV: whether anything in the app has focus. With nothing focused, Back goes to the system and leaves the
//  app, so the shell and the player use this to put focus somewhere when it has been lost.
//

#if os(tvOS)
import UIKit

enum TVFocusCheck {
    /// Whether any of the app's windows has a focused item.
    static var appHasFocus: Bool {
        UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .flatMap(\.windows)
            .contains { UIFocusSystem.focusSystem(for: $0)?.focusedItem != nil }
    }
}
#endif
