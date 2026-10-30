//
//  PlayerSessionPictureInPicture.swift
//  Consolation
//
//  One Picture in Picture button for every platform and engine. macOS's system PiP crops sample-buffer video (it
//  mirrors the layer 1:1 into the PiP panel), so on the Mac live TV uses the app's own floating video window instead.
//  AVPlayer content, iPhone, iPad and Apple TV use system PiP.
//

import AVFoundation
import PlaybackKit
import PlayerKit

extension PlayerSession {
    /// Whether this engine's PiP is the app's floating window rather than the system's.
    static func usesFloatingWindow(for engine: any PlaybackEngine) -> Bool {
        #if os(macOS)
        !(engine.displayLayer is AVPlayerLayer)
        #else
        false
        #endif
    }

    /// Whether the PiP button should show.
    var canPictureInPicture: Bool {
        guard let engine = pictureInPictureEngine else { return false }
        if Self.usesFloatingWindow(for: engine) { return true }
        guard let pictureInPicture else { return false }
        return pictureInPicture.isPossible || pictureInPicture.isActive
    }

    /// Whether the video is in PiP (system or floating) now.
    var isPictureInPictureActive: Bool {
        isFloating || pictureInPicture?.isActive == true
    }

    /// In multi-view, Picture in Picture keeps the audible tile and stops the others; the controls then offer "Restore
    /// Multi-view".
    func togglePictureInPicture() {
        guard let engine = pictureInPictureEngine else { return }
        if isMultiView, !isPictureInPictureActive {
            multiViewSnapshot = multiView.snapshot()
            multiView.exitMultiView(keeping: multiView.audibleTile)
        }
        if Self.usesFloatingWindow(for: engine) {
            isFloating.toggle()
        } else {
            pictureInPicture?.toggle()
        }
    }
}
