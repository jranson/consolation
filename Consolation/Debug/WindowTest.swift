//
//  WindowTest.swift
//  Consolation
//
//  Debug builds on Mac and iPad: `-ConsolationWindowTest YES` (with a channel playing) opens a second window, shows the
//  player there, then back in the first, and logs at each step which window has the video and whether playback
//  kept the same engine, so moving the video between windows can be checked without driving the UI.
//      open build/Consolation.app --args -ConsolationPlayChannel 9.1 -ConsolationWindowTest YES
//

import os
import PlaybackKit
import SwiftUI

#if DEBUG && !os(tvOS)
/// The shells of the open windows, in the order they opened (debug builds only).
enum DebugWindows {
    @MainActor static var shells: [ShellModel] = []
}

enum WindowTest {
    @MainActor
    static func run(session: PlayerSession, openWindow: OpenWindowAction) async {
        let log = Logger(subsystem: AppIdentifier.bundleID, category: "Debug")
        for _ in 0..<200 where session.engine?.state != .playing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        guard let first = DebugWindows.shells.first, let engine = session.engine else { return }
        let identity = ObjectIdentifier(engine as AnyObject)
        func report(_ step: String) {
            let owner = DebugWindows.shells.firstIndex { $0.id == session.videoWindow }.map { "window \($0 + 1)" }
            let shown = (session.engine as? any LivePlaybackControlling)?.diagnostics.framesShown ?? -1
            let same = session.engine.map { ObjectIdentifier($0 as AnyObject) == identity } ?? false
            let line = "Window test, \(step): \(DebugWindows.shells.count) windows, video in \(owner ?? "none"), "
                + "same engine \(same), frames shown \(shown)"
            log.notice("\(line, privacy: .public)")
        }
        report("start")
        openWindow(id: AppWindow.groupID)
        try? await Task.sleep(for: .seconds(3))
        report("second window opened")
        guard DebugWindows.shells.count > 1 else { return }
        DebugWindows.shells[1].selection = .nowPlaying
        try? await Task.sleep(for: .seconds(4))
        report("player opened in window 2")
        first.selection = .liveTV
        try? await Task.sleep(for: .seconds(3))
        report("window 1 went to Live TV")
        first.selection = .nowPlaying
        try? await Task.sleep(for: .seconds(4))
        report("player opened in window 1 again")
    }
}
#endif
