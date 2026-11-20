//
//  TVSkipCommercialsTests.swift
//  ConsolationUITests
//
//  Skip Commercials on Apple TV. `-ConsolationTestAdBreak YES` (Debug builds) puts whatever plays in an ad break, so
//  the button shows over the missing-file stream TVPlayerTests uses: no server, no tuner, no network.
//

import XCTest

@MainActor
final class TVSkipCommercialsTests: TVRemoteTestCase {
    private var skipButton: XCUIElement { app.buttons["player.skipCommercials"] }

    private func launchInABreak() {
        launch(["-ConsolationPane", "home", "-ConsolationPlayURL", "file:///ui-test/missing.mp4",
                "-ConsolationTestAdBreak", "YES"], waitsForPill: false)
        XCTAssertTrue(app.buttons["player.video"].waitForExistence(timeout: 5), "the player opens")
        XCTAssertTrue(skipButton.waitForExistence(timeout: 5), "Skip Commercials shows during the break")
    }

    private func waitForFocusID(_ identifier: String, timeout: TimeInterval = 4) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while focusedID != identifier {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    func testSkipCommercialsTakesFocusAndBackDismissesIt() {
        launchInABreak()
        XCTAssertTrue(waitForFocusID("player.skipCommercials"),
                      "Skip Commercials has focus (focused: \(focusedLabels))")
        press(.menu)
        XCTAssertTrue(skipButton.waitForNonExistence(timeout: 3), "Back dismisses it")
        XCTAssertTrue(waitForFocusID("player.video"), "focus returns to the video (\(focusedLabels))")
        assertStillInTheApp("Back on the button doesn't leave the app")
    }

    /// A break dismissed with Back stays dismissed through the menu and back: the video keeps focus.
    func testADismissedBreakStaysDismissedThroughTheMenu() {
        launchInABreak()
        XCTAssertTrue(waitForFocusID("player.skipCommercials"), "Skip Commercials has focus (\(focusedLabels))")
        press(.menu)
        XCTAssertTrue(waitForFocusID("player.video"), "Back dismisses it (\(focusedLabels))")
        // Back on the video opens the menu; choosing Now Playing returns to the player, still in the break, but
        // dismissed: the video keeps focus.
        press(.menu)
        XCTAssertTrue(waitForFocusID("pill.nowPlaying"), "Back opens the menu (\(focusedLabels))")
        press(.select)
        XCTAssertTrue(waitForFocusID("player.video"), "back in the player (\(focusedLabels))")
        XCTAssertFalse(skipButton.exists, "a dismissed break stays dismissed")
    }

    func testSelectOnSkipCommercialsSkips() {
        launchInABreak()
        XCTAssertTrue(waitForFocusID("player.skipCommercials"), "Skip Commercials has focus (\(focusedLabels))")
        press(.select)
        XCTAssertTrue(skipButton.waitForNonExistence(timeout: 3), "skipping ends the offer")
        XCTAssertTrue(waitForFocusID("player.video"), "focus returns to the video (\(focusedLabels))")
    }
}
