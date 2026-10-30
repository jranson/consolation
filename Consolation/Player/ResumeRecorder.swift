//
//  ResumeRecorder.swift
//  Consolation
//
//  Saves where on-demand playback is (Quick Play videos today) every few seconds and when it stops, for Home's
//  Continue Watching. Live channels and live streams never get a position, and never count as finished. Engines
//  can't start at a saved position yet, so playing a video again starts at 0: a saved position is kept until
//  playback passes it (or the user seeks past it), never overwritten by the first seconds of a restart.
//

import AVFoundation
import CoreMedia
import Foundation
import MediaSourceKit
import PlaybackKit

final class ResumeRecorder {
    /// Reads an engine's position and duration; nil for live streams and before the duration is known.
    typealias ProgressReader = @MainActor (any PlaybackEngine) -> (position: Duration, duration: Duration)?

    /// How often a playing video's position is saved.
    static let sampleInterval: Duration = .seconds(15)

    private let store: ResumeStore
    private let allows: (MediaItemID) -> Bool
    private let readProgress: ProgressReader
    private var current: (item: MediaItemID, engine: any PlaybackEngine)?
    /// The unfinished position saved before this playback began. Nothing earlier is saved until playback passes
    /// it, so a restart from 0 never replaces it.
    private var baseline: Duration?
    private var sampler: Task<Void, Never>?
    /// Waits for the engine to be able to seek, then starts at the saved position.
    private var resumer: Task<Void, Never>?

    /// Saved positions closer to the start than this play from the beginning.
    static let minimumResume: Duration = .seconds(10)
    /// How long to wait for a stream to become seekable before giving up and playing from the start.
    static let resumeTimeout: Duration = .seconds(30)

    /// - Parameters:
    ///   - allows: whether an item may be remembered at all.
    ///   - readProgress: reads the engine's position; tests inject one.
    init(store: ResumeStore, allows: @escaping (MediaItemID) -> Bool = { _ in true },
         readProgress: @escaping ProgressReader = ResumeRecorder.progress(of:)) {
        self.store = store
        self.allows = allows
        self.readProgress = readProgress
    }

    /// Quick Play positions are kept only while Quick Play history is on: a position is history too.
    convenience init(store: ResumeStore, history: QuickPlayHistory) {
        self.init(store: store, allows: { [weak history] item in
            item.source != .quickPlay || history?.isEnabled == true
        })
    }

    isolated deinit {
        sampler?.cancel()
    }

    /// The identity a position is saved under, or nil for live channels. Quick Play URLs use the Quick Play
    /// source's hashed key, never the URL.
    static func itemID(for item: PlayingItem) -> MediaItemID? {
        switch item {
        case .channel: nil
        case .url(let url): MediaItemID(source: .quickPlay, key: QuickPlaySource.itemKey(for: url))
        case .media(let media): media.isLive ? nil : media.item
        }
    }

    /// Follows a newly started engine. Whatever was followed before is saved first.
    func begin(_ item: PlayingItem, engine: any PlaybackEngine) {
        end()
        guard let itemID = Self.itemID(for: item) else { return }
        current = (itemID, engine)
        baseline = store.point(for: itemID).flatMap { $0.progress.isFinished ? nil : $0.progress.position }
        if let baseline { resume(engine, at: baseline) }
        sampler = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: Self.sampleInterval)
                guard !Task.isCancelled, let self, self.capture() else { return }
            }
        }
    }

    /// Saves the position and stops following the engine. Call it before the engine stops.
    func end() {
        capture()
        resumer?.cancel()
        resumer = nil
        sampler?.cancel()
        sampler = nil
        current = nil
        baseline = nil
    }

    /// Saves the position now. False once playback ended or failed, so the sampler stops.
    @discardableResult
    func capture() -> Bool {
        guard let current else { return false }
        let item = current.item
        let engine = current.engine
        guard allows(item) else { return true }
        switch engine.state {
        case .ended:
            // Only on-demand video finishes; a live stream (live HLS, MPEG-TS) that ends just stopped.
            if !engine.streamInfo.isLive, readProgress(engine) != nil { store.markFinished(item) }
            return false
        case .failed:
            return false
        case .idle, .connecting:
            return true
        case .playing, .paused, .buffering:
            guard let progress = readProgress(engine) else { return true }
            if let baseline {
                guard progress.position >= baseline else { return true }
                self.baseline = nil
            }
            store.record(item, position: progress.position, duration: progress.duration)
            return true
        }
    }

    /// Continue Watching: once the engine knows its timeline (an on-demand stream), seek to the saved position.
    private func resume(_ engine: any PlaybackEngine, at position: Duration) {
        guard position >= Self.minimumResume else { return }
        let seconds = Double(position.components.seconds) + Double(position.components.attoseconds) / 1e18
        resumer = Task { [weak self] in
            let deadline = ContinuousClock.now + Self.resumeTimeout
            while !Task.isCancelled, ContinuousClock.now < deadline {
                if let timeline = engine.timeline() {
                    guard !timeline.isLive, seconds < timeline.range.upperBound else { return }
                    engine.seek(toPosition: seconds)
                    // Playing on from there: the saved point no longer holds back new saves.
                    self?.baseline = nil
                    return
                }
                if case .failed = engine.state { return }
                try? await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// Position and duration of on-demand playback; nil for live streams, the TS engine (always live), and
    /// before the duration is known.
    static func progress(of engine: any PlaybackEngine) -> (position: Duration, duration: Duration)? {
        guard let player = engine as? AVPlayerEngine, !player.streamInfo.isLive,
              let duration = player.playerLayer.player?.currentItem?.duration,
              duration.isNumeric, !duration.isIndefinite else { return nil }
        let seconds = duration.seconds
        guard seconds.isFinite, seconds > 0 else { return nil }
        return (.seconds(player.currentTime), .seconds(seconds))
    }
}
