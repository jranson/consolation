//
//  TVPlayerTests.swift
//  ConsolationUITests
//
//  The full-screen player with the Siri Remote: Back reaching the pill while a stream plays with its controls hidden,
//  and Select bringing up the control bar with focus in it. The "stream" is a local file that doesn't exist: the
//  session runs, but nothing touches the network or a tuner. Select here only shows the controls; no test presses
//  Select on a control.
//

import XCTest

@MainActor
final class TVPlayerTests: TVRemoteTestCase {
    /// The controls (and with them the pill) hide 3 s after the last input.
    private static let autoHide: TimeInterval = 4

    private func launchInThePlayer() {
        launch(["-ConsolationPane", "home", "-ConsolationPlayURL", "file:///ui-test/missing.mp4"], waitsForPill: false)
        XCTAssertTrue(app.buttons["player.video"].waitForExistence(timeout: 5), "the player opens")
    }

    private func waitForFocusID(_ identifier: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while focusedID != identifier {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    func testBackWhilePlayingWithHiddenControlsFocusesThePill() {
        launchInThePlayer()
        Thread.sleep(forTimeInterval: Self.autoHide)
        XCTAssertFalse(app.buttons["player.playPause"].exists, "the controls have hidden")
        press(.menu)
        XCTAssertTrue(waitForFocusID("pill.nowPlaying"),
                      "Back brings the pill and focuses Now Playing's item (focused: \(focusedLabels))")
    }

    func testSelectShowsTheControlsWithFocusAndBackHidesThem() {
        launchInThePlayer()
        Thread.sleep(forTimeInterval: Self.autoHide)
        assertFocus("player.video", "the video has focus while the controls are hidden")

        press(.select)
        XCTAssertTrue(waitForFocusID("player.playPause"),
                      "Select brings up the controls with focus on Play/Pause (focused: \(focusedLabels))")
        Thread.sleep(forTimeInterval: Self.autoHide)
        XCTAssertTrue(app.buttons["player.playPause"].exists, "the controls stay up while focus is in them")
        press(.right)
        XCTAssertFalse(focusedIsInPill, "right moves along the control bar (focused: \(focusedLabels))")

        press(.menu)
        XCTAssertTrue(waitForFocusID("player.video"), "Back hides the controls and returns to the video")
        XCTAssertTrue(app.buttons["player.playPause"].waitForNonExistence(timeout: 2), "the controls are gone")

        press(.menu)
        XCTAssertTrue(waitForFocusID("pill.nowPlaying"), "Back again goes to the pill (focused: \(focusedLabels))")
    }
}
