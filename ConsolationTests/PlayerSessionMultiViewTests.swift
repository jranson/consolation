import Foundation
import HTTPMPEG2Kit
import PlaybackKit
import PlayerKit
import Testing
@testable import Consolation

/// The player session's multi-view: tiles play through PlayerKit, added tiles get their own tuner slot and leave
/// the reserve alone, and the controls act on the target tile. Engines are fakes; nothing connects.
struct PlayerSessionMultiViewTests {
    /// Records each engine the session asks for, and whether it was an added tile.
    private final class Factory {
        var made: [MadeEngine] = []

        func session() -> PlayerSession {
            PlayerSession(preferences: PlaybackPreferences(defaults: TestDefaults.make())) { item, _, isAdded in
                let engine = FakeEngine()
                self.made.append(MadeEngine(item: item, isAdded: isAdded, engine: engine))
                return engine
            }
        }
    }

    private static func channel(_ number: String) -> LiveChannel {
        LiveChannel(key: "tvch:Antenna:\(number)", guideNumber: number, name: "K\(number)",
                    streamURL: URL(string: "http://192.0.2.10:5004/auto/v\(number)")!, isHD: true, favorite: .none)
    }

    @Test func addingATileKeepsTheFirstStreamPlaying() async {
        let factory = Factory()
        let session = factory.session()
        let list = ["2.1", "9.1"].map(Self.channel)
        session.play(list[0], within: list)
        #expect(await session.addToMultiView(.channel(list[1]), channels: list) == nil)
        #expect(session.isMultiView)
        #expect(factory.made.map(\.isAdded) == [false, true])
        #expect(factory.made.allSatisfy { !$0.engine.isStopped })
        // The new tile has focus: it is the target the controls act on.
        #expect(session.item == .channel(list[1]))
    }

    @Test func aFlipReplacesOnlyTheTargetTileAndExitKeepsIt() async throws {
        let factory = Factory()
        let session = factory.session()
        let list = ["2.1", "9.1", "31.1"].map(Self.channel)
        session.play(list[0], within: list)
        await session.addToMultiView(.channel(list[1]), channels: list)
        session.channelUp()
        try await Task.sleep(for: PlayerSession.channelFlipDebounce + .milliseconds(200))
        #expect(session.multiView.tiles.map(\.item) == [.channel(list[0]), .channel(list[2])])
        #expect(factory.made[1].engine.isStopped, "the flipped tile's old stream closed")
        #expect(!factory.made[0].engine.isStopped)

        session.exitMultiView()
        #expect(!session.isMultiView)
        #expect(session.item == .channel(list[2]))
        #expect(factory.made[0].engine.isStopped, "exit stops the other tiles")
    }

    @Test func stopEndsEveryTile() async {
        let factory = Factory()
        let session = factory.session()
        session.play(URL(string: "file:///one.ts")!)
        await session.addToMultiView(.url(URL(string: "file:///two.ts")!))
        session.stop()
        #expect(!session.isActive)
        #expect(factory.made.allSatisfy { $0.engine.isStopped })
    }

    @Test func brokerAdmissionsBecomeTileAdmissions() {
        #expect(TunerTileCapacity.translate(.needsTuner(deviceID: nil, capacity: nil, takesLastFreeTuner: false))
                == .allowed(cost: .tuner, warning: nil))
        if case .allowed(.tuner, let warning) = TunerTileCapacity.translate(
            .needsTuner(deviceID: nil, capacity: nil, takesLastFreeTuner: true)) {
            #expect(warning != nil)
        } else {
            Issue.record("the last free tuner is allowed, with a warning")
        }
        #expect(!TunerTileCapacity.translate(.unavailable(.noFreeTuner([]))).isAllowed)
    }
}

/// An engine the session asked for.
private struct MadeEngine {
    let item: PlayingItem
    let isAdded: Bool
    let engine: FakeEngine
}
