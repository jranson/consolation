//
//  TVTimelineTests.swift
//  ConsolationUITests
//
//  The player's timeline with the Siri Remote: down from the buttons reaches it, left and right move its dot, and
//  Select moves playback there. Needs a seekable stream: an on-demand HLS test URL, so it runs only when
//  `CONSOLATION_UI_NETWORK_URL` is set (TEST_RUNNER_CONSOLATION_UI_NETWORK_URL for xcodebuild). Never a tuner.
//

import XCTest

@MainActor
final class TVTimelineTests: TVRemoteTestCase {
    func testSelectOnTheTimelineMovesPlayback() throws {
        guard let url = ProcessInfo.processInfo.environment["CONSOLATION_UI_NETWORK_URL"] else {
            throw XCTSkip("set CONSOLATION_UI_NETWORK_URL to an on-demand stream")
        }
        launch(["-ConsolationPane", "home", "-ConsolationPlayURL", url], waitsForPill: false)
        XCTAssertTrue(app.buttons["player.video"].waitForExistence(timeout: 10), "the player opens")
        Thread.sleep(forTimeInterval: 8)
        press(.select)
        let timeline = app.descendants(matching: .any)["player.timeline"]
        XCTAssertTrue(timeline.waitForExistence(timeout: 5), "the controls show the timeline")
        let before = timeline.value as? String ?? ""
        press(.down)
        XCTAssertTrue(timeline.hasFocus || focusedID == "player.timeline",
                      "down reaches the timeline (\(focusedLabels))")
        press(.right, times: 3)
        XCTAssertEqual(focusedID, "player.timeline", "left and right stay on the timeline (\(focusedLabels))")
        let pending = Self.seconds(timeline.value as? String)
        XCTAssertGreaterThan(pending, Self.seconds(before) + 60, "right moves the dot ahead")
        press(.select)
        Thread.sleep(forTimeInterval: 3)
        let after = Self.seconds(timeline.value as? String)
        XCTAssertGreaterThanOrEqual(after, pending - 2, "Select moved playback to the dot (\(before) → \(after))")
    }

    /// Play/Pause during playback pauses and brings up the controls with focus on the timeline.
    func testPlayPauseFocusesTheTimeline() throws {
        guard let url = ProcessInfo.processInfo.environment["CONSOLATION_UI_NETWORK_URL"] else {
            throw XCTSkip("set CONSOLATION_UI_NETWORK_URL to an on-demand stream")
        }
        launch(["-ConsolationPane", "home", "-ConsolationPlayURL", url], waitsForPill: false)
        XCTAssertTrue(app.buttons["player.video"].waitForExistence(timeout: 10), "the player opens")
        Thread.sleep(forTimeInterval: 8)
        press(.playPause)
        let deadline = Date().addingTimeInterval(3)
        while focusedID != "player.timeline", Date() < deadline { Thread.sleep(forTimeInterval: 0.2) }
        XCTAssertEqual(focusedID, "player.timeline", "Play/Pause focuses the timeline (\(focusedLabels))")
        XCTAssertTrue(app.buttons["player.playPause"].exists, "the controls are up")
    }

    /// In Quick Play, down from the URL field goes to the history, not to Clear or a row's remove button. The stream
    /// plays in the mini player so the history records it.
    func testDownFromQuickPlaysFieldReachesTheHistory() throws {
        guard let url = ProcessInfo.processInfo.environment["CONSOLATION_UI_NETWORK_URL"] else {
            throw XCTSkip("set CONSOLATION_UI_NETWORK_URL to an on-demand stream")
        }
        launch(["-ConsolationPane", "quickPlay", "-ConsolationPlayURL", url, "-ConsolationKeepPane", "YES"])
        let entry = app.buttons["quickPlay.historyItem"].firstMatch
        XCTAssertTrue(entry.waitForExistence(timeout: 15), "the stream is in the history")
        XCTAssertEqual(app.descendants(matching: .any).matching(NSPredicate(format: "hasFocus == true")).firstMatch
                        .elementType, .textField, "Quick Play starts on its field")
        press(.down)
        // The list's cell takes focus on Apple TV and shows the entry's URL.
        let host = URL(string: url)?.host() ?? url
        XCTAssertTrue(focusedLabels.contains { $0.contains(host) }, "down reaches the history (\(focusedLabels))")
    }

    /// "3:13" or "1:02:03" in seconds.
    private static func seconds(_ label: String?) -> Double {
        (label ?? "").split(separator: ":").reduce(0) { $0 * 60 + (Double($1) ?? 0) }
    }
}
