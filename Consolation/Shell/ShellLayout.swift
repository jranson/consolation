//
//  ShellLayout.swift
//  Consolation
//
//  Layout chosen from the window's width, never from the device type or orientation, so a folding iPhone Duo or a
//  resized iPad window just switches layout (and playback never restarts).
//

import SwiftUI

enum ShellLayout: Equatable {
    /// Under about 500 pt: iPhone, folded iPhone Duo, narrow iPad split views. The pill moves to the bottom.
    case compact
    /// Mac windows, iPad, unfolded iPhone Duo.
    case regular
    /// Apple TV: everything is seen from across the room.
    case television

    static let compactWidth: CGFloat = 500

    static func forWidth(_ width: CGFloat) -> ShellLayout {
        #if os(tvOS)
        return .television
        #else
        return width < compactWidth ? .compact : .regular
        #endif
    }

    /// Space the pill takes at the leading edge (regular) or the bottom (compact).
    var pillInset: CGFloat {
        switch self {
        case .compact: 0
        case .regular: 76
        case .television: 90
        }
    }

    var contentPadding: CGFloat {
        switch self {
        case .compact: 16
        case .regular: 32
        case .television: 60
        }
    }

    var pillIconSize: CGFloat { self == .television ? 30 : 17 }
    var pillButtonSize: CGFloat { self == .television ? 76 : 40 }
}

private struct ShellLayoutKey: EnvironmentKey {
    static let defaultValue = ShellLayout.regular
}

extension EnvironmentValues {
    var shellLayout: ShellLayout {
        get { self[ShellLayoutKey.self] }
        set { self[ShellLayoutKey.self] = newValue }
    }
}
