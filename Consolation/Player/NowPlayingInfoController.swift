//
//  NowPlayingInfoController.swift
//  Consolation
//
//  Publishes what's playing to the system (Control Center, the Mac's media keys and Now Playing menu, the Siri
//  Remote and lock screen) and handles its remote commands. Next and previous track are channel up and down.
//  Live streams are marked live, so the system shows no scrubber. On OS 27 this hands over to the NowPlaying
//  framework's MediaSession (`PlayerMediaSessionItem`); MediaPlayer's info center serves OS 26.
//

import MediaPlayer
import NowPlaying
import PlaybackKit

@MainActor
final class NowPlayingInfoController {
    private let session: PlayerSession
    private var targets: [(MPRemoteCommand, Any)] = []
    /// The OS 27 media session, type-erased so the stored property needs no availability.
    private var mediaSession: AnyObject?
    private var isPrimary = false

    init(session: PlayerSession) {
        self.session = session
        if #available(macOS 27, iOS 27, tvOS 27, *) {
            mediaSession = MediaSession(PlayerMediaSessionItem(session: session))
        } else {
            registerCommands()
        }
    }

    /// Call when the item or playback state changes.
    func update() {
        if #available(macOS 27, iOS 27, tvOS 27, *),
           let mediaSession = mediaSession as? MediaSession<PlayerMediaSessionItem> {
            // The session follows the player by observation; it only has to claim the app's Now Playing once.
            guard session.isActive, !isPrimary else { return }
            isPrimary = true
            Task {
                do {
                    try await mediaSession.requestToBecomeApplicationPrimary()
                } catch {
                    self.isPrimary = false
                }
            }
            return
        }
        let center = MPNowPlayingInfoCenter.default()
        guard let item = session.item, let engine = session.engine else {
            center.nowPlayingInfo = nil
            center.playbackState = .stopped
            return
        }
        let names = item.nowPlayingNames
        var info: [String: Any] = [
            MPMediaItemPropertyTitle: names.title,
            MPNowPlayingInfoPropertyIsLiveStream: item.isLive,
            MPNowPlayingInfoPropertyMediaType: MPNowPlayingInfoMediaType.video.rawValue,
            MPNowPlayingInfoPropertyPlaybackRate: engine.state == .playing ? 1.0 : 0.0
        ]
        if let subtitle = names.subtitle { info[MPMediaItemPropertyArtist] = subtitle }
        center.nowPlayingInfo = info
        center.playbackState = engine.state == .paused ? .paused : .playing
    }

    private func registerCommands() {
        let center = MPRemoteCommandCenter.shared()
        add(center.togglePlayPauseCommand) { $0.session.togglePause() }
        add(center.playCommand) { controller in
            if controller.session.engine?.state == .paused || controller.session.tunerReleased {
                controller.session.togglePause()
            }
        }
        add(center.pauseCommand) { controller in
            if controller.session.engine?.state == .playing { controller.session.togglePause() }
        }
        add(center.nextTrackCommand) { $0.session.channelUp() }
        add(center.previousTrackCommand) { $0.session.channelDown() }
        add(center.stopCommand) { $0.session.stop() }
    }

    private func add(_ command: MPRemoteCommand, _ action: @escaping @MainActor (NowPlayingInfoController) -> Void) {
        command.isEnabled = true
        let target = command.addTarget { [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.session.isActive else { return }
                action(self)
            }
            return .success
        }
        targets.append((command, target))
    }
}
