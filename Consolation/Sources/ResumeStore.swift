//
//  ResumeStore.swift
//  Consolation
//
//  Where the user stopped in videos that aren't live, the source of Home's Continue Watching. Kept on this device
//  only, never synced, and capped (tvOS keeps documents in UserDefaults, which has little room). Live channels
//  never get a resume position.
//

import Foundation
import MediaSourceKit
import Observation

@Observable
final class ResumeStore {
    /// The newest positions kept.
    static let maxEntries = 200
    /// Stopping earlier than this leaves nothing worth resuming.
    static let minimumPosition: Duration = .seconds(10)
    /// Watched this far, an item counts as finished and leaves Continue Watching.
    static let finishedFraction = 0.95

    private static let documentName = "resume-positions"
    private let documents: any DocumentStore

    /// Newest first.
    private(set) var points: [ResumePoint] = []

    init(documents: any DocumentStore = DocumentStores.platformDefault()) {
        self.documents = documents
        points = documents.load([ResumePoint].self, named: Self.documentName) ?? []
    }

    /// What Continue Watching shows: the positions not yet watched to the end, newest first.
    var unfinished: [ResumePoint] { points.filter { !$0.progress.isFinished } }

    func point(for item: MediaItemID) -> ResumePoint? {
        points.first { $0.item == item }
    }

    /// Saves where playback is now. Near the end it counts as finished; very early it saves nothing.
    func record(_ item: MediaItemID, position: Duration, duration: Duration?, at date: Date = .now) {
        guard item.channelKey == nil else { return }
        let finished = duration.map { $0 > .zero && position / $0 >= Self.finishedFraction } ?? false
        guard finished || position >= Self.minimumPosition else { return }
        upsert(ResumePoint(item: item, progress: PlaybackProgress(
            position: position, duration: duration, updatedAt: date, isFinished: finished)))
    }

    /// Playback reached the end.
    func markFinished(_ item: MediaItemID, at date: Date = .now) {
        guard item.channelKey == nil else { return }
        let previous = point(for: item)?.progress
        let duration = previous?.duration
        upsert(ResumePoint(item: item, progress: PlaybackProgress(
            position: duration ?? previous?.position ?? .zero, duration: duration, updatedAt: date,
            isFinished: true)))
    }

    func remove(_ item: MediaItemID) {
        let kept = points.filter { $0.item != item }
        guard kept.count != points.count else { return }
        points = kept
        save()
    }

    /// Drops the source's positions whose key isn't in `keys`, for example Quick Play videos no longer in the
    /// history.
    func retain(source: SourceID, keys: Set<String>) {
        let kept = points.filter { $0.item.source != source || keys.contains($0.item.key) }
        guard kept.count != points.count else { return }
        points = kept
        save()
    }

    func clear() {
        guard !points.isEmpty else { return }
        points = []
        save()
    }

    private func upsert(_ point: ResumePoint) {
        var updated = points.filter { $0.item != point.item }
        updated.insert(point, at: 0)
        if updated.count > Self.maxEntries { updated.removeLast(updated.count - Self.maxEntries) }
        points = updated
        save()
    }

    private func save() {
        documents.save(points.isEmpty ? nil : points, named: Self.documentName)
    }
}
