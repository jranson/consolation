//
//  NowPlayingMediaSession.swift
//  Consolation
//
//  OS 27: what's playing, published through the NowPlaying framework's MediaSession (Control Center, the Mac's
//  media keys and Now Playing menu, the Siri Remote). It observes the player session, so it updates itself.
//  Live streams have a live duration (no scrubber), next and previous are channel up and down, and nothing is
//  offered to the system's suggestions.
//

import Foundation
import NowPlaying
import Observation
import PlaybackKit

@available(macOS 27, iOS 27, tvOS 27, *)
@Observable
final class PlayerMediaSessionItem: MediaSessionRepresentable {
    @ObservationIgnored private let session: PlayerSession

    init(session: PlayerSession) {
        self.session = session
    }

    nonisolated let id = AppIdentifier.scoped("player")

    var content: (any MediaContentRepresentable)? {
        guard let item = session.item else { return nil }
        let names = item.nowPlayingNames
        var content = GenericContent(id: item.id, title: names.title, subtitle: names.subtitle, type: .video,
                                     duration: item.isLive ? .live : nil, artwork: nil)
        content.isExcludedFromSuggestions = true
        return content
    }

    var playbackSnapshot: MediaPlaybackSnapshot? {
        guard session.isActive else { return MediaPlaybackSnapshot(state: .stopped) }
        if session.tunerReleased || session.releasedForBackground { return MediaPlaybackSnapshot(state: .paused) }
        switch session.engine?.state {
        case .playing: return MediaPlaybackSnapshot(state: .playing())
        case .paused: return MediaPlaybackSnapshot(state: .paused)
        case .connecting, .buffering: return MediaPlaybackSnapshot(state: .buffering)
        default: return MediaPlaybackSnapshot(state: .stopped)
        }
    }

    var commands: [MediaCommand] {
        let isChannel = session.currentChannel != nil
        return [
            .togglePlayPause { [weak self] in self?.session.togglePause() },
            .play { [weak self] in self?.resumeIfPaused() },
            .pause { [weak self] in self?.pauseIfPlaying() },
            .stop { [weak self] in self?.session.stop() },
            .next { [weak self] in self?.session.channelUp() }.enabled(isChannel),
            .previous { [weak self] in self?.session.channelDown() }.enabled(isChannel)
        ]
    }

    private func resumeIfPaused() {
        if session.engine?.state == .paused || session.tunerReleased { session.togglePause() }
    }

    private func pauseIfPlaying() {
        if session.engine?.state == .playing { session.togglePause() }
    }
}
