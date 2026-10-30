//
//  PictureInPicture.swift
//  PlaybackKit
//
//  System Picture in Picture for any engine: AVPlayerLayer-backed engines use the player layer directly, and
//  sample-buffer engines (live MPEG-TS) use a sample-buffer content source. Live streams report an infinite time
//  range, so the PiP window shows no scrubber.
//

import AVFoundation
import AVKit
import Observation

@Observable
public final class PictureInPicture: NSObject {
    public private(set) var isActive = false
    public private(set) var isPossible = false

    @ObservationIgnored private var controller: AVPictureInPictureController?
    @ObservationIgnored private weak var engine: (any PlaybackEngine)?
    @ObservationIgnored private var possibleObservation: NSKeyValueObservation?

    public static var isSupported: Bool { AVPictureInPictureController.isPictureInPictureSupported() }

    /// Prepares PiP for `engine`'s display layer. Returns nil where PiP isn't supported.
    public init?(engine: any PlaybackEngine) {
        guard Self.isSupported else { return nil }
        self.engine = engine
        super.init()
        let source: AVPictureInPictureController.ContentSource
        if let playerLayer = engine.displayLayer as? AVPlayerLayer {
            source = .init(playerLayer: playerLayer)
        } else if let sampleLayer = engine.displayLayer as? AVSampleBufferDisplayLayer {
            source = .init(sampleBufferDisplayLayer: sampleLayer, playbackDelegate: self)
        } else {
            return nil
        }
        let controller = AVPictureInPictureController(contentSource: source)
        controller.delegate = self
        self.controller = controller
        let options: NSKeyValueObservingOptions = [.initial, .new]
        possibleObservation = controller.observe(\.isPictureInPicturePossible, options: options) { [weak self] pip, _ in
            let possible = pip.isPictureInPicturePossible
            Task { @MainActor in self?.isPossible = possible }
        }
    }

    public func toggle() {
        guard let controller else { return }
        if controller.isPictureInPictureActive {
            controller.stopPictureInPicture()
        } else {
            controller.startPictureInPicture()
        }
    }

    public func stop() {
        controller?.stopPictureInPicture()
    }

    /// iOS: start PiP on its own when the app goes to the background while this content plays inline. Only for
    /// content that is the user's primary focus (the full-screen player). No effect elsewhere.
    public var startsAutomatically: Bool {
        get {
            #if os(iOS)
            controller?.canStartPictureInPictureAutomaticallyFromInline ?? false
            #else
            false
            #endif
        }
        set {
            #if os(iOS)
            controller?.canStartPictureInPictureAutomaticallyFromInline = newValue
            #endif
        }
    }
}

extension PictureInPicture: AVPictureInPictureControllerDelegate {
    // Active from "will start", so a host checking during the move to the background (automatic PiP) keeps playing.
    nonisolated public func pictureInPictureControllerWillStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { self.isActive = true }
        } else {
            Task { @MainActor in self.isActive = true }
        }
    }

    nonisolated public func pictureInPictureControllerDidStartPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = true }
    }

    nonisolated public func pictureInPictureControllerDidStopPictureInPicture(
        _ pictureInPictureController: AVPictureInPictureController) {
        Task { @MainActor in self.isActive = false }
    }
}

extension PictureInPicture: AVPictureInPictureSampleBufferPlaybackDelegate {
    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                       setPlaying playing: Bool) {
        Task { @MainActor in
            guard let engine = self.engine else { return }
            if playing { engine.resume() } else { engine.pause() }
        }
    }

    nonisolated public func pictureInPictureControllerTimeRangeForPlayback(
        _ pictureInPictureController: AVPictureInPictureController) -> CMTimeRange {
        // Live: an infinite range hides the scrubber.
        CMTimeRange(start: .negativeInfinity, duration: .positiveInfinity)
    }

    nonisolated public func pictureInPictureControllerIsPlaybackPaused(
        _ pictureInPictureController: AVPictureInPictureController) -> Bool {
        MainActor.assumeIsolated { self.engine?.state == .paused }
    }

    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                       didTransitionToRenderSize newRenderSize: CMVideoDimensions) {}

    nonisolated public func pictureInPictureController(_ pictureInPictureController: AVPictureInPictureController,
                                                       skipByInterval skipInterval: CMTime) async {
        await MainActor.run {
            (self.engine as? any LivePlaybackControlling)?.skip(seconds: skipInterval.seconds)
        }
    }
}
