//
//  DebugLaunchActions.swift
//  Consolation
//
//  Debug builds only: launch arguments that drive the app for testing and screenshots, e.g.
//      open build/Consolation.app --args -ConsolationAddSource hdhomerun.local -ConsolationPlayChannel 9.1
//      open build/Consolation.app --args -ConsolationPlayURL https://example.com/stream.m3u8
//      open build/Consolation.app --args -ConsolationPane liveTV
//      -ConsolationPlayURL file:///missing.mp4 -ConsolationKeepPane YES   (plays without opening the player: the mini player)
//      -ConsolationPlayURL file:///a.ts -ConsolationAddTileURLs file:///b.ts,file:///c.ts   (multi-view with three tiles)
//      open build/Consolation.app --args -ConsolationDiscover YES   (logs what UDP discovery finds)
//      -ConsolationFlipLayout 6   (iPhone and iPad: rotate mid-playback and log whether playback restarted)
//      -ConsolationWindowTest YES   (Mac and iPad: move the video between two windows and log it)
//

import HTTPMPEG2Kit
import os
import PlaybackKit
import SwiftUI

extension View {
    /// Runs the debug launch actions once, after the first appearance. Does nothing in Release builds.
    func debugLaunchActions() -> some View {
        #if DEBUG
        modifier(DebugLaunchActionsModifier())
        #else
        self
        #endif
    }
}

#if DEBUG
private struct DebugLaunchActionsModifier: ViewModifier {
    @Environment(ShellModel.self) private var shell
    @Environment(SourceStore.self) private var sources
    @Environment(LiveTVModel.self) private var liveTV
    @Environment(PlayerSession.self) private var session
    #if !os(tvOS)
    @Environment(\.openWindow) private var openWindow
    #endif

    /// The actions run once per launch, in the first window, not again in each window opened later.
    private static var hasRun = false

    func body(content: Content) -> some View {
        content.task {
            guard !Self.hasRun else { return }
            Self.hasRun = true
            await run()
        }
    }

    private func run() async {
        let defaults = UserDefaults.standard
        if defaults.bool(forKey: "ConsolationDiscover") {
            let log = Logger(subsystem: AppIdentifier.bundleID, category: "Debug")
            do {
                let tuners = try await HDHomeRunDiscoveryClient().discover()
                log.notice("Discovery found \(tuners.count) tuner(s): \(tuners.map(\.ipv4), privacy: .public)")
            } catch {
                log.error("Discovery failed: \(String(describing: error), privacy: .public)")
            }
        }
        if let host = defaults.string(forKey: "ConsolationAddSource") {
            sources.addHDHomeRun(host: host)
            liveTV.refresh(force: true)
        }
        if let pane = defaults.string(forKey: "ConsolationPane").flatMap(ShellItem.init(rawValue:)) {
            shell.selection = pane
        }
        if let text = defaults.string(forKey: "ConsolationPlayURL"), let url = URL(string: text) {
            session.play(url)
            if !defaults.bool(forKey: "ConsolationKeepPane") { shell.selection = .nowPlaying }
        }
        if let guideNumber = defaults.string(forKey: "ConsolationPlayChannel") {
            await playChannel(guideNumber)
        }
        await addTiles(defaults.string(forKey: "ConsolationAddTileURLs"))
        if defaults.bool(forKey: "ConsolationPiP") {
            await startPictureInPicture()
        }
        #if !os(tvOS)
        if defaults.bool(forKey: "ConsolationWindowTest") {
            await WindowTest.run(session: session, openWindow: openWindow)
        }
        #endif
        #if os(iOS)
        if defaults.integer(forKey: "ConsolationFlipLayout") > 0 {
            await LayoutFlipTest.run(count: defaults.integer(forKey: "ConsolationFlipLayout"), session: session)
        }
        #endif
        if let pane = defaults.string(forKey: "ConsolationThenPane").flatMap(ShellItem.init(rawValue:)) {
            try? await Task.sleep(for: .seconds(6))
            shell.selection = pane
        }
        if let guideNumber = defaults.string(forKey: "ConsolationThenChannel") {
            // Like tapping a channel in the guide while the mini player shows.
            try? await Task.sleep(for: .seconds(4))
            await playChannel(guideNumber)
        }
    }

    /// Starts Picture in Picture (system, or the Mac's floating window) a few seconds into playback, logs where the
    /// display view is each second, and stops PiP again after 6 s.
    private func startPictureInPicture() async {
        let log = Logger(subsystem: AppIdentifier.bundleID, category: "Debug")
        for _ in 0..<200 where !session.canPictureInPicture || session.engine?.state != .playing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(3))
        session.togglePictureInPicture()
        for second in 0..<10 {
            if second == 6 { session.togglePictureInPicture() }
            try? await Task.sleep(for: .seconds(1))
            guard let layer = session.engine?.displayLayer else { continue }
            let view = session.engine?.displayView
            let parent = view?.superview.map { "\(type(of: $0)) \($0.bounds.size)" } ?? "none"
            let state = "PiP \(session.isPictureInPictureActive), layer \(layer.frame), view in \(parent)"
            log.notice("\(state, privacy: .public)")
        }
    }

    /// More multi-view tiles, comma-separated (local files in tests: no network, never a tuner).
    private func addTiles(_ list: String?) async {
        for url in (list ?? "").split(separator: ",").compactMap({ URL(string: String($0)) }) {
            await session.addToMultiView(.url(url))
        }
    }

    private func playChannel(_ guideNumber: String) async {
        liveTV.refresh()
        for _ in 0..<100 {
            if let channel = liveTV.channels.first(where: { $0.guideNumber == guideNumber }) {
                session.play(channel, within: liveTV.visibleChannels.isEmpty ? liveTV.channels : liveTV.visibleChannels)
                shell.selection = .nowPlaying
                return
            }
            try? await Task.sleep(for: .milliseconds(100))
        }
    }
}
#endif
