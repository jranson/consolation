//
//  TVFocusTests.swift
//  ConsolationUITests
//
//  Apple TV focus and the collapsible menu (Apple Music's pattern), driven with the Siri Remote in the tvOS simulator:
//  the app starts in the restored pane with only a "‹ Home" header; Back opens the menu on the current item; up and
//  down move within it, left and right don't leave it; Select switches pane and closes it; Back in the open menu leaves
//  the app. UI tests use XCTest (Swift Testing can't drive XCUIApplication).
//

import XCTest

@MainActor
final class TVFocusTests: TVRemoteTestCase {
    private var header: XCUIElement { menuHeader }

    /// Opens the menu with Back and checks it opened on `item`.
    private func openMenu(on item: String, line: UInt = #line) {
        press(.menu)
        XCTAssertTrue(waitForPillFocus(), "Back opens the menu (focused: \(focusedLabels))", line: line)
        assertFocus("pill.\(item)", "the menu opens on the current item", line: line)
    }

    // MARK: - Tests

    func testLaunchFocusesThePaneWithTheMenuCollapsed() {
        assertFocus("home.etagere", "the app starts in the restored pane")
        XCTAssertTrue(header.exists, "the collapsed menu shows where you are")
        XCTAssertFalse(app.buttons["pill.home"].exists, "the menu is collapsed")
    }

    func testUpAndDownMoveInTheMenuAndLeftAndRightStay() {
        openMenu(on: "home")
        let order = ["pill.home", "pill.liveTV", "pill.quickPlay", "pill.library", "pill.nowPlaying", "pill.settings"]
        for expected in order.dropFirst() {
            press(.down)
            assertFocus(expected, "moving down the menu")
        }
        press(.right)
        assertFocus("pill.settings", "right stays in the menu")
        press(.left)
        assertFocus("pill.settings", "left stays in the menu")
        for expected in order.reversed().dropFirst() {
            press(.up)
            assertFocus(expected, "moving up the menu")
        }
        XCTAssertTrue(app.buttons["pill.home"].isSelected, "moving through the menu doesn't switch panes")
    }

    func testSelectSwitchesPaneAndCollapsesTheMenu() {
        openMenu(on: "home")
        press(.down, times: 5)
        assertFocus("pill.settings", "on Settings")
        press(.select)
        XCTAssertTrue(app.buttons["pill.settings"].waitForNonExistence(timeout: 3), "the menu collapses")
        XCTAssertEqual(header.label.contains("Settings"), true, "the header shows Settings (\(header.label))")
        XCTAssertFalse(focusedIsInPill, "focus moves into Settings (focused: \(focusedLabels))")
        openMenu(on: "settings")
    }

    func testBackInTheOpenMenuLeavesTheApp() {
        openMenu(on: "home")
        press(.menu)
        assertLeftTheApp("Back in the open menu leaves the app")
    }

    /// Now Playing with nothing playing has nothing to focus, so choosing it keeps the menu open.
    func testChoosingAPaneWithNothingToFocusKeepsTheMenuOpen() {
        openMenu(on: "home")
        press(.down, times: 4)
        press(.select)
        XCTAssertTrue(app.buttons["pill.nowPlaying"].isSelected, "Now Playing is selected")
        assertFocus("pill.nowPlaying", "the menu stays open with focus on Now Playing")
    }

    /// Leaving the app on Now Playing with nothing playing, then coming back, used to leave focus nowhere, so the menu
    /// couldn't be opened. Coming back opens the menu there.
    func testComingBackToAnEmptyNowPlayingOpensTheMenu() {
        openMenu(on: "home")
        press(.down, times: 4)
        press(.select)
        assertFocus("pill.nowPlaying", "Now Playing is chosen, with the menu still open")
        press(.menu)
        assertLeftTheApp("Back in the open menu leaves the app")
        app.activate()
        XCTAssertTrue(app.wait(for: .runningForeground, timeout: 5), "the app is back")
        XCTAssertTrue(waitForPillFocus(timeout: 5), "the menu opens (focused: \(focusedLabels))")
        assertFocus("pill.nowPlaying", "on Now Playing")
    }

    func testQuickPlayTakesFocusWhenChosen() {
        openMenu(on: "home")
        press(.down, times: 2)
        press(.select)
        XCTAssertTrue(app.buttons["pill.quickPlay"].waitForNonExistence(timeout: 3), "the menu collapses")
        XCTAssertFalse(focusedIsInPill, "Quick Play takes focus (focused: \(focusedLabels))")
        XCTAssertFalse(app.keyboards.firstMatch.exists, "focusing the field doesn't open the keyboard")
    }

    /// Home's Etagere in mode 1 (the default) takes every direction; Back opens the menu, and choosing Home again
    /// returns to the Etagere.
    func testHomeEtagereKeepsEveryDirectionAndBackOpensTheMenu() {
        assertFocus("home.etagere", "the app starts in Home's Etagere")
        let moves: [(XCUIRemote.Button, String)] = [
            (.left, "left"), (.up, "up"), (.down, "down"), (.left, "left again"), (.right, "right"), (.left, "left")
        ]
        for (button, name) in moves {
            press(button)
            assertFocusStaysInEtagere("\(name) stays in the Etagere; the menu must not take it")
        }
        openMenu(on: "home")
        press(.select)
        assertFocus("home.etagere", "choosing Home returns to the Etagere")
    }

    /// Settings › Home › Vertical navigation: Cursor (mode 2). Each shelf row takes focus itself; left never leaves
    /// the rows, and Back opens the menu.
    func testHomeCursorModeKeepsLeftAndBackOpensTheMenu() {
        launch(["-ConsolationPane", "home", "-org.centennialoss.consolation.home.verticalMode", "cursor"])
        // Focus arriving on a row makes that shelf active, which can hide the focused flag from the snapshot too.
        assertFocusOutsideThePill("the app starts in a shelf row")
        for (button, name) in [(XCUIRemote.Button.left, "left"), (.down, "down"), (.left, "left on the next row")] {
            press(button)
            assertFocusOutsideThePill("\(name) stays among the shelf rows")
        }
        openMenu(on: "home")
    }

    /// "Go" on an empty shelf's placeholder opens Settings at Sources, with its add field focused.
    func testSelectOnAnEmptyShelfOpensSettingsAtSources() throws {
        try launchWithOnlyRecentRecordings()
        assertFocus("home.etagere", "the app starts in Home's Etagere")
        press(.select)
        XCTAssertTrue(header.label.contains("Settings"), "go on the placeholder opens Settings (\(header.label))")
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        XCTAssertEqual(focused.elementType, .textField, "Settings opens at the Sources add field")
    }

    /// The long-press menu's "Edit Home" opens Settings at Home, with the first shelf's switch focused.
    func testEditHomeOpensSettingsAtHome() throws {
        try launchWithOnlyRecentRecordings()
        remote.press(.select, forDuration: 1.2)
        Self.settle()
        XCTAssertTrue(waitForFocus(on: "Edit Home"), "the placeholder's long-press menu offers Edit Home")
        press(.select)
        XCTAssertTrue(header.label.contains("Settings"), "Edit Home opens Settings (\(header.label))")
        // The menu animates away before its action runs, and Settings then places focus.
        XCTAssertTrue(waitForFocus(on: "Favorites"), "Settings opens at Home's first shelf")
    }
}
