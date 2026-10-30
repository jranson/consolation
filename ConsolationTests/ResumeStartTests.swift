import AppKit
import CoreGraphics
import Foundation
import MediaSourceKit
import PlaybackKit
import QuartzCore
import Testing
@testable import Consolation

/// Continue Watching starts at the saved position: once the engine can seek (its timeline is known), on-demand
/// playback jumps there; live content and short positions start where they are. Fake engines only.
@MainActor
struct ResumeStartTests {
    static let url = URL(string: "https://streams.example.com/vod/movie.mp4")!
    static let item = ResumeRecorder.itemID(for: .url(url))!

    private static func recorder(saving position: Duration) -> ResumeRecorder {
        let store = ResumeStore(documents: DefaultsDocumentStore(defaults: TestDefaults.make()))
        store.record(item, position: position, duration: .seconds(3_600))
        return ResumeRecorder(store: store, readProgress: { _ in nil })
    }

    @Test func onDemandPlaybackStartsAtTheSavedPosition() async {
        let recorder = Self.recorder(saving: .seconds(2_400))
        let engine = SeekableFakeEngine(isLive: false)
        recorder.begin(.url(Self.url), engine: engine)
        #expect(await waitUntil { engine.seeks == [2_400] })
        recorder.end()
    }

    @Test func liveContentAndEarlyPositionsStartWhereTheyAre() async throws {
        let live = SeekableFakeEngine(isLive: true)
        let liveRecorder = Self.recorder(saving: .seconds(2_400))
        liveRecorder.begin(.url(Self.url), engine: live)
        let early = SeekableFakeEngine(isLive: false)
        let earlyRecorder = Self.recorder(saving: .seconds(5))
        earlyRecorder.begin(.url(Self.url), engine: early)
        try await Task.sleep(for: .milliseconds(600))
        #expect(live.seeks.isEmpty)
        #expect(early.seeks.isEmpty)
        liveRecorder.end()
        earlyRecorder.end()
    }
}

/// An engine whose timeline is known at once and which records seeks.
@MainActor
final class SeekableFakeEngine: PlaybackEngine {
    var state: PlaybackState = .playing
    var streamInfo = PlaybackStreamInfo()
    let displayLayer = CALayer()
    let displayView = PlatformView(frame: .zero)
    var isMuted = false
    private(set) var seeks: [Double] = []
    private let isLive: Bool

    init(isLive: Bool) {
        self.isLive = isLive
        streamInfo.isLive = isLive
    }

    func start() {}
    func pause() {}
    func resume() {}
    func stop() {}

    func timeline() -> PlaybackTimeline? {
        PlaybackTimeline(range: 0...3_600, position: 0, isLive: isLive)
    }

    func seek(toPosition position: Double) {
        seeks.append(position)
    }
}
