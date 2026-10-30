import Foundation
import MediaSourceKit
import PlaybackKit
import Testing
@testable import Consolation

/// Resume positions while a video plays: a restart from 0 (before the engine can seek to the saved position, or when
/// it can't) never overwrites the saved position until playback passes it, and live streams never finish. Fake
/// engines only.
@MainActor
struct ResumeRecorderTests {
    static let url = URL(string: "https://streams.example.com/vod/movie.mp4")!
    static let item = ResumeRecorder.itemID(for: .url(url))!

    /// A recorder whose position reader returns `position` (nil: live, or not known yet).
    final class Harness {
        let store = ResumeStore(documents: DefaultsDocumentStore(defaults: TestDefaults.make()))
        var position: Duration?
        var duration: Duration = .seconds(3_600)
        lazy var recorder = ResumeRecorder(store: store, readProgress: { [unowned self] _ in
            position.map { ($0, duration) }
        })
    }

    @Test func aRestartKeepsTheSavedPositionUntilPlaybackPassesIt() {
        let harness = Harness()
        harness.store.record(Self.item, position: .seconds(2_400), duration: .seconds(3_600))
        let engine = FakeEngine(state: .playing)
        harness.recorder.begin(.url(Self.url), engine: engine)

        // Continue Watching (or a foreground restart) starts at 0: the first samples change nothing.
        for seconds in [15, 600, 2_399] {
            harness.position = .seconds(seconds)
            harness.recorder.capture()
            #expect(harness.store.point(for: Self.item)?.progress.position == .seconds(2_400))
        }
        // Past the saved position (watched there, or the user sought beyond it), positions are saved again,
        // including going back afterwards.
        harness.position = .seconds(2_410)
        harness.recorder.capture()
        #expect(harness.store.point(for: Self.item)?.progress.position == .seconds(2_410))
        harness.position = .seconds(1_200)
        harness.recorder.capture()
        #expect(harness.store.point(for: Self.item)?.progress.position == .seconds(1_200))

        // Stopping early in the next playback keeps the newest position.
        harness.recorder.end()
        harness.recorder.begin(.url(Self.url), engine: FakeEngine(state: .playing))
        harness.position = .seconds(30)
        harness.recorder.end()
        #expect(harness.store.point(for: Self.item)?.progress.position == .seconds(1_200))
    }

    @Test func aFinishedVideoStartsOverFromNothing() {
        let harness = Harness()
        harness.store.markFinished(Self.item)
        harness.recorder.begin(.url(Self.url), engine: FakeEngine(state: .playing))
        harness.position = .seconds(45)
        harness.recorder.capture()
        let progress = harness.store.point(for: Self.item)?.progress
        #expect(progress?.position == .seconds(45))
        #expect(progress?.isFinished == false)
    }

    @Test func onlyOnDemandVideoFinishes() {
        let harness = Harness()
        let live = FakeEngine(state: .ended, isLive: true)
        harness.recorder.begin(.url(Self.url), engine: live)
        #expect(harness.recorder.capture() == false)
        #expect(harness.store.points.isEmpty)
        harness.recorder.end()

        // A stream with no known duration (raw MPEG-TS, live HLS) gives no position, so it never finishes either.
        harness.recorder.begin(.url(Self.url), engine: FakeEngine(state: .ended))
        harness.recorder.capture()
        #expect(harness.store.points.isEmpty)
        harness.recorder.end()

        harness.position = .seconds(3_600)
        harness.recorder.begin(.url(Self.url), engine: FakeEngine(state: .ended))
        #expect(harness.recorder.capture() == false)
        #expect(harness.store.point(for: Self.item)?.progress.isFinished == true)
    }
}
