//
//  TVSettingsTests.swift
//  ConsolationUITests
//
//  Settings on Apple TV: every text field reachable with the remote opens the keyboard when selected.
//

import XCTest

final class TVSettingsTests: TVRemoteTestCase {
    /// Settings opened from Home's empty shelf, focus moved down to the field with `identifier`.
    private func focusSettingsField(_ identifier: String, line: UInt = #line) throws {
        try launchWithOnlyRecentRecordings()
        press(.select)
        XCTAssertTrue(app.descendants(matching: .any)["menu.header"].label.contains("Settings"),
                      "go on the placeholder opens Settings", line: line)
        for _ in 0..<12 where focusedID != identifier {
            press(.down)
        }
        assertFocus(identifier, "down from Sources reaches \(identifier) (\(focusedLabels))", line: line)
    }

    /// Select on the Plex token field opens the keyboard, so a token can be entered on Apple TV.
    func testThePlexTokenFieldOpensTheKeyboard() throws {
        try focusSettingsField("settings.plex.token")
        press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the keyboard opens for the token")
    }

    /// The same for the Plex address field above it.
    func testThePlexAddressFieldOpensTheKeyboard() throws {
        try focusSettingsField("settings.plex.address")
        press(.select)
        XCTAssertTrue(app.keyboards.firstMatch.waitForExistence(timeout: 3), "the keyboard opens for the address")
    }
}
