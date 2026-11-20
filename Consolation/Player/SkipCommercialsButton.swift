//
//  SkipCommercialsButton.swift
//  Consolation
//
//  The player's "Skip Commercials" button, in the lower right while playback is inside a suspected ad break
//  (`AdBreakSkipper`), above the controls while they show. On Apple TV it takes focus as the break starts (when the
//  video has it), so Select skips; Back dismisses it for the rest of the break, and focus returns to the video.
//

import MediaSourceKit
import SwiftUI

extension View {
    /// Shows Skip Commercials over the player during an ad break. `videoFocus`: the video's own focus, which the
    /// button takes from and gives back to on Apple TV.
    func skipCommercials(videoFocus: FocusState<Bool>.Binding) -> some View {
        modifier(SkipCommercialsModifier(videoFocus: videoFocus))
    }
}

private struct SkipCommercialsModifier: ViewModifier {
    @Environment(PlayerSession.self) private var session
    @Environment(AdBreakSkipper.self) private var adBreaks
    @Environment(ShellModel.self) private var shell
    let videoFocus: FocusState<Bool>.Binding
    @FocusState private var buttonFocused: Bool

    func body(content: Content) -> some View {
        content
            .overlay(alignment: .bottomTrailing) {
                if adBreaks.current != nil, !session.isMultiView {
                    button
                        .padding(.trailing, Self.trailingInset)
                        .padding(.bottom, session.controlsVisible ? Self.raisedInset : Self.bottomInset)
                        .transition(.opacity)
                }
            }
            .animation(.smooth(duration: 0.25), value: adBreaks.current)
            .animation(.smooth(duration: 0.25), value: session.controlsVisible)
            // A new item (or one playing on as a multi-view grid closes) is followed afresh.
            .task(id: FollowKey(item: session.item, isMultiView: session.isMultiView)) {
                await adBreaks.follow(session)
            }
            #if os(tvOS)
            .onChange(of: adBreaks.current) { old, new in breakChanged(from: old, to: new) }
            // The video getting focus during a break (at playback start, the controls or the menu closing) hands it
            // on: with the video focused, nothing else could reach the button.
            .onChange(of: videoFocus.wrappedValue) { _, videoFocused in
                if videoFocused { takeFocusIfOffered() }
            }
            .onChange(of: buttonFocused) { _, focused in adBreaks.buttonHasFocus = focused }
            #endif
    }

    private var button: some View {
        Button {
            adBreaks.skip(session)
            #if os(tvOS)
            videoFocus.wrappedValue = true
            #endif
        } label: {
            Label("Skip Commercials", systemImage: "forward.end.fill")
        }
        .buttonStyle(.glass)
        .accessibilityIdentifier("player.skipCommercials")
        #if os(tvOS)
        .focused($buttonFocused)
        .onExitCommand {
            adBreaks.dismiss()
            videoFocus.wrappedValue = true
        }
        .onPlayPauseCommand { session.togglePause() }
        #endif
    }

    #if os(tvOS)
    /// A break starting takes focus from the video; the button going away with focus gives it back, so focus is
    /// never left nowhere.
    private func breakChanged(from old: AdBreak?, to new: AdBreak?) {
        if new != nil, old == nil {
            takeFocusIfOffered()
        } else if new == nil, buttonFocused || adBreaks.buttonHasFocus {
            videoFocus.wrappedValue = true
        }
    }

    /// While a break is offered, the button takes focus from the video, never from the menu or the controls (it
    /// does once they hand focus back to the video).
    private func takeFocusIfOffered() {
        guard adBreaks.current != nil, !session.isMultiView, !shell.pillHasFocus, !session.controlsPinned
        else { return }
        // Once the button is on screen and the video's focus has settled.
        Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(100))
            guard adBreaks.current != nil, videoFocus.wrappedValue, !shell.pillHasFocus else { return }
            buttonFocused = true
        }
    }

    static let trailingInset: CGFloat = 80
    static let bottomInset: CGFloat = 60
    static let raisedInset: CGFloat = 270
    #else
    static let trailingInset: CGFloat = 28
    static let bottomInset: CGFloat = 28
    static let raisedInset: CGFloat = 170
    #endif
}

/// What `AdBreakSkipper.follow(_:)` restarts for.
private struct FollowKey: Equatable {
    let item: PlayingItem?
    let isMultiView: Bool
}
