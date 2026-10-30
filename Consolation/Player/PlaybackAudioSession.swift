//
//  PlaybackAudioSession.swift
//  Consolation
//
//  iOS, iPadOS and tvOS: the audio session for video playback. `.playback` plays with the silent switch on and lets
//  Picture in Picture keep sound in the background; multichannel content lets AC-3 reach an HDMI or AirPlay
//  receiver as 5.1. macOS has no audio session.
//
//  Activating, deactivating and configuring a session can block for a while, so all of it runs on one serial
//  background queue (never the main thread), in the order it was asked for. The category is set before the first
//  activation, because changing it while the session is active can stall audio, and again only after the Capture
//  Card viewer used `.playAndRecord` for its live audio (iPad): it records only while capture is active.
//

#if os(iOS) || os(tvOS)
import AVFoundation
import OSLog
#endif

enum PlaybackAudioSession {
    #if os(iOS) || os(tvOS)
    private nonisolated static let logger = Logger(subsystem: AppIdentifier.bundleID, category: "AudioSession")
    private nonisolated static let queue = DispatchQueue(label: AppIdentifier.scoped("audio-session"),
                                                         qos: .userInitiated)
    /// Only read and written on `queue`.
    private nonisolated(unsafe) static var isConfigured = false
    #endif

    /// Call before starting a stream. Returns at once; the session activates in the background.
    static func activate() {
        #if os(iOS) || os(tvOS)
        queue.async { activateOnQueue() }
        #endif
    }

    /// Call once nothing plays any more, so other apps' audio can resume. Returns at once.
    static func deactivate() {
        #if os(iOS) || os(tvOS)
        queue.async { deactivateOnQueue() }
        #endif
    }

    /// Call when the capture card viewer stops (iPad): its `.playAndRecord` session ends and `.playback` is back
    /// for the player. Returns at once.
    static func captureEnded() {
        #if os(iOS)
        queue.async {
            deactivateOnQueue()
            configureOnQueue(AVAudioSession.sharedInstance())
        }
        #endif
    }

    #if os(iOS) || os(tvOS)
    private nonisolated static func activateOnQueue() {
        let session = AVAudioSession.sharedInstance()
        // The capture card viewer may have left `.playAndRecord` behind.
        if !isConfigured || session.category != .playback { configureOnQueue(session) }
        do {
            try session.setActive(true)
        } catch {
            logger.error("Audio session activation failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func configureOnQueue(_ session: AVAudioSession) {
        do {
            #if os(iOS)
            try session.setCategory(.playback, mode: .moviePlayback, policy: .longFormVideo)
            #else
            try session.setCategory(.playback, mode: .moviePlayback)
            #endif
            try session.setSupportsMultichannelContent(true)
            isConfigured = true
        } catch {
            logger.error("Audio session configuration failed: \(error.localizedDescription, privacy: .public)")
        }
    }

    private nonisolated static func deactivateOnQueue() {
        do {
            try AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        } catch {
            // Expected while a renderer is still winding down; the next activation reuses the session.
            logger.debug("Audio session deactivation: \(error.localizedDescription, privacy: .public)")
        }
    }
    #endif
}
