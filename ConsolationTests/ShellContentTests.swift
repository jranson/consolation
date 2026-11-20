//
//  ShellContentTests.swift
//  ConsolationTests
//
//  The menu lists only panes with something to show: Live TV with a tuner, Library with a library server ("Libraries"
//  with more than one), Now Playing while something plays. A pane that leaves the menu while on screen goes back.
//

import Foundation
import Testing
@testable import Consolation

@MainActor
struct ShellContentTests {
    private static func defaults() -> UserDefaults {
        UserDefaults(suiteName: "ConsolationTests.\(UUID().uuidString)") ?? .standard
    }

    /// Settings whose content the test sets through `content`.
    private final class Box {
        var content = ShellContent(tunerCount: 0, libraryCount: 0, isPlaying: false)
    }

    private static func settings(_ box: Box) -> PillSettings {
        let settings = PillSettings(defaults: defaults())
        settings.readContent = { box.content }
        return settings
    }

    @Test func emptyPanesLeaveTheMenu() {
        let box = Box()
        let settings = Self.settings(box)
        #expect(!settings.visibleItems.contains(.liveTV))
        #expect(!settings.visibleItems.contains(.library))
        #expect(!settings.visibleItems.contains(.nowPlaying))
        #expect(settings.visibleItems.contains(.home))
        #expect(settings.visibleItems.contains(.quickPlay))
        #expect(settings.visibleItems.contains(.settings))
        box.content = ShellContent(tunerCount: 1, libraryCount: 1, isPlaying: true)
        #expect(settings.visibleItems.contains(.liveTV))
        #expect(settings.visibleItems.contains(.library))
        #expect(settings.visibleItems.contains(.nowPlaying))
    }

    @Test func libraryIsPluralWithMoreThanOneServer() {
        let one = ShellContent(tunerCount: 0, libraryCount: 1, isPlaying: false)
        let two = ShellContent(tunerCount: 0, libraryCount: 2, isPlaying: false)
        #expect(String(localized: one.title(for: .library)) == "Library")
        #expect(String(localized: two.title(for: .library)) == "Libraries")
        #expect(String(localized: two.title(for: .liveTV)) == "Live TV")
    }

    @Test func emptyPanesAreNeverRestored() {
        let empty = ShellContent(tunerCount: 0, libraryCount: 0, isPlaying: false)
        #expect(ShellModel.restorable(.liveTV, hidden: [], content: empty) == .home)
        #expect(ShellModel.restorable(.library, hidden: [], content: empty) == .home)
        #expect(ShellModel.restorable(.quickPlay, hidden: [], content: empty) == .quickPlay)
    }

    @Test func playbackEndingInNowPlayingReturnsToTheLastPane() {
        let box = Box()
        box.content.isPlaying = true
        let shell = ShellModel(settings: Self.settings(box), defaults: Self.defaults())
        shell.selection = .quickPlay
        shell.selection = .nowPlaying
        box.content.isPlaying = false
        shell.leaveSelectionIfNotVisible()
        #expect(shell.selection == .quickPlay)
    }

    @Test func removingTheLastTunerOnLiveTVGoesHome() {
        let box = Box()
        box.content.tunerCount = 1
        let shell = ShellModel(settings: Self.settings(box), defaults: Self.defaults())
        shell.selection = .liveTV
        box.content.tunerCount = 0
        shell.leaveSelectionIfNotVisible()
        #expect(shell.selection == .home)
    }
}
