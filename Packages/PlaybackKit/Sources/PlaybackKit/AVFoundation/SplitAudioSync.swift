//
//  SplitAudioSync.swift
//  PlaybackKit
//
//  The pure decisions that keep the audio player of a tone-mapped split (ToneMappedSplitPlan) in step with the
//  video player: when to start both together, when to pause the audio, and when to move it back into line with the
//  video. `SplitAudioFollower` samples both players into a `Snapshot` and carries out the `Action`. The video is
//  the master: it is never moved to follow the audio, so a correction never costs a video hiccup.
//

import Foundation

public nonisolated enum SplitAudioSync {
    /// Audio further than this from the video (either way) is moved back into line: 60 ms, inside the 40–80 ms
    /// range where viewers start to notice lip-sync errors.
    public static let driftTolerance = 0.060
    /// How often the follower samples both players.
    public static let checkInterval: Duration = .milliseconds(500)
    /// After a start or a correction, drift isn't judged for this long, while the audio timebase settles.
    public static let settleSeconds = 1.0
    /// Seconds between deciding to start both players and the shared host time they start at.
    public static let startLead = 0.15
    /// How far ahead of the running video the audio is cued when it joins: room for a seek and a preroll.
    public static let joinLead = 0.5
    /// A stalled video restarts once its buffer is likely to keep up, or after this long with some data.
    public static let restartTimeoutSeconds = 4.0

    public enum PlayerStatus: Equatable, Sendable {
        case paused
        case waiting
        case playing
    }

    public struct Snapshot: Equatable, Sendable {
        /// The user wants playback (not paused).
        public var wantsPlay: Bool
        /// Both players must be (re)started together: at first, after a stall, a seek or a resume.
        public var needsStart: Bool
        /// A start, join or seek is in flight.
        public var isSyncing: Bool
        public var video: PlayerStatus
        public var audio: PlayerStatus
        /// The video item is ready and its buffer likely to keep up (or full).
        public var videoLikelyToKeepUp: Bool
        /// The video buffer has something in it.
        public var videoHasData: Bool
        public var audioReady: Bool
        public var audioEnded: Bool
        /// Audio time minus video time at the same host time, in seconds; nil when either isn't running.
        public var drift: Double?
        /// Seconds since the last start or join; nil before the first.
        public var secondsSinceSync: Double?
        /// Seconds since `needsStart` was set.
        public var secondsWaiting: Double

        public init(wantsPlay: Bool, needsStart: Bool, isSyncing: Bool = false, video: PlayerStatus,
                    audio: PlayerStatus, videoLikelyToKeepUp: Bool, videoHasData: Bool = true, audioReady: Bool,
                    audioEnded: Bool = false, drift: Double? = nil, secondsSinceSync: Double? = nil,
                    secondsWaiting: Double = 0) {
            self.wantsPlay = wantsPlay
            self.needsStart = needsStart
            self.isSyncing = isSyncing
            self.video = video
            self.audio = audio
            self.videoLikelyToKeepUp = videoLikelyToKeepUp
            self.videoHasData = videoHasData
            self.audioReady = audioReady
            self.audioEnded = audioEnded
            self.drift = drift
            self.secondsSinceSync = secondsSinceSync
            self.secondsWaiting = secondsWaiting
        }
    }

    public enum Action: Equatable, Sendable {
        case none
        case pauseAudio
        /// Pause both, preroll both, then start both at the same item time and host time.
        case startBoth
        /// Cue the audio a little ahead of the running video and start it when the video reaches that time.
        case joinAudio
    }

    public static func decide(_ snapshot: Snapshot) -> Action {
        if snapshot.isSyncing { return .none }
        let audioRunning = snapshot.audio != .paused
        guard snapshot.wantsPlay else { return audioRunning ? .pauseAudio : .none }
        if snapshot.needsStart {
            let videoReady = snapshot.videoLikelyToKeepUp
                || (snapshot.videoHasData && snapshot.secondsWaiting >= restartTimeoutSeconds)
            if videoReady, snapshot.audioReady { return .startBoth }
            return audioRunning ? .pauseAudio : .none
        }
        guard snapshot.video == .playing else {
            // A stalled video, or one paused by the system (Picture in Picture controls, an interruption).
            return audioRunning ? .pauseAudio : .none
        }
        if snapshot.audioEnded || !snapshot.audioReady { return .none }
        guard snapshot.audio == .playing else { return .joinAudio }
        if let drift = snapshot.drift, abs(drift) > driftTolerance,
           (snapshot.secondsSinceSync ?? .infinity) >= settleSeconds {
            return .joinAudio
        }
        return .none
    }

    /// Both players start at `itemTime` (where the paused video is) at a host time `lead` seconds from now.
    public static func startTimes(itemTime: Double, hostNow: Double,
                                  lead: Double = startLead) -> (itemTime: Double, hostTime: Double) {
        (itemTime, hostNow + lead)
    }

    /// Where to cue the audio when it joins a video that is at `videoTime` at `hostNow`, moving at `rate`.
    public static func joinTarget(videoTime: Double, rate: Double, lead: Double = joinLead) -> Double {
        videoTime + lead * max(rate, 0)
    }

    /// The host time at which a video that is at `videoTime` at `hostNow`, moving at `rate`, reaches `itemTime`.
    /// Nil when the video isn't moving.
    public static func hostTime(reaching itemTime: Double, videoTime: Double, hostNow: Double,
                                rate: Double) -> Double? {
        guard rate > 0 else { return nil }
        return hostNow + (itemTime - videoTime) / rate
    }

    /// Audio time minus video time, both read at the same host time.
    public static func drift(audioTime: Double, videoTime: Double) -> Double {
        audioTime - videoTime
    }
}
