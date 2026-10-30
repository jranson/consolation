//
//  TVHomeTests.swift
//  ConsolationUITests
//
//  Home on Apple TV with the Siri Remote: mode 2's rows at the top edge, and Play/Pause (it dismisses the mini player
//  while something plays, otherwise it plays the Active ShelfCard). Nothing here plays a channel: Play/Pause is pressed
//  only on a Home with nothing but a placeholder, and the "playing" video is a missing local file, which connects
//  nowhere.
//

import XCTest

@MainActor
final class TVHomeTests: TVRemoteTestCase {
    /// Favorites, Live TV Channels and Recent Recordings, in that order: the transient and optional shelves off.
    static let threeShelves = shelvesArguments([
        ("favorites", true), ("liveChannels", true), ("recordingNow", false), ("recentRecordings", true),
        ("continueWatching", false), ("quickPlayHistory", false)
    ])

    private var miniPlayer: XCUIElement {
        app.descendants(matching: .any)["player.mini"]
    }

    /// The three shelves' titles, top to bottom.
    static let shelfTitles = ["Favorites", "Live TV Channels", "Recent Recordings"]

    /// The title of the Active Shelf's row. In mode 2 the focused row is the Active Shelf, and the simulator's
    /// accessibility snapshot reports the row as selected but never as focused (`CONSOLATION_FOCUS_TRACE=1` shows
    /// UIKit's focus on it), so the selected row stands for the focused one.
    private var activeRow: String? {
        let selected = NSPredicate(format: "isSelected == true AND label IN %@", Self.shelfTitles)
        let row = app.buttons.matching(selected).firstMatch
        return row.exists ? row.label : nil
    }

    /// Waits up to `timeout` seconds for the row titled `title` to be the active (focused) one.
    private func waitForActiveRow(_ title: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while activeRow != title {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    /// Mode 2 (Vertical navigation: Cursor, for this launch only): each row takes focus. Down from the first row
    /// reaches the second; up on the first row, with nothing above it, keeps focus there (a bump) instead of jumping
    /// to the pill or getting stuck. No Select is pressed.
    func testCursorModeTopRowMovesDownAndKeepsUp() {
        launch(["-ConsolationPane", "home", "-org.centennialoss.consolation.home.verticalMode", "cursor"]
               + Self.threeShelves)
        press(.right)
        assertFocusOutsideThePill("right enters a shelf row")
        XCTAssertNotNil(activeRow, "right makes a row active")
        // Wherever focus entered (the saved Active Shelf), three ups end on the first row.
        press(.up, times: 3)
        XCTAssertTrue(waitForActiveRow("Favorites"), "up reaches the first row (active: \(activeRow ?? "none"))")

        press(.down)
        XCTAssertTrue(waitForActiveRow("Live TV Channels"),
                      "down from the first row moves to the second (active: \(activeRow ?? "none"))")
        press(.up)
        XCTAssertTrue(waitForActiveRow("Favorites"), "up from the second row returns (active: \(activeRow ?? "none"))")

        press(.up)
        XCTAssertTrue(waitForActiveRow("Favorites"),
                      "up on the first row keeps it active (active: \(activeRow ?? "none"))")
        assertFocusOutsideThePill("up at the top never reaches the pill")
        press(.up)
        assertFocusOutsideThePill("a second up at the top stays too")
        XCTAssertEqual(activeRow, "Favorites", "a second up at the top keeps the first row")

        press(.down)
        XCTAssertTrue(waitForActiveRow("Live TV Channels"),
                      "after the bump, down still moves: focus isn't stuck (active: \(activeRow ?? "none"))")
        press(.menu)
        assertFocus("pill.home", "Back returns to Home's pill item")
    }

    /// While something plays in the mini player, Play/Pause on Home's Etagere dismisses it and plays nothing.
    func testPlayPauseOnHomeDismissesTheMiniPlayer() throws {
        // A local file that doesn't exist: no network, never a tuner, but the session (and the mini player) runs.
        try launchWithOnlyRecentRecordings(["-ConsolationPlayURL", "file:///ui-test/missing.mp4",
                                            "-ConsolationKeepPane", "YES"])
        XCTAssertTrue(miniPlayer.waitForExistence(timeout: 10), "the mini player shows what plays")
        press(.right)
        assertFocus("home.etagere", "right enters Home's Etagere")

        press(.playPause)
        XCTAssertTrue(miniPlayer.waitForNonExistence(timeout: 5), "Play/Pause dismisses the mini player")
        XCTAssertTrue(menuHeader.label.contains("Home"), "Home stays: the placeholder's action didn't run")
        assertFocus("home.etagere", "focus stays in the Etagere")
    }

    /// With nothing playing, Play/Pause is "go" on the Active ShelfCard, here Recent Recordings' placeholder: it
    /// opens Settings at Sources, and no session starts.
    func testPlayPauseWithNothingPlayingIsGo() throws {
        try launchWithOnlyRecentRecordings()
        press(.right)
        assertFocus("home.etagere", "right enters Home's Etagere")
        press(.playPause)
        XCTAssertTrue(menuHeader.label.contains("Settings"), "Play/Pause on the placeholder opens Settings")
        XCTAssertFalse(miniPlayer.exists, "no session started")
    }
}
