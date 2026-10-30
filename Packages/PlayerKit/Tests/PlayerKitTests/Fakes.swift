import CoreGraphics
import Foundation
import Observation
import PlaybackKit
@testable import PlayerKit
import QuartzCore
#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// An engine that records what the session asks of it.
@Observable
final class FakeEngine: PlaybackEngine {
    let name: String
    var state: PlaybackState
    var streamInfo = PlaybackStreamInfo()
    let displayView = PlatformView(frame: .zero)
    var displayLayer: CALayer { CALayer() }
    var isMuted = false
    private(set) var startCount = 0
    private(set) var stopCount = 0
    private(set) var tiers: [DecodeTier] = []
    private(set) var decodeTier: DecodeTier = .single
    private(set) var audioChanges: [Bool] = []
    private(set) var volumes: [Float] = []

    var playsAudio = true {
        didSet { audioChanges.append(playsAudio) }
    }

    var volume: Float = 1 {
        didSet { volumes.append(volume) }
    }

    init(name: String, state: PlaybackState = .playing) {
        self.name = name
        self.state = state
    }

    func start() { startCount += 1 }
    func pause() {}
    func resume() {}
    func stop() {
        stopCount += 1
        state = .idle
    }

    func setDecodeTier(_ tier: DecodeTier) {
        tiers.append(tier)
        decodeTier = tier
    }
}

/// Makes `FakeEngine`s and remembers them by item.
final class EngineShop {
    private(set) var made: [FakeEngine] = []
    var startState: PlaybackState = .playing

    func make(_ item: String, _ tile: TileID) -> any PlaybackEngine {
        let engine = FakeEngine(name: item, state: startState)
        made.append(engine)
        return engine
    }

    func last(_ item: String) -> FakeEngine? {
        made.last { $0.name == item }
    }
}

final class FakeCapacity: TileCapacityProviding {
    typealias Item = String
    var answers: [String: TileAdmission] = [:]
    private(set) var asked: [(item: String, playing: [String])] = []

    func admission(for item: String, alongside playing: [String]) async -> TileAdmission {
        asked.append((item, playing))
        return answers[item] ?? .allowed(cost: .tuner, warning: nil)
    }
}

/// Timing that never waits: every sleep returns at once unless the task was cancelled.
let instantTiming = AudioFocusTiming(
    crossfadeSteps: 3,
    firstFrameTimeout: .milliseconds(500),
    sleep: { _ in
        await Task.yield()
        try Task.checkCancellation()
    }
)

func makeSession(budget: TileBudget = TileBudget(maximumTiles: 6), followsFocus: Bool = true,
                 capacity: FakeCapacity? = nil, shop: EngineShop) -> MultiViewSession<String> {
    let session = MultiViewSession<String>(
        budget: budget, audioFollowsFocus: followsFocus, capacity: capacity, timing: instantTiming,
        isUnavailable: { $0.code == 805 }, makeEngine: shop.make
    )
    session.containerSize = CGSize(width: 1920, height: 1080)
    return session
}
