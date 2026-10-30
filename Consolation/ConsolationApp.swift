//
//  ConsolationApp.swift
//  Consolation
//
//  Created by James Ranson on 4/12/26.
//

import PlaybackKit
import SwiftUI

#if os(macOS)
import AppKit

/// Quits with the last window, and turns off window tabbing (View ▸ Show Tab Bar / Show All Tabs).
final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool {
        true
    }

    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }
}
#endif

/// The tuner settings the broker follows, compared as one value.
private struct TunerSettings: Equatable {
    let reserve: Int
    let sharing: PlaybackPreferences.MultiplexSharing

    init(_ preferences: PlaybackPreferences) {
        reserve = preferences.tunerReserve
        sharing = preferences.multiplexSharing
    }
}

@main
struct ConsolationApp: App {
    @State private var app = AppModel()
    /// Bumped after a rotation or mirror change in the Capture Card menus, so their checkmarks re-read it.
    @State private var previewTransformMenuRevision = 0
    /// The whole app's phase: background only when no window is in the foreground.
    @Environment(\.scenePhase) private var scenePhase

    #if os(macOS)
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate
    #elseif os(iOS)
    @UIApplicationDelegateAdaptor(IOSAppOrientationDelegate.self) var iosOrientationDelegate
    #endif

    init() {
        AppIdentifier.logBundleIdentifier()
        // `make run-… TRACE=health` (or the scheme's environment in Xcode) prints playback health every second.
        PlaybackHealthTrace.isEnabled = ProcessInfo.processInfo.environment["CONSOLATION_HEALTH_TRACE"] == "1"
    }

    var body: some Scene {
        WindowGroup(id: AppWindow.groupID) {
            AppWindow(settings: app.pillSettings, homePositions: app.homePositions) { app.nowPlayingInfo.update() }
                .appEnvironment(app)
                // Game controllers (iPhone, iPad, Mac): attached once, by the first window.
                .task { app.controllers.start() }
                #if os(macOS)
                .frame(minWidth: 860, minHeight: 540)
                #endif
        }
        #if os(macOS)
        .windowStyle(.hiddenTitleBar)
        #endif
        #if !os(tvOS)
        // macOS menus; on iPad the same commands show in the hardware keyboard's ⌘ overlay.
        .commands {
            ShellCommands(session: app.session)
            if CaptureCardSupport.isAvailable {
                ConsolationCommands(
                    capture: app.capture,
                    previewTransformMenuRevision: previewTransformMenuRevision
                ) {
                    previewTransformMenuRevision += 1
                }
            }
        }
        #endif
        .onChange(of: TunerSettings(app.preferences), initial: true) { app.applyTunerSettings() }
        .onChange(of: scenePhase) { _, phase in
            // A direction or button held while the app leaves the foreground never repeats or sticks.
            if phase != .active { app.controllers.releaseAll() }
            #if os(iOS) || os(tvOS)
            // Streams close in the background (freeing the tuner) unless Picture in Picture shows them.
            switch phase {
            case .background: app.session.enterBackground()
            case .active: app.session.enterForeground()
            default: break
            }
            #endif
        }
    }
}
