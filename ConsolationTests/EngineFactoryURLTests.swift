import Foundation
import HTTPMPEG2Kit
import PlaybackKit
import Testing
@testable import Consolation

/// Which engine a Quick Play URL gets: raw MPEG-TS and Matroska never go to AVPlayer, which can't open them.
/// Engines are made but never started, so no request leaves the process.
@MainActor
struct EngineFactoryURLTests {
    private let factory = EngineFactory(preferences: PlaybackPreferences(defaults: TestDefaults.make()),
                                        broker: TunerBroker())

    @Test func matroskaURLsPlayInTheMatroskaEngine() {
        for text in ["https://media.example.com/movies/Movie.mkv", "file:///Users/someone/Movies/Clip.webm",
                     "http://192.0.2.20:8096/stream?container=mkv"] {
            let engine = factory.makeEngine(for: .url(URL(string: text)!))
            #expect(engine is MatroskaEngine, "\(text)")
            #expect(engine.state == .idle)
        }
    }

    @Test func otherURLsKeepTheirEngines() {
        #expect(factory.makeEngine(for: .url(URL(string: "https://media.example.com/a.ts")!))
            is TransportStreamEngine)
        #expect(factory.makeEngine(for: .url(URL(string: "https://media.example.com/a.m3u8")!)) is AVPlayerEngine)
        #expect(factory.makeEngine(for: .url(URL(string: "https://media.example.com/a.mp4")!)) is AVPlayerEngine)
    }
}
