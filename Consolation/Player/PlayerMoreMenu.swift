//
//  PlayerMoreMenu.swift
//  Consolation
//
//  The controls' "More" (…) menu: captions and the audio track, then the less frequent actions (Picture in Picture,
//  Exit or Restore Multi-view, the technical stats).
//

import PlaybackKit
import PlayerKit
import SwiftUI

struct PlayerMoreMenu: View {
    @Environment(PlayerSession.self) private var session
    @Environment(PlaybackPreferences.self) private var preferences

    var body: some View {
        Menu {
            captionItems
            audioTrackItems
            Section {
                if session.canPictureInPicture {
                    Button(session.isPictureInPictureActive ? "Exit Picture in Picture" : "Picture in Picture",
                           systemImage: session.isPictureInPictureActive ? "pip.exit" : "pip.enter") {
                        session.togglePictureInPicture()
                    }
                }
                if session.isMultiView {
                    Button("Exit Multi-view", systemImage: "rectangle.inset.filled") { session.exitMultiView() }
                } else if session.multiViewSnapshot != nil {
                    Button("Restore Multi-view", systemImage: "square.grid.2x2.fill") { session.restoreMultiView() }
                }
                Button(session.statsVisible ? "Hide Stats" : "Show Stats", systemImage: "chart.bar.xaxis") {
                    session.statsVisible.toggle()
                }
            }
        } label: {
            PlayerControlIcon(systemName: "ellipsis.circle")
        }
        .playerControlStyle()
        .menuIndicator(.hidden)
        .fixedSize()
        .accessibilityLabel("More")
        .accessibilityIdentifier("player.more")
    }

    /// Live MPEG-TS: Off or one of the caption services the stream has carried (CC1–CC4). AVPlayer content: Off or
    /// one of its subtitle renditions, drawn by the system in the user's caption style.
    @ViewBuilder private var captionItems: some View {
        if let subtitles = session.engine as? any SubtitleSelecting, !subtitles.subtitleOptions.isEmpty {
            Section("Subtitles") {
                check("Off", subtitles.selectedSubtitleID == nil) { subtitles.selectSubtitle(id: nil) }
                ForEach(subtitles.subtitleOptions) { option in
                    let name = option.isClosedCaptions ? "\(option.displayName) (CC)" : option.displayName
                    check(name, subtitles.selectedSubtitleID == option.id) { subtitles.selectSubtitle(id: option.id) }
                }
            }
        } else if let captions = session.engine as? any CaptionProviding, !captions.availableCaptionServices.isEmpty {
            Section("Captions") {
                check("Off", !preferences.captionsEnabled) { preferences.captionsEnabled = false }
                ForEach(captions.availableCaptionServices, id: \.self) { service in
                    let selected = preferences.captionsEnabled && captions.captionService == service
                    check("\(service)".uppercased(), selected) {
                        captions.selectCaptionService(service)
                        preferences.captionsEnabled = true
                    }
                }
            }
        }
    }

    /// For example English 5.1 or the Spanish 2.0 second audio program.
    @ViewBuilder private var audioTrackItems: some View {
        if let selector = session.engine as? any AudioTrackSelecting, selector.audioTracks.count > 1 {
            Section("Audio") {
                ForEach(selector.audioTracks) { track in
                    check(track.displayName, track.id == selector.selectedAudioTrackID) {
                        selector.selectAudioTrack(id: track.id)
                    }
                }
            }
        }
    }

    private func check(_ title: String, _ isSelected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            if isSelected { Label(title, systemImage: "checkmark") } else { Text(title) }
        }
    }
}
