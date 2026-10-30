//
//  HomeNotice.swift
//  Consolation
//
//  The short messages Home shows in an alert, and where the system's Local Network setting is.
//

import Foundation
#if os(iOS)
import UIKit
#endif

/// A short message Home shows in an alert.
struct HomeNotice: Identifiable, Equatable {
    let id = UUID()
    let title: String
    let message: String

    /// "Go" on a card that no source has now.
    static func unavailable(_ cardTitle: String) -> HomeNotice {
        HomeNotice(title: String(localized: "Can't Play \(cardTitle)"),
                   message: String(localized: """
                       Its source didn't answer, or doesn't have it any more. Check the source in Settings › Sources.
                       """))
    }

    /// Apple TV: Local Network access is off, and an app can't open Settings there.
    static var localNetwork: HomeNotice {
        HomeNotice(title: String(localized: "Local Network Access Is Off"),
                   message: String(localized: """
                       To reach your tuners, open Settings on this Apple TV, choose Privacy & Security › Local \
                       Network, and turn on \(AppIdentifier.name).
                       """))
    }
}

/// The system's Local Network setting for this app, where an app can open it: the privacy pane in System Settings
/// on the Mac, the app's own page in Settings on iPhone and iPad (it has the Local Network switch). Nil on Apple TV.
enum LocalNetworkSettings {
    static var url: URL? {
        #if os(macOS)
        URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_LocalNetwork")
        #elseif os(iOS)
        URL(string: UIApplication.openSettingsURLString)
        #else
        nil
        #endif
    }
}
