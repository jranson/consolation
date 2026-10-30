//
//  PlayerControls.swift
//  Consolation
//
//  The player's controls: one row of buttons, then the timeline below it. The buttons, in order: Back 10 s, Play/Pause,
//  Forward 30 s (only with more than 30 s to the live edge or the end), Go to Live (live content behind its live edge
//  only), Stop, Mute, Multi-view, Full Screen, and "More" (captions, audio track and the rest). In multi-view they act
//  on the target tile (the front or focused one).
//

import PlaybackKit
import PlayerKit
import SwiftUI
#if os(macOS)
import AppKit
#endif

struct PlayerControls: View {
    @Environment(PlayerSession.self) private var session
    @Environment(ShellModel.self) private var shell
    /// Apple TV: focus for the Play/Pause button, which takes focus when Select brings the controls up.
    var playPauseFocus: FocusState<Bool>.Binding?

    /// How often the timeline (and the buttons that depend on it) is read while the controls are up.
    static let refreshInterval = 0.5
    static let backStep = -10.0
    static let forwardStep = 30.0

    var body: some View {
        TimelineView(.periodic(from: .now, by: Self.refreshInterval)) { _ in
            let timeline = session.engine?.timeline()
            VStack(spacing: 12) {
                buttons(timeline)
                if let timeline {
                    PlayerTimelineRow(timeline: timeline, onSeek: { position in
                        session.engine?.seek(toPosition: position)
                        session.showControlsBriefly()
                    }, onActivity: { session.showControlsBriefly() })
                }
            }
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 12)
        .frame(maxWidth: Self.maxWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
        .padding(.bottom, 28)
        .padding(.horizontal, 40)
    }

    #if os(tvOS)
    static let maxWidth: CGFloat = 1_300
    #else
    static let maxWidth: CGFloat = 760
    #endif

    private func buttons(_ timeline: PlaybackTimeline?) -> some View {
        HStack(spacing: PlayerControlMetrics.spacing) {
            if timeline != nil {
                controlButton("gobackward.10", label: "Back 10 Seconds") { skip(Self.backStep) }
            }
            playPauseOrRetry
            if let timeline, timeline.remaining > Self.forwardStep {
                controlButton("goforward.30", label: "Forward 30 Seconds") { skip(Self.forwardStep) }
            }
            if let timeline, timeline.isLive, !timeline.isAtLiveEdge {
                controlButton("forward.end.fill", label: "Go to Live") { goToLive(timeline) }
                    .accessibilityIdentifier("player.goToLive")
            }
            controlButton("stop.fill", label: "Stop") { session.stop() }
            controlButton(isMuted ? "speaker.slash.fill" : "speaker.wave.2.fill", label: isMuted ? "Unmute" : "Mute") {
                session.engine?.isMuted.toggle()
                session.showControlsBriefly()
            }
            multiViewButton
            fullScreenButton
            PlayerMoreMenu()
        }
    }

    /// Play/Pause, or on Apple TV Retry when the stream failed (the error card's Retry sits inside the video's
    /// Select target there).
    @ViewBuilder private var playPauseOrRetry: some View {
        #if os(tvOS)
        if case .failed = session.engine?.state {
            controlButton("arrow.clockwise", label: "Retry") { session.retry() }
        }
        #endif
        controlButton(isPaused ? "play.fill" : "pause.fill", label: isPaused ? "Play" : "Pause") {
            session.togglePause()
        }
        .modifier(OptionalFocus(binding: playPauseFocus))
        .accessibilityIdentifier("player.playPause")
    }

    /// One stream: add a tile. Several: the arrangement panel (Add Tile, Replace, Move, Remove, Exit Multi-view).
    @ViewBuilder private var multiViewButton: some View {
        if session.isMultiView {
            controlButton("square.grid.2x2", label: "Arrange Multi-view") {
                session.hideControls()
                session.multiView.present(.arrangement)
            }
            .accessibilityIdentifier("player.arrange")
        } else {
            controlButton("plus.rectangle.on.rectangle", label: "Add to Multi-view") { session.tilePicker = .add }
                .accessibilityIdentifier("player.addTile")
        }
    }

    /// The Mac: the window's full screen. Elsewhere the app is already full screen, so this fills the screen with
    /// the picture instead (Zoom to Fill, cropping the edges) or fits it again.
    @ViewBuilder private var fullScreenButton: some View {
        #if os(macOS)
        controlButton("arrow.up.left.and.arrow.down.right", label: "Full Screen") {
            NSApp.keyWindow?.toggleFullScreen(nil)
            session.showControlsBriefly()
        }
        #else
        controlButton(shell.fillsView ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right",
                      label: shell.fillsView ? "Fit to Screen" : "Zoom to Fill") {
            shell.fillsView.toggle()
            session.setFillsView(shell.fillsView, in: shell.id)
            session.showControlsBriefly()
        }
        #endif
    }

    private var isPaused: Bool {
        session.tunerReleased || session.engine?.state == .paused
    }

    private var isMuted: Bool { session.engine?.isMuted ?? false }

    private func skip(_ seconds: Double) {
        session.engine?.skip(by: seconds)
        session.showControlsBriefly()
    }

    private func goToLive(_ timeline: PlaybackTimeline) {
        if let live = session.liveControls {
            live.jumpToLive()
        } else {
            session.engine?.seek(toPosition: timeline.range.upperBound)
        }
        session.showControlsBriefly()
    }

    private func controlButton(_ symbol: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            PlayerControlIcon(systemName: symbol)
        }
        .playerControlStyle()
        .help(label)
        .accessibilityLabel(label)
    }
}

/// `.focused(binding)` when there is a binding.
private struct OptionalFocus: ViewModifier {
    let binding: FocusState<Bool>.Binding?

    func body(content: Content) -> some View {
        if let binding { content.focused(binding) } else { content }
    }
}
