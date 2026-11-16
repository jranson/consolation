//
//  HostedVideoPlayer.swift
//  Consolation
//
//  Videos that play only in their hosting service's own embedded player (YouTube links from Quick Play, Home's
//  Quick Play cards and Bullpen bookmarks), never in our engines. On Mac, iPad and iPhone the embed shows in Now
//  Playing (`HostedVideoPane`) in place of the video surface, with the service's own controls; on Apple TV, which has
//  no WebKit, the video goes to the service's app (`HostedVideoHandOff`).
//
//  The embed and the engine player never play at once: starting one stops the other. The embed plays only while its
//  window shows Now Playing (the service's terms forbid hidden or background playback), so leaving Now Playing stops
//  it. PRIVACY.md says what the embed connects to.
//

import Foundation
import MediaSourceKit
import Observation

/// One play of a hosted video: the link, a title for Now Playing, and the Quick Play URL it came from, if any.
nonisolated struct HostedVideo: Hashable, Sendable, Identifiable {
    let link: HostedVideoLink
    let title: String
    /// Recorded in the Quick Play history once the video plays.
    let quickPlayURL: URL?
    /// Each play is its own, so playing the same video again starts it over.
    let id = UUID()

    init(link: HostedVideoLink, title: String? = nil, quickPlayURL: URL? = nil) {
        self.link = link
        self.title = title ?? String(localized: "YouTube Video")
        self.quickPlayURL = quickPlayURL
    }
}

@Observable
final class HostedVideoPlayer {
    /// Stops the engine player before the embed starts (set by `AppModel`).
    @ObservationIgnored var stopsEngines: () -> Void = {}
    /// Records a Quick Play URL once its video plays (set by `AppModel`).
    @ObservationIgnored var recordsHistory: (URL) -> Void = { _ in }

    /// The video in Now Playing, or nil.
    private(set) var current: HostedVideo?
    /// The window whose Now Playing shows the embed: the first to show Now Playing claims it.
    private(set) var window: UUID?
    /// Apple TV: why the video couldn't be handed to the service's app, shown until dismissed.
    var handOffFailure: String?

    var isActive: Bool { current != nil }

    /// Plays `url` when it is a hosted video link. Returns false (and does nothing) for any other URL.
    @discardableResult
    func play(_ url: URL, title: String? = nil) -> Bool {
        guard let link = HostedVideoLink(url: url) else { return false }
        play(HostedVideo(link: link, title: title, quickPlayURL: url))
        return true
    }

    /// Plays a video in the embed; Apple TV hands it to the service's app.
    func play(_ video: HostedVideo) {
        #if os(tvOS)
        HostedVideoHandOff.open(video.link) { [weak self] opened in
            guard let self else { return }
            if opened {
                if let url = video.quickPlayURL { self.recordsHistory(url) }
            } else {
                self.handOffFailure = HostedVideoHandOff.failureMessage
            }
        }
        #else
        stopsEngines()
        PlaybackAudioSession.activate()
        window = nil
        current = video
        #endif
    }

    /// A window showing Now Playing takes the embed if no window has it.
    func claim(for window: UUID) {
        guard current != nil, self.window == nil else { return }
        self.window = window
    }

    /// The embed reached the ready state: a Quick Play URL joins the history.
    func didBecomeReady(_ video: HostedVideo) {
        guard current?.id == video.id, let url = video.quickPlayURL else { return }
        recordsHistory(url)
    }

    /// Ends the embed (Done, leaving Now Playing, or the engine player starting).
    func stop() {
        guard current != nil else { return }
        current = nil
        window = nil
        PlaybackAudioSession.deactivate()
    }

    /// The window showing the embed left Now Playing or closed.
    func windowLeft(_ window: UUID) {
        if self.window == window { stop() }
    }
}
