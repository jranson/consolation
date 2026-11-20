//
//  AdBreakSkipper.swift
//  Consolation
//
//  "Skip Commercials": while a library item plays (a Bullpen recording), its source's suspected ad breaks are read
//  once playback starts, and whenever playback is inside one the player offers to skip to where the program resumes.
//  Breaks are only suspected, so nothing is skipped unless the viewer asks. Back (Apple TV) dismisses the offer for
//  the rest of that break.
//

import Foundation
import MediaSourceKit
import Observation
import PlaybackKit

@Observable
final class AdBreakSkipper {
    typealias Loader = @MainActor (MediaItemID) async -> AdBreakList

    /// The break playing now, offered to skip; nil outside a break, or once Back dismissed it.
    private(set) var current: AdBreak?
    /// Apple TV: Skip Commercials has focus (the player's chrome leaves the controls alone meanwhile).
    var buttonHasFocus = false

    /// The item's breaks, in seconds from its start.
    @ObservationIgnored var breaks: [AdBreak] = []
    @ObservationIgnored private var dismissed: AdBreak?
    @ObservationIgnored private let load: Loader

    /// How often the position is read while an item with breaks plays.
    static let pollInterval: Duration = .milliseconds(500)
    /// How soon a server still detecting is asked again.
    static let pendingRetry: Duration = .seconds(60)

    init(load: @escaping Loader) {
        self.load = load
    }

    /// Follows the session's stream while it plays one library item: reads its breaks, then where playback is,
    /// until cancelled (the item changes, or the player's chrome leaves the screen). Reads nothing for live
    /// channels and URLs, and polls nothing for an item without breaks.
    func follow(_ session: PlayerSession) async {
        reset()
        defer { reset() }
        #if DEBUG
        if Self.offersTestBreak { return await followTestBreak(session) }
        #endif
        guard case .media(let media) = session.item, !media.isLive else { return }
        var list = await load(media.item)
        var nextLoad = list.isPending ? ContinuousClock.now + Self.pendingRetry : nil
        while !Task.isCancelled {
            breaks = list.breaks
            guard !breaks.isEmpty || nextLoad != nil else { return }
            offer(at: Self.position(in: session))
            try? await Task.sleep(for: Self.pollInterval)
            if let due = nextLoad, ContinuousClock.now >= due, !Task.isCancelled {
                list = await load(media.item)
                nextLoad = list.isPending ? ContinuousClock.now + Self.pendingRetry : nil
            }
        }
    }

    /// Where the single stream plays, in seconds from the media's start; nil in multi-view or before it can seek.
    static func position(in session: PlayerSession) -> Double? {
        guard !session.isMultiView, let timeline = session.engine?.timeline() else { return nil }
        return timeline.elapsed
    }

    /// Offers the break playing at `position`, unless it was dismissed. Leaving a dismissed break forgets the
    /// dismissal, so coming back to it (a seek) offers it again.
    func offer(at position: Double?) {
        let playing = position.flatMap { AdBreak.playing(at: $0, in: breaks) }
        if playing != dismissed { dismissed = nil }
        let offered = playing == dismissed ? nil : playing
        if offered != current { current = offered }
    }

    /// Skip Commercials: playback continues where the program resumes.
    func skip(_ session: PlayerSession) {
        guard let current else { return }
        if let engine = session.engine, let timeline = engine.timeline() {
            engine.seek(toPosition: timeline.range.lowerBound + current.end)
        }
        // Until the engine reports the new position, the break stays out of the offer.
        dismiss()
    }

    /// Back on Skip Commercials: no offer for the rest of this break.
    func dismiss() {
        dismissed = current
        current = nil
    }

    #if DEBUG
    /// `-ConsolationTestAdBreak YES` (UI tests): whatever plays is in an ad break, with no server and no seeking.
    static var offersTestBreak: Bool { UserDefaults.standard.bool(forKey: "ConsolationTestAdBreak") }

    private func followTestBreak(_ session: PlayerSession) async {
        breaks = [AdBreak(start: 0, end: .greatestFiniteMagnitude)]
        while !Task.isCancelled {
            offer(at: session.isActive && !session.isMultiView ? 1 : nil)
            try? await Task.sleep(for: Self.pollInterval)
        }
    }
    #endif

    private func reset() {
        breaks = []
        dismissed = nil
        if current != nil { current = nil }
    }
}
