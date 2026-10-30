//
//  TVRemoteTestCase.swift
//  ConsolationUITests
//
//  What every Apple TV UI test shares: launching the app on Home, pressing Siri Remote buttons, and reading where
//  focus is. A test must never press Select or Play/Pause where a real channel's card could be the Active ShelfCard:
//  it would tune the household's tuners. `launchWithOnlyRecentRecordings` gives Home nothing but a placeholder.
//

import XCTest

@MainActor
class TVRemoteTestCase: XCTestCase {
    var app: XCUIApplication!
    let remote = XCUIRemote.shared

    override func setUp() {
        continueAfterFailure = false
        app = XCUIApplication()
        launch(["-ConsolationPane", "home"])
    }

    override func tearDown() {
        app.terminate()
    }

    // MARK: - Launching

    /// Launches (again) with `arguments`, and waits for the collapsed menu's header (unless the player opens, which
    /// shows none).
    func launch(_ arguments: [String], waitsForPill: Bool = true) {
        if app.state != .notRunning { app.terminate() }
        app.launchArguments = arguments
        // Logs every focus move to the simulator's log (`CONSOLATION_FOCUS_TRACE`), for diagnosing a failure.
        app.launchEnvironment["CONSOLATION_FOCUS_TRACE"] = "1"
        app.launch()
        if waitsForPill { XCTAssertTrue(menuHeader.waitForExistence(timeout: 10)) }
        Self.settle()
    }

    /// Settings › Home's shelves for this launch only (a launch argument, never saved): each listed shelf on or off.
    static func shelvesArguments(_ shelves: [(kind: String, isEnabled: Bool)]) -> [String] {
        let json = "[" + shelves.map { #"{"kind":"\#($0.kind)","isEnabled":\#($0.isEnabled)}"# }
            .joined(separator: ",") + "]"
        let hex = Data(json.utf8).map { String(format: "%02x", $0) }.joined()
        return ["-org.centennialoss.consolation.home.shelves", "<\(hex)>"]
    }

    /// Relaunches with Favorites and Live TV Channels turned off for this launch only, so Home holds only Recent
    /// Recordings' placeholder. "Go" on a card would play it, and a UI test must never tune the household's tuners;
    /// a placeholder only opens Settings. Skips if the shelf isn't empty.
    func launchWithOnlyRecentRecordings(_ extraArguments: [String] = []) throws {
        launch(["-ConsolationPane", "home"]
               + Self.shelvesArguments([("favorites", false), ("liveChannels", false), ("recordingNow", false),
                                        ("continueWatching", false), ("quickPlayHistory", false)])
               + extraArguments)
        let etagere = app.descendants(matching: .any)["home.etagere"]
        let message = "Connect a DVR source in Settings"
        guard etagere.label == "Recent Recordings", (etagere.value as? String)?.hasPrefix(message) == true else {
            let shown = "\(etagere.label): \(String(describing: etagere.value))"
            throw XCTSkip("Home isn't only an empty Recent Recordings shelf here (\(shown))")
        }
    }

    /// Apple TV's collapsed menu: "‹ Home" in the upper left.
    var menuHeader: XCUIElement { app.descendants(matching: .any)["menu.header"] }

    // MARK: - The remote

    func press(_ button: XCUIRemote.Button, times: Int = 1) {
        for _ in 0..<times {
            remote.press(button)
            Self.settle()
        }
    }

    /// Lets focus and the selection-follows-focus pane change finish.
    static func settle() {
        Thread.sleep(forTimeInterval: 0.6)
    }

    /// Back at the top level left the app for the Apple TV Home Screen.
    func assertLeftTheApp(_ message: String, line: UInt = #line) {
        // XCTest's own wait: the state only refreshes while the test's run loop turns, not under Thread.sleep.
        let left = app.wait(for: .runningBackgroundSuspended, timeout: 5) || app.state == .runningBackground
        XCTAssertTrue(left, "\(message) (state \(app.state.rawValue))", line: line)
    }

    /// The app is still in front: XCTest's wait, briefly.
    func assertStillInTheApp(_ message: String, line: UInt = #line) {
        XCTAssertFalse(app.wait(for: .runningBackgroundSuspended, timeout: 1), message, line: line)
    }

    /// Waits for the pill to have focus.
    func waitForPillFocus(timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !focusedIsInPill {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    // MARK: - Focus

    /// The identifier of the element with focus ("" when it has none).
    var focusedID: String {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch.identifier
    }

    var focusedIsInPill: Bool { focusedID.hasPrefix("pill.") }

    func assertFocus(_ expected: String, _ message: String, line: UInt = #line) {
        XCTAssertEqual(focusedID, expected, message, line: line)
    }

    /// Waits up to `timeout` seconds for `focusedShows(label)`.
    func waitForFocus(on label: String, timeout: TimeInterval = 3) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !focusedShows(label) {
            guard Date() < deadline else { return false }
            Thread.sleep(forTimeInterval: 0.2)
        }
        return true
    }

    /// Whether the focused element is labeled `label`, or contains an element that is (a menu cell).
    func focusedShows(_ label: String) -> Bool {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
        guard focused.exists else { return false }
        let labeled = NSPredicate(format: "label == %@", label)
        return focused.label == label || focused.descendants(matching: .any).matching(labeled).firstMatch.exists
    }

    /// The labels of every element reported as focused, for failure messages.
    var focusedLabels: [String] {
        app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
            .allElementsBoundByIndex.map { "\($0.identifier)|\($0.label)" }
    }

    /// The pill never has focus. Like `assertFocusStaysInEtagere`, it allows a moment where the accessibility
    /// snapshot reports no focused element after a shelf move.
    func assertFocusOutsideThePill(_ message: String, line: UInt = #line) {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
        let identifiers = focused.allElementsBoundByIndex.map(\.identifier)
        XCTAssertFalse(identifiers.contains { $0.hasPrefix("pill.") }, "\(message) (focused: \(identifiers))",
                       line: line)
    }

    /// Home's Etagere is one focusable element that keeps every direction. After a shelf move that reverses
    /// direction (up, then down) the simulator's accessibility snapshot can report no focused element for a moment,
    /// although UIKit's focus never moves (`CONSOLATION_FOCUS_TRACE=1` logs no focus update), so this checks that the
    /// focused element, whenever one is reported, is the Etagere: in particular the pill never has focus.
    func assertFocusStaysInEtagere(_ message: String, line: UInt = #line) {
        let focused = app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true"))
        let identifiers = focused.allElementsBoundByIndex.map(\.identifier)
        XCTAssertTrue(identifiers.allSatisfy { $0 == "home.etagere" }, "\(message) (focused: \(identifiers))",
                      line: line)
    }
}
