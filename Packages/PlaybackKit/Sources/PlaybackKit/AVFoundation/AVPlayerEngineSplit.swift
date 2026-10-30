//
//  AVPlayerEngineSplit.swift
//  PlaybackKit
//
//  The tone-mapped split route. On a display that can't show HDR, AVPlayer filters every PQ and HLG variant out of a
//  multivariant playlist and refuses one with only HDR video, although it tone-maps an HDR media playlist played on its
//  own. So when a presentation offers only HDR video and the display isn't eligible, the main player (whose
//  AVPlayerLayer stays the display layer, so PiP, AirPlay, frame taps and fill keep working) plays the video variant's
//  media playlist, and a SplitAudioFollower plays the audio rendition's in sync. The route is chosen when the stream
//  loads, and taken as a fallback when AVPlayer rejects an HDR-only multivariant playlist anyway. HDR-capable displays
//  keep the multivariant playlist and its adaptive bit rate.
//

import AVFoundation
import CoreMedia
import Foundation
import os

extension AVPlayerEngine {
    nonisolated static let log = Logger(subsystem: "PlaybackKit", category: "AVPlayer")

    /// Whether the display can show HDR, read when a stream loads (a display change mid-stream keeps the route;
    /// a rejection after one falls back to the split).
    var isHDREligible: Bool {
        switch configuration.hdrEligibility {
        case .system: AVPlayer.eligibleForHDRPlayback
        case .eligible: true
        case .ineligible: false
        }
    }

    /// Moves playback to `seconds` (on-demand streams) with AVPlayer's default tolerance. A split pauses both
    /// players, seeks the video, and starts both together where it landed.
    public func seek(to seconds: TimeInterval) {
        seek(to: seconds, tolerance: .positiveInfinity)
    }

    /// Seeks within `tolerance` either side of `seconds`; `completion` gets whether the seek finished (false when
    /// a later one replaced it). A split's audio follows.
    func seek(to seconds: TimeInterval, tolerance: CMTime, completion: (@MainActor (Bool) -> Void)? = nil) {
        guard player.currentItem != nil, seconds.isFinite else {
            completion?(false)
            return
        }
        let time = CMTime(seconds: max(0, seconds), preferredTimescale: 600)
        if let follower {
            follower.seek(to: time, tolerance: tolerance, completion: completion)
        } else if let completion {
            let player = player
            Task {
                completion(await player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance))
            }
        } else {
            player.seek(to: time, toleranceBefore: tolerance, toleranceAfter: tolerance)
        }
    }

    func noteRoute(_ route: Route) {
        guard route != self.route else { return }
        self.route = route
        Self.log.info("AVPlayerEngine route: \(route.rawValue, privacy: .public)")
    }

    func stopFollower() {
        follower?.stop()
        follower = nil
    }

    /// Plays `playlist` as a split when the display can't show HDR and it offers only HDR video; true when it did.
    func splitIfNeeded(_ playlist: HLSMultivariantPlaylist, baseURL: URL, token: Int) -> Bool {
        guard ToneMappedSplitPlan.shouldSplit(playlist, hdrEligible: isHDREligible),
              let plan = ToneMappedSplitPlan(playlist: playlist, baseURL: baseURL) else { return false }
        playSplit(plan, reason: "display not HDR-eligible", token: token)
        return true
    }

    func canFallBackToSplit(after error: any Error) -> Bool {
        guard inputKind != .file, route != .toneMappedSplit, !attemptedSplit else { return false }
        return PlaybackErrorMapping.isHDRVariantRejection(error) || PlaybackErrorMapping.isMultivariantRejection(error)
    }

    /// AVPlayer refused the multivariant playlist: if it offers only HDR video, play it as a split instead.
    func beginSplitFallback(after error: any Error) {
        attemptedSplit = true
        let token = restartGeneration()
        loadTask = Task { [weak self] in
            await self?.splitAfterRejection(error, token: token)
        }
    }

    private func splitAfterRejection(_ rejection: any Error, token: Int) async {
        var known = knownMultivariant
        if known == nil, inputKind == .hls,
           let playlist = try? await HLSMultivariantRepair.fetchMultivariant(url: url, fetcher: makeFetcher()) {
            known = (playlist, url)
        }
        guard isCurrent(token) else { return }
        guard let known, ToneMappedSplitPlan.isHDROnly(known.playlist),
              let plan = ToneMappedSplitPlan(playlist: known.playlist, baseURL: known.baseURL) else {
            return fail(rejection)
        }
        playSplit(plan, reason: "multivariant playlist rejected", token: token)
    }

    func playSplit(_ plan: ToneMappedSplitPlan, reason: String, token: Int) {
        guard let item = prepareItem(asset: makeAsset(plan.videoURL), route: .toneMappedSplit, token: token) else {
            return
        }
        attemptedSplit = true
        let audio = plan.selectedAudio.map { "audio rendition \($0 + 1) of \(plan.renditions.count)" }
        Self.log.info("""
            AVPlayerEngine tone-mapped split (\(reason, privacy: .public)): \
            \(plan.videoRange.rawValue, privacy: .public) video at \(plan.bandwidth) bit/s, \
            \(audio ?? "no separate audio", privacy: .public)
            """)
        guard let audioURL = plan.selectedAudioURL else {
            player.automaticallyWaitsToMinimizeStalling = true
            player.replaceCurrentItem(with: item)
            if !isPausedByUser {
                player.play()
            }
            return
        }
        let audioItem = AVPlayerItem(asset: makeAsset(audioURL))
        audioItem.preferredForwardBufferDuration = configuration.preferredForwardBufferDuration
        let follower = SplitAudioFollower(video: player, videoItem: item, audioItem: audioItem,
                                          wantsPlay: !isPausedByUser) { [weak self] error in
            self?.handleFailure(error, token: token)
        }
        self.follower = follower
        applyMute()
        applyVolume()
        player.replaceCurrentItem(with: item)
        follower.start()
    }

    /// Failures that mean AVPlayer couldn't show the HDR video on this display, even tone-mapped.
    nonisolated static func isToneMappingFailure(_ error: (any Error)?) -> Bool {
        guard let error else { return false }
        if PlaybackErrorMapping.isHDRVariantRejection(error) { return true }
        let kind = PlaybackErrorMapping.playbackError(from: error).kind
        return kind == .decoder || kind == .unsupportedFormat
    }
}
