//
//  PlaybackDisplayWakeLock.swift
//  Consolation
//
//  Keeps the display awake while video plays (from Consolation, with tvOS added).
//

import Foundation
#if os(iOS) || os(tvOS)
import UIKit
#endif

enum PlaybackDisplayWakeLock {
    #if os(macOS)
    private static var activity: NSObjectProtocol?
    #endif

    static func setActive(_ active: Bool) {
        #if os(iOS) || os(tvOS)
        UIApplication.shared.isIdleTimerDisabled = active
        #elseif os(macOS)
        if active {
            guard activity == nil else { return }
            activity = ProcessInfo.processInfo.beginActivity(
                options: [.idleDisplaySleepDisabled, .idleSystemSleepDisabled],
                reason: AppIdentifier.scoped("playback")
            )
        } else if let current = activity {
            ProcessInfo.processInfo.endActivity(current)
            activity = nil
        }
        #endif
    }
}
