//
//  LayoutFlipTest.swift
//  Consolation
//
//  Debug builds on iPhone and iPad: `-ConsolationFlipLayout <count>` rotates the window between portrait and landscape
//  every 4 s, `count` times, a few seconds into playback. On an iPhone that crosses the 500 pt width class both ways
//  (bottom pill and leading pill), like folding and unfolding iPhone Duo, so it checks that a resize never restarts
//  playback: each step logs the window width, the engine's identity and state, and the frames shown so far.
//      make run-sim-iphone CHANNEL=9.1 ARGS="-ConsolationFlipLayout 6"
//

import os
import PlaybackKit
import SwiftUI

#if DEBUG && os(iOS)
import UIKit

enum LayoutFlipTest {
    @MainActor
    static func run(count: Int, session: PlayerSession) async {
        let log = Logger(subsystem: AppIdentifier.bundleID, category: "Debug")
        for _ in 0..<200 where session.engine?.state != .playing {
            try? await Task.sleep(for: .milliseconds(100))
        }
        try? await Task.sleep(for: .seconds(3))
        guard let scene = UIApplication.shared.connectedScenes.compactMap({ $0 as? UIWindowScene }).first,
              let engine = session.engine else { return }
        let identity = ObjectIdentifier(engine as AnyObject)
        for step in 0...count {
            if step > 0 {
                let landscape = step % 2 == 1
                scene.requestGeometryUpdate(.iOS(interfaceOrientations: landscape ? .landscapeRight : .portrait))
                try? await Task.sleep(for: .seconds(4))
            }
            let current = session.engine.map { ObjectIdentifier($0 as AnyObject) }
            let shown = (session.engine as? any LivePlaybackControlling)?.diagnostics.framesShown ?? -1
            let state = session.engine.map { String(describing: $0.state) } ?? "none"
            let line = "Layout flip \(step): width \(Int(scene.effectiveGeometry.coordinateSpace.bounds.width)) pt, "
                + "same engine \(current == identity), state \(state), frames shown \(shown)"
            log.notice("\(line, privacy: .public)")
        }
    }
}
#endif
