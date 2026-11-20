//
//  TVLibraryTests.swift
//  ConsolationUITests
//
//  The Library pane on Apple TV, with this simulator's own library server. Select here only opens folders (a server,
//  Recording Now), never plays anything.
//

import XCTest

@MainActor
final class TVLibraryTests: TVRemoteTestCase {
    /// Whether the focused element's label contains `text`.
    private func focusedContains(_ text: String) -> Bool {
        focusedLabels.contains { $0.contains(text) }
    }

    /// An empty folder (Recording Now with nothing recording) had nothing to focus, so Back left the app, and coming
    /// back landed in the same folder with no way out. The empty folder now holds focus and Back closes it.
    func testBackClosesAnEmptyFolder() throws {
        launch(["-ConsolationPane", "library"])
        guard menuHeader.label.contains("Librar") else {
            throw XCTSkip("no library server on this simulator (\(menuHeader.label))")
        }
        guard !focusedIsInPill, !focusedContains("Add Source") else {
            throw XCTSkip("focus isn't on a library server (\(focusedLabels))")
        }
        press(.select)
        var found = false
        for _ in 0..<15 {
            if focusedContains("Recording Now") {
                found = true
                break
            }
            press(.down)
        }
        guard found else { throw XCTSkip("the server has no Recording Now folder (\(focusedLabels))") }
        press(.select)
        let placeholder = app.descendants(matching: .any)["library.placeholder"]
        // The folder loads from the server; "Nothing here yet." replaces the spinner, both holding focus.
        Thread.sleep(forTimeInterval: 2)
        guard placeholder.exists else { throw XCTSkip("something is recording now (\(focusedLabels))") }
        assertFocus("library.placeholder", "the empty folder holds focus")
        press(.menu)
        assertStillInTheApp("Back closes the folder instead of leaving the app")
        XCTAssertTrue(placeholder.waitForNonExistence(timeout: 3), "the folder closed")
        XCTAssertFalse(focusedID.isEmpty && focusedLabels.isEmpty, "focus is back in the server's folder")
    }
}
