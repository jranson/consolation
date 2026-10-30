//
//  SplitAudioFollower.swift
//  PlaybackKit
//
//  The second, video-less AVPlayer of a tone-mapped split (ToneMappedSplitPlan), kept in step with the engine's
//  video player. Both run with `automaticallyWaitsToMinimizeStalling` off (required by `setRate(_:time:atHostTime:)`)
//  and on the host clock, so they share one time base and can't drift apart by audio-clock error. They start
//  together: preroll both, then the same item time at the same host time. Every half second, and whenever either
//  player's state changes, the follower samples both and acts on `SplitAudioSync.decide`: the audio pauses while the
//  video stalls or is paused by the system, both restart together once the video can play again, and audio that
//  drifts past the tolerance is cued ahead and rejoins the running video.
//

import AVFoundation
import CoreMedia
import Foundation

final class SplitAudioFollower {
    let audioPlayer: AVPlayer
    let audioItem: AVPlayerItem
    private let video: AVPlayer
    private let videoItem: AVPlayerItem
    private let onFailure: (any Error) -> Void

    /// The user wants playback; the engine's pause and resume set it.
    private(set) var wantsPlay: Bool
    private var needsStart = true
    private var waitStarted = ContinuousClock.now
    private var isSyncing = false
    private var lastSync: ContinuousClock.Instant?
    private var audioEnded = false
    /// Bumped by every operation, so an older one that resumes after an await gives up.
    private var operation = 0
    private var isStopped = false
    private var observations: [NSKeyValueObservation] = []
    private var tasks: [Task<Void, Never>] = []
    /// The start, join or seek in flight.
    private var syncTask: Task<Void, Never>?

    // Diagnostics and the opt-in network test.
    private(set) var startCount = 0
    private(set) var joinCount = 0
    private(set) var lastDrift: Double?
    private(set) var maxSettledDrift = 0.0

    init(video: AVPlayer, videoItem: AVPlayerItem, audioItem: AVPlayerItem, wantsPlay: Bool,
         onFailure: @escaping (any Error) -> Void) {
        self.video = video
        self.videoItem = videoItem
        self.audioItem = audioItem
        self.wantsPlay = wantsPlay
        self.onFailure = onFailure
        let audioPlayer = AVPlayer()
        audioPlayer.automaticallyWaitsToMinimizeStalling = false
        audioPlayer.sourceClock = CMClockGetHostTimeClock()
        audioPlayer.allowsExternalPlayback = false
        self.audioPlayer = audioPlayer
        video.automaticallyWaitsToMinimizeStalling = false
        video.sourceClock = CMClockGetHostTimeClock()
    }

    /// Loads the audio item and starts following. The engine has already put `videoItem` on the video player.
    func start() {
        audioPlayer.replaceCurrentItem(with: audioItem)
        observe()
        tasks.append(Task { [weak self] in
            while !Task.isCancelled {
                self?.tick()
                try? await Task.sleep(for: SplitAudioSync.checkInterval)
            }
        })
    }

    func stop() {
        guard !isStopped else { return }
        isStopped = true
        operation += 1
        observations.forEach { $0.invalidate() }
        observations = []
        tasks.forEach { $0.cancel() }
        tasks = []
        syncTask?.cancel()
        syncTask = nil
        audioPlayer.pause()
        audioPlayer.replaceCurrentItem(with: nil)
        video.sourceClock = nil
        video.automaticallyWaitsToMinimizeStalling = true
    }

    func pause() {
        wantsPlay = false
        operation += 1
        isSyncing = false
        video.pause()
        audioPlayer.pause()
    }

    func resume() {
        wantsPlay = true
        requireStart()
        tick()
    }

    /// Seeks the video, then restarts both together at wherever it landed (if the user wants playback).
    /// `completion` gets whether the video's seek finished.
    func seek(to time: CMTime, tolerance: CMTime = .positiveInfinity, completion: (@MainActor (Bool) -> Void)? = nil) {
        requireStart()
        operation += 1
        let current = operation
        isSyncing = true
        video.pause()
        audioPlayer.pause()
        let video = video
        syncTask = Task { [weak self] in
            let finished = await video.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
            completion?(finished)
            guard let self, self.isCurrent(current) else { return }
            self.isSyncing = false
            self.tick()
        }
    }

    // MARK: Sampling

    func tick() {
        guard !isStopped else { return }
        let snapshot = makeSnapshot()
        if let drift = snapshot.drift {
            lastDrift = drift
            if (snapshot.secondsSinceSync ?? 0) >= SplitAudioSync.settleSeconds, !snapshot.needsStart {
                maxSettledDrift = max(maxSettledDrift, abs(drift))
            }
        }
        switch SplitAudioSync.decide(snapshot) {
        case .none:
            break
        case .pauseAudio:
            audioPlayer.pause()
        case .startBoth:
            startBoth()
        case .joinAudio:
            joinAudio()
        }
    }

    func makeSnapshot() -> SplitAudioSync.Snapshot {
        let now = ContinuousClock.now
        let videoReady = video.status == .readyToPlay && videoItem.status == .readyToPlay
        return SplitAudioSync.Snapshot(
            wantsPlay: wantsPlay, needsStart: needsStart, isSyncing: isSyncing,
            video: Self.status(of: video), audio: Self.status(of: audioPlayer),
            videoLikelyToKeepUp: videoReady && (videoItem.isPlaybackLikelyToKeepUp || videoItem.isPlaybackBufferFull),
            videoHasData: videoReady && !videoItem.isPlaybackBufferEmpty,
            audioReady: audioPlayer.status == .readyToPlay && audioItem.status == .readyToPlay,
            audioEnded: audioEnded, drift: currentDrift(),
            secondsSinceSync: lastSync.map { Self.seconds(now - $0) },
            secondsWaiting: Self.seconds(now - waitStarted))
    }

    /// Audio minus video at one host time, while both timebases run.
    func currentDrift() -> Double? {
        guard let videoBase = videoItem.timebase, let audioBase = audioItem.timebase,
              CMTimebaseGetRate(videoBase) > 0, CMTimebaseGetRate(audioBase) > 0 else { return nil }
        let clock = CMClockGetHostTimeClock()
        let now = CMClockGetTime(clock)
        let videoTime = CMSyncConvertTime(now, from: clock, to: videoBase).seconds
        let audioTime = CMSyncConvertTime(now, from: clock, to: audioBase).seconds
        guard videoTime.isFinite, audioTime.isFinite else { return nil }
        return SplitAudioSync.drift(audioTime: audioTime, videoTime: videoTime)
    }

    // MARK: Actions

    private func startBoth() {
        operation += 1
        let current = operation
        isSyncing = true
        video.pause()
        audioPlayer.pause()
        let videoTime = video.currentTime()
        let itemTime = videoTime.isNumeric ? videoTime : .zero
        syncTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.audioPlayer.seek(to: itemTime, toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.isCurrent(current) else { return }
            await self.prerollBoth()
            guard self.isCurrent(current) else { return }
            let clock = CMClockGetHostTimeClock()
            let times = SplitAudioSync.startTimes(itemTime: itemTime.seconds, hostNow: CMClockGetTime(clock).seconds)
            let host = CMTime(seconds: times.hostTime, preferredTimescale: 1_000_000_000)
            self.video.setRate(1, time: itemTime, atHostTime: host)
            self.audioPlayer.setRate(1, time: itemTime, atHostTime: host)
            self.audioEnded = false
            self.finishSync()
            self.startCount += 1
        }
    }

    private func joinAudio() {
        guard let videoBase = videoItem.timebase else { return }
        operation += 1
        let current = operation
        isSyncing = true
        audioPlayer.pause()
        let clock = CMClockGetHostTimeClock()
        let now = CMClockGetTime(clock)
        let videoTime = CMSyncConvertTime(now, from: clock, to: videoBase).seconds
        let rate = Double(CMTimebaseGetRate(videoBase))
        guard videoTime.isFinite, rate > 0 else { return finishSync(counts: false) }
        let target = CMTime(seconds: SplitAudioSync.joinTarget(videoTime: videoTime, rate: rate),
                            preferredTimescale: 90_000)
        syncTask = Task { [weak self] in
            guard let self else { return }
            _ = await self.audioPlayer.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero)
            guard self.isCurrent(current) else { return }
            if self.audioPlayer.status == .readyToPlay, self.audioPlayer.rate == 0 {
                _ = await self.audioPlayer.preroll(atRate: 1)
            }
            guard self.isCurrent(current) else { return }
            // Re-read the video now: where it will be at the target decides the host time. A host time already
            // past is fine; the audio timebase is set as if it had been running since then.
            let hostNow = CMClockGetTime(clock)
            let videoNow = CMSyncConvertTime(hostNow, from: clock, to: videoBase).seconds
            guard let host = SplitAudioSync.hostTime(reaching: target.seconds, videoTime: videoNow,
                                                     hostNow: hostNow.seconds,
                                                     rate: Double(CMTimebaseGetRate(videoBase))) else {
                return self.finishSync(counts: false)
            }
            self.audioPlayer.setRate(1, time: target, atHostTime: CMTime(seconds: host,
                                                                         preferredTimescale: 1_000_000_000))
            self.finishSync()
            self.joinCount += 1
        }
    }

    private func prerollBoth() async {
        let audioPlayer = audioPlayer
        let audioDone: Task<Void, Never>? = audioPlayer.status == .readyToPlay && audioPlayer.rate == 0
            ? Task { _ = await audioPlayer.preroll(atRate: 1) } : nil
        if video.status == .readyToPlay, video.rate == 0 {
            _ = await video.preroll(atRate: 1)
        }
        await audioDone?.value
    }

    private func finishSync(counts: Bool = true) {
        isSyncing = false
        if counts {
            needsStart = false
            lastSync = .now
        }
    }

    private func requireStart() {
        if !needsStart { waitStarted = .now }
        needsStart = true
    }

    private func isCurrent(_ current: Int) -> Bool {
        current == operation && !isStopped
    }

    // MARK: Observation

    private func observe() {
        let refresh: @Sendable () -> Void = { [weak self] in
            Task { @MainActor [weak self] in self?.tick() }
        }
        observations = [
            video.observe(\.timeControlStatus) { @Sendable _, _ in refresh() },
            audioPlayer.observe(\.timeControlStatus) { @Sendable _, _ in refresh() },
            audioItem.observe(\.status) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.audioStatusChanged() }
            }
        ]
        let center = NotificationCenter.default
        tasks += [
            Task { [weak self, videoItem] in
                let name = AVPlayerItem.playbackStalledNotification
                for await _ in center.notifications(named: name, object: videoItem) {
                    guard let self, !self.isStopped else { return }
                    // Without automatic waiting the video's rate drops to 0 here; restart both once it can play.
                    self.requireStart()
                    self.audioPlayer.pause()
                }
            },
            Task { [weak self, audioItem] in
                let name = AVPlayerItem.didPlayToEndTimeNotification
                for await _ in center.notifications(named: name, object: audioItem) {
                    self?.audioEnded = true
                }
            },
            Task { [weak self, audioItem] in
                let name = AVPlayerItem.failedToPlayToEndTimeNotification
                for await note in center.notifications(named: name, object: audioItem) {
                    let error = note.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
                    self?.fail(error)
                }
            }
        ]
    }

    private func audioStatusChanged() {
        guard !isStopped else { return }
        if audioItem.status == .failed {
            fail(audioItem.error)
        } else {
            tick()
        }
    }

    private func fail(_ error: (any Error)?) {
        guard !isStopped else { return }
        onFailure(error ?? PlaybackError(kind: .source, title: "Can't play this stream's audio"))
    }

    nonisolated static func status(of player: AVPlayer) -> SplitAudioSync.PlayerStatus {
        switch player.timeControlStatus {
        case .playing: .playing
        case .waitingToPlayAtSpecifiedRate: .waiting
        case .paused: .paused
        @unknown default: .paused
        }
    }

    nonisolated static func seconds(_ duration: Duration) -> Double {
        let parts = duration.components
        return Double(parts.seconds) + Double(parts.attoseconds) / 1e18
    }
}
