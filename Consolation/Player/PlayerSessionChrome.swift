//
//  PlayerSessionChrome.swift
//  Consolation
//
//  The player's auto-hiding controls and the channel banner.
//

import Foundation
import PlaybackKit

extension PlayerSession {
    static let chromeAutoHide: Duration = .seconds(3)
    static let bannerDuration: Duration = .seconds(4)

    /// Apple TV: the controls stay up while focus is in them (no auto-hide).
    func pinControls() {
        chromeTask?.cancel()
        controlsPinned = true
        controlsVisible = true
    }

    /// Apple TV: focus left the controls; they hide on their own again.
    func unpinControls() {
        controlsPinned = false
    }

    /// Apple TV: Back in the controls hides them at once.
    func hideControls() {
        chromeTask?.cancel()
        controlsPinned = false
        controlsVisible = false
    }

    /// Apple TV: shows the controls and moves focus into them.
    func requestControlsFocus() {
        controlsFocusRequest += 1
    }

    /// Apple TV's Play/Pause in the player: pause or play, and bring up the controls with focus on the timeline, ready
    /// to scrub; without a timeline (a stream that can't seek), on Play/Pause.
    func playPauseFromRemote() {
        togglePause()
        guard engine?.timeline() != nil else {
            requestControlsFocus()
            return
        }
        pinControls()
        timelineFocusRequested = true
    }

    func showControlsBriefly() {
        #if os(tvOS)
        // Apple TV multi-view: the bar comes only with Select on the front tile, which also moves focus into it; up
        // on its own it would take the remote's input from the tiles.
        if isMultiView, !controlsVisible { return }
        #endif
        controlsVisible = true
        chromeTask?.cancel()
        // Pinned (focus is in them): a press there must not start the auto-hide.
        guard !controlsPinned else { return }
        chromeTask = Task { [weak self] in
            try? await Task.sleep(for: Self.chromeAutoHide)
            guard !Task.isCancelled else { return }
            self?.controlsVisible = false
        }
    }

    func flashBanner() {
        guard currentChannel != nil else { return }
        bannerVisible = true
        bannerTask?.cancel()
        bannerTask = Task { [weak self] in
            try? await Task.sleep(for: Self.bannerDuration)
            guard !Task.isCancelled else { return }
            self?.bannerVisible = false
        }
    }
}
