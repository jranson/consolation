//
//  AVPlayerEngineObservation.swift
//  PlaybackKit
//
//  Key-value observation, notifications and a 1 Hz periodic refresh that map AVPlayer and AVPlayerItem to
//  PlaybackState and PlaybackStreamInfo. KVO can fire on any thread, so its handlers are @Sendable and hop to
//  the main actor; every callback carries the generation token so callbacks from a replaced item are dropped.
//

import AVFoundation
import CoreMedia
import Foundation

extension AVPlayerEngine {
    func observe(_ item: AVPlayerItem, token: Int) {
        observations = [
            item.observe(\.status, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in self?.itemStatusChanged(token: token) }
            },
            item.observe(\.presentationSize, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(token) else { return }
                    self.refreshStreamInfo()
                }
            },
            player.observe(\.timeControlStatus, options: [.new]) { @Sendable [weak self] _, _ in
                Task { @MainActor [weak self] in
                    guard let self, self.isCurrent(token) else { return }
                    self.updateStateFromPlayer()
                }
            }
        ]
        let center = NotificationCenter.default
        notificationTasks = [
            Task { [weak self] in
                for await _ in center.notifications(named: AVPlayerItem.didPlayToEndTimeNotification, object: item) {
                    guard let self, self.isCurrent(token) else { return }
                    self.noteEnded()
                }
            },
            Task { [weak self] in
                for await _ in center.notifications(named: AVPlayerItem.playbackStalledNotification, object: item) {
                    guard let self, self.isCurrent(token) else { return }
                    self.noteStall()
                }
            },
            Task { [weak self] in
                let name = AVPlayerItem.failedToPlayToEndTimeNotification
                for await notification in center.notifications(named: name, object: item) {
                    let error = notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? any Error
                    guard let self, self.isCurrent(token) else { return }
                    self.handleFailure(error, token: token)
                }
            }
        ]
        let interval = CMTime(seconds: 1, preferredTimescale: 600)
        timeObserver = player.addPeriodicTimeObserver(forInterval: interval, queue: .main) { @Sendable [weak self] _ in
            MainActor.assumeIsolated {
                guard let self, self.isCurrent(token), self.isItemReady else { return }
                self.refreshStreamInfo()
            }
        }
    }

    func tearDownItemObservers() {
        observations.forEach { $0.invalidate() }
        observations = []
        notificationTasks.forEach { $0.cancel() }
        notificationTasks = []
        if let timeObserver {
            player.removeTimeObserver(timeObserver)
        }
        timeObserver = nil
    }

    private func itemStatusChanged(token: Int) {
        guard isCurrent(token), let item = player.currentItem else { return }
        switch item.status {
        case .readyToPlay:
            guard !isItemReady else { return }
            isItemReady = true
            updateStateFromPlayer()
            refreshStreamInfo()
            seekToStartIfAsked(item)
            Task { [weak self] in await self?.loadSubtitleOptions(token: token) }
        case .failed:
            handleFailure(item.error, token: token)
        case .unknown:
            break
        @unknown default:
            break
        }
    }

    /// Updates size, live-ness and frame rate from the item, and loads codec facts from its tracks once.
    func refreshStreamInfo() {
        guard let item = player.currentItem else { return }
        var info = streamInfo
        let size = item.presentationSize
        if size.width > 0, size.height > 0 {
            info.width = Int(size.width.rounded())
            info.height = Int(size.height.rounded())
        }
        if item.status == .readyToPlay {
            info.isLive = item.duration.isIndefinite
        }
        if info.frameRate == nil {
            let rates = item.tracks.filter { $0.isEnabled }.map(\.currentVideoFrameRate).filter { $0 > 0 }
            info.frameRate = rates.first.flatMap { ISOFragment.snapped(Double($0)) }
        }
        setStreamInfo(info)
        if !hasLoadedTrackFormats, item.status == .readyToPlay, !item.tracks.isEmpty {
            hasLoadedTrackFormats = true
            let token = generation
            Task { [weak self] in
                await self?.loadTrackFormats(token: token)
            }
        }
    }

    /// Fills codec names, channel count and language that the manifest didn't provide, from format descriptions.
    private func loadTrackFormats(token: Int) async {
        // A tone-mapped split's audio is on the follower's item.
        let items = [player.currentItem, follower?.audioItem].compactMap { $0 }
        var facts = TrackFacts()
        for track in items.flatMap(\.tracks) where track.isEnabled {
            guard let assetTrack = track.assetTrack,
                  let descriptions = try? await assetTrack.load(.formatDescriptions),
                  let description = descriptions.first else { continue }
            let codec = HLSCodecs.displayName(of: Self.fourCCString(CMFormatDescriptionGetMediaSubType(description)))
            switch CMFormatDescriptionGetMediaType(description) {
            case kCMMediaType_Video:
                facts.videoCodec = facts.videoCodec ?? codec
            case kCMMediaType_Audio:
                facts.audioCodec = facts.audioCodec ?? codec
                if let basic = CMAudioFormatDescriptionGetStreamBasicDescription(description)?.pointee {
                    facts.audioChannels = facts.audioChannels ?? Int(basic.mChannelsPerFrame)
                }
                if facts.audioLanguage == nil {
                    facts.audioLanguage = try? await assetTrack.load(.languageCode)
                }
            default:
                break
            }
        }
        guard isCurrent(token) else { return }
        var info = streamInfo
        info.videoCodec = info.videoCodec ?? facts.videoCodec
        info.audioCodec = info.audioCodec ?? facts.audioCodec
        info.audioChannels = info.audioChannels ?? facts.audioChannels.flatMap { $0 > 0 ? $0 : nil }
        info.audioLanguage = info.audioLanguage ?? facts.audioLanguage
        setStreamInfo(info)
    }

    private nonisolated struct TrackFacts {
        var videoCodec: String?
        var audioCodec: String?
        var audioChannels: Int?
        var audioLanguage: String?
    }

    nonisolated static func fourCCString(_ code: FourCharCode) -> String {
        let bytes = [24, 16, 8, 0].map { UInt8((code >> $0) & 0xFF) }
        return String(bytes: bytes, encoding: .isoLatin1) ?? "????"
    }
}
