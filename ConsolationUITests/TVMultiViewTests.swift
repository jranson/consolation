//
//  TVMultiViewTests.swift
//  ConsolationUITests
//
//  Multi-view with the Siri Remote: the d-pad moves between grid tiles, Select brings one forward, Back returns to the
//  grid and then to the pill, and Select on the front tile brings up the controls with focus in them. The tiles play
//  local files that don't exist: the session and its tiles run, but nothing touches the network or a tuner. Select is
//  only ever pressed on these tiles.
//

import XCTest

@MainActor
final class TVMultiViewTests: TVRemoteTestCase {
    private func launchWithThreeTiles() {
        launch(["-ConsolationPane", "home", "-ConsolationPlayURL", "file:///ui-test/one.ts",
                "-ConsolationAddTileURLs", "file:///ui-test/two.ts,file:///ui-test/three.ts"],
               waitsForPill: false)
        XCTAssertTrue(tiles.element(boundBy: 2).waitForExistence(timeout: 8), "three tiles play")
        Self.settle()
    }

    /// Every tile's frame and focus, for failure messages.
    private var tileFrames: [String] {
        tiles.allElementsBoundByIndex.map { "\($0.frame) focus \($0.hasFocus) enabled \($0.isEnabled)" }
    }

    private var tiles: XCUIElementQuery { app.buttons.matching(identifier: "multiview.tile") }

    /// The tile with focus, if one has it.
    private var focusedTile: XCUIElement? {
        let focused = tiles.matching(NSPredicate(format: "hasFocus == true")).firstMatch
        return focused.exists ? focused : nil
    }

    private func waitForFocusedTile(timeout: TimeInterval = 3) -> XCUIElement? {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let tile = focusedTile { return tile }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return nil
    }

    func testTheDPadMovesBetweenTilesAndSelectBringsOneForward() throws {
        launchWithThreeTiles()
        // Focus queries resolve again on every read, so each frame is read once, right away.
        let first = try XCTUnwrap(waitForFocusedTile(), "a tile has focus (focused: \(focusedLabels))").frame
        let screen = app.windows.firstMatch.frame
        XCTAssertLessThan(first.width, screen.width * 0.6, "grid tiles are cells, not full screen")

        // Two tiles on top, the third centered below: up reaches the top row, then left its first tile, where a
        // further left stays (no wrap, and focus never leaves the player).
        press(.up)
        press(.left, times: 2)
        let topLeft = try XCTUnwrap(waitForFocusedTile(), "focus stays on a tile at the grid's edge").frame
        XCTAssertLessThan(topLeft.minX, screen.width * 0.25, "up then left reach the top-left tile")
        press(.right)
        let next = try XCTUnwrap(waitForFocusedTile(), "right moves to another tile (focused: \(focusedLabels))").frame
        XCTAssertGreaterThan(next.minX, topLeft.minX,
                             "right moves to the tile on the right (tiles: \(tileFrames))")

        press(.select)
        let front = try XCTUnwrap(waitForFocusedTile(), "the front tile keeps focus").frame
        XCTAssertGreaterThan(front.width, screen.width * 0.8, "Select brings the tile forward")

        press(.menu)
        let back = try XCTUnwrap(waitForFocusedTile(), "Back returns to the grid with focus on a tile").frame
        XCTAssertLessThan(back.width, screen.width * 0.6, "the tile is back in its cell")

        press(.menu)
        XCTAssertTrue(waitForPill(), "Back from the grid goes to the pill (focused: \(focusedLabels))")
    }

    func testSelectOnTheFrontTileShowsTheControlsWithMultiViewButtons() throws {
        launchWithThreeTiles()
        XCTAssertNotNil(waitForFocusedTile(), "a tile has focus (focused: \(focusedLabels))")
        press(.select)
        press(.select)
        let playPause = app.buttons["player.playPause"]
        XCTAssertTrue(playPause.waitForExistence(timeout: 3), "Select on the front tile shows the controls")
        XCTAssertTrue(waitForFocusID("player.playPause"), "focus moves into the controls (focused: \(focusedLabels))")
        XCTAssertTrue(app.buttons["player.arrange"].exists, "the controls offer Arrange Multi-view")
        // Exit Multi-view is in the More menu and the arrangement panel.
        XCTAssertTrue(app.descendants(matching: .any)["player.more"].exists, "the controls offer the More menu")

        press(.menu)
        XCTAssertTrue(playPause.waitForNonExistence(timeout: 3), "Back hides the controls")
        XCTAssertNotNil(waitForFocusedTile(), "focus returns to the front tile (focused: \(focusedLabels))")
    }

    /// In multi-view, focus in the menu used to get stuck there instead of getting back to the tiles. Back opens the
    /// menu on Now Playing, right stays in it, and Select there returns to a tile.
    func testTheMenuReturnsFocusToTheTiles() throws {
        launchWithThreeTiles()
        XCTAssertNotNil(waitForFocusedTile(), "a tile has focus (focused: \(focusedLabels))")
        press(.menu)
        XCTAssertTrue(waitForPill(), "Back from the grid opens the menu (focused: \(focusedLabels))")
        assertFocus("pill.nowPlaying", "the menu opens on Now Playing")
        press(.right)
        assertFocus("pill.nowPlaying", "right stays in the menu")
        press(.select)
        XCTAssertNotNil(waitForFocusedTile(), "Select on Now Playing returns to a tile (focused: \(focusedLabels))")
        XCTAssertEqual(app.state, .runningForeground, "the app is still in front")
    }

    private func waitForPill(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !focusedIsInPill {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    private func waitForFocusID(_ identifier: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while focusedID != identifier {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }
}
