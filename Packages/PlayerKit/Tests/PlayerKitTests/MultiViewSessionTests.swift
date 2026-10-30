import CoreGraphics
import PlaybackKit
@testable import PlayerKit
import Testing

struct MultiViewSessionTests {
    let shop = EngineShop()

    @Test func adoptKeepsThePlayingEngineWithoutRestarting() {
        let session = makeSession(shop: shop)
        let engine = FakeEngine(name: "9.1")
        let tile = session.adopt(engine: engine, item: "9.1")
        #expect(engine.startCount == 0)
        #expect(session.mode == .single(tile))
        #expect(session.audibleEngine === engine)
        #expect(engine.playsAudio)
        #expect(engine.tiers.isEmpty)
    }

    @Test func addStartsASilentGridTileAndAudioFollowsAfterTheDwell() async throws {
        let session = makeSession(shop: shop)
        let first = FakeEngine(name: "9.1")
        let tileA = session.adopt(engine: first, item: "9.1")
        let tileB = try await session.add("2.1")
        let second = try #require(shop.last("2.1"))
        #expect(second.startCount == 1)
        #expect(session.mode == .grid(focused: tileB))
        #expect(second.audioChanges.first == false)
        #expect(first.decodeTier == .full(fieldRate: false))
        #expect(second.decodeTier == .full(fieldRate: false))
        #expect(session.audibleTile == tileA)

        await session.settleAudio()
        #expect(session.audibleTile == tileB)
        #expect(second.playsAudio && second.volume == 1)
        #expect(!first.playsAudio && first.volume == 0)
        // The crossfade: old 1 → 0, new 0 → 1, in steps.
        #expect(first.volumes == [1, 2, 3].map { 1 - Float($0) / 3 })
        #expect(second.volumes == [0, 1, 2, 3].map { Float($0) / 3 })
    }

    @Test func audioWaitsForTheNewTilesFirstPicture() async throws {
        let session = makeSession(shop: shop)
        let first = FakeEngine(name: "9.1")
        session.adopt(engine: first, item: "9.1")
        shop.startState = .connecting
        try await session.add("2.1")
        await session.settleAudio()
        // It never showed a picture within the timeout: audio stays on the first tile.
        #expect(first.playsAudio && first.volume == 1)
        #expect(shop.last("2.1")?.playsAudio == false)
    }

    @Test func aFurtherMoveRestartsTheDwell() async throws {
        let session = makeSession(shop: shop)
        let first = FakeEngine(name: "a")
        session.adopt(engine: first, item: "a")
        let tileB = try await session.add("b")
        try await session.add("c")
        // Focus is on c; moving to b before the dwell ends cancels the move to c.
        #expect(session.focus(tile: tileB))
        await session.settleAudio()
        #expect(session.audibleEngine === shop.last("b"))
        #expect(shop.last("c")?.playsAudio == false)
        #expect(shop.last("c")?.volumes.isEmpty == true)
        #expect(shop.last("b")?.playsAudio == true)
    }

    @Test func movingBackToTheAudibleTileCancelsThePendingMove() async throws {
        let session = makeSession(shop: shop)
        let first = FakeEngine(name: "a")
        let tileA = session.adopt(engine: first, item: "a")
        try await session.add("b")
        #expect(session.focus(tile: tileA))
        await session.settleAudio()
        #expect(session.audibleTile == tileA)
        #expect(first.playsAudio && first.volume == 1)
        #expect(shop.last("b")?.playsAudio == false)
    }

    @Test func audioStaysOnTheLastForegroundTileWhenNotFollowingFocus() async throws {
        let session = makeSession(followsFocus: false, shop: shop)
        let first = FakeEngine(name: "a")
        let tileA = session.adopt(engine: first, item: "a")
        let tileB = try await session.add("b")
        await session.settleAudio()
        #expect(session.audibleTile == tileA)
        #expect(session.select(tileB) == .broughtForward)
        await session.settleAudio()
        #expect(session.audibleTile == tileB)
        #expect(shop.last("b")?.playsAudio == true)
        #expect(!first.playsAudio)
        #expect(first.decodeTier == .reduced)
        #expect(shop.last("b")?.decodeTier == .full(fieldRate: true))
        #expect(session.back())
        session.focus(tile: tileA)
        await session.settleAudio()
        #expect(session.audibleTile == tileB)
    }

    @Test func exitMultiViewStopsTheOthersAndKeepsTheFrontTile() async throws {
        let session = makeSession(shop: shop)
        let first = FakeEngine(name: "a")
        session.adopt(engine: first, item: "a")
        let tileB = try await session.add("b")
        try await session.add("c")
        session.focus(tile: tileB)
        session.select(tileB)
        let kept = session.exitMultiView()
        await session.settleAudio()
        #expect(kept == tileB)
        #expect(session.mode == .single(tileB))
        #expect(first.stopCount == 1)
        #expect(shop.last("c")?.stopCount == 1)
        #expect(shop.last("b")?.stopCount == 0)
        #expect(shop.last("b")?.playsAudio == true)
        #expect(shop.last("b")?.decodeTier == .full(fieldRate: true))
        #expect(session.tiles.map(\.id) == [tileB])
    }

    @Test func removeStopsTheEngineAndFallsBackToSingle() async throws {
        let session = makeSession(shop: shop)
        let first = FakeEngine(name: "a")
        let tileA = session.adopt(engine: first, item: "a")
        let tileB = try await session.add("b")
        await session.settleAudio()
        #expect(session.remove(tileB))
        await session.settleAudio()
        #expect(shop.last("b")?.stopCount == 1)
        #expect(session.mode == .single(tileA))
        #expect(first.playsAudio && first.volume == 1)
        #expect(first.decodeTier == .full(fieldRate: true))
        #expect(!session.remove(tileA))
    }

    @Test func budgetIsCheckedBeforeCapacity() async throws {
        let capacity = FakeCapacity()
        let session = makeSession(budget: TileBudget(maximumTiles: 2), capacity: capacity, shop: shop)
        session.start("a")
        try await session.add("b")
        await #expect(throws: MultiViewError.tileLimit(2)) {
            try await session.add("c")
        }
        #expect(capacity.asked.map(\.item) == ["b"])
        #expect(capacity.asked.first?.playing == ["a"])
    }

    @Test func capacityDenialIsReportedAndNothingStarts() async {
        let capacity = FakeCapacity()
        capacity.answers["5.1"] = .denied(reason: "All tuners are in use.")
        let session = makeSession(capacity: capacity, shop: shop)
        session.start("a")
        await #expect(throws: MultiViewError.unavailable(reason: "All tuners are in use.")) {
            try await session.add("5.1")
        }
        #expect(shop.last("5.1") == nil)
        #expect(session.tiles.count == 1)
    }

    @Test func admissionPassesWarningsThrough() async {
        let capacity = FakeCapacity()
        capacity.answers["7.1"] = .allowed(cost: .tuner, warning: "Taking the last free tuner…")
        let session = makeSession(capacity: capacity, shop: shop)
        session.start("a")
        #expect(await session.admission(for: "7.1") == .allowed(cost: .tuner, warning: "Taking the last free tuner…"))
        #expect(await session.admission(for: "2.1").isAllowed)
    }

    @Test func compactWidthLimitsAdding() async throws {
        let session = makeSession(shop: shop)
        session.containerSize = CGSize(width: 390, height: 844)
        session.start("a")
        try await session.add("b")
        #expect(session.addTileLimitReason != nil)
        await #expect(throws: MultiViewError.self) { try await session.add("c") }
    }

    @Test func replaceKeepsTheTileAndSwapsTheEngine() async throws {
        let capacity = FakeCapacity()
        let session = makeSession(capacity: capacity, shop: shop)
        let tileA = session.start("a")
        let oldEngine = try #require(shop.last("a"))
        try await session.replace(tileA, with: "z")
        let newEngine = try #require(shop.last("z"))
        #expect(oldEngine.stopCount == 1)
        #expect(newEngine.startCount == 1)
        #expect(session.tiles.map(\.id) == [tileA])
        #expect(session.tile(tileA)?.item == "z")
        #expect(newEngine.playsAudio && newEngine.volume == 1)
        #expect(capacity.asked.last?.playing == [])
    }

    @Test func tileStatusShowsUnavailable() {
        let session = makeSession(shop: shop)
        let tileA = session.start("a")
        let engine = shop.last("a")
        let busy = PlaybackError(kind: .source, title: "All tuners in use", code: 805)
        engine?.state = .failed(busy)
        #expect(session.tile(tileA)?.status == .unavailable(busy))
        let other = PlaybackError(kind: .network, title: "Lost")
        engine?.state = .failed(other)
        #expect(session.tile(tileA)?.status == .failed(other))
    }

    @Test func miniPresentationSuspendsAllButTheAudibleTile() async throws {
        let session = makeSession(shop: shop)
        let first = FakeEngine(name: "a")
        session.adopt(engine: first, item: "a")
        try await session.add("b")
        await session.settleAudio()
        session.presentation = .mini
        #expect(first.decodeTier == .suspended)
        #expect(shop.last("b")?.decodeTier == .full(fieldRate: true))
        session.presentation = .full
        #expect(first.decodeTier == .full(fieldRate: false))
    }

    @Test func snapshotAndRestoreAfterPictureInPicture() async throws {
        let session = makeSession(shop: shop)
        let first = FakeEngine(name: "a")
        session.adopt(engine: first, item: "a")
        let tileB = try await session.add("b")
        try await session.add("c")
        session.select(tileB)
        let snapshot = try #require(session.snapshot())
        #expect(snapshot == MultiViewSnapshot(items: ["a", "b", "c"], focusedIndex: 1, wasForeground: true))

        session.exitMultiView(keeping: tileB)
        let keptEngine = try #require(shop.last("b"))
        let failures = await session.restore(snapshot)
        #expect(failures.isEmpty)
        #expect(session.tiles.map(\.item) == ["a", "b", "c"])
        #expect(session.mode == .foreground(tileB))
        #expect(keptEngine.startCount == 1)
        #expect(session.tile(tileB)?.engine === keptEngine)
    }

    @Test func navigationThroughTheSession() async throws {
        let session = makeSession(shop: shop)
        let tileA = session.start("a")
        let tileB = try await session.add("b")
        #expect(session.focus(.leftward))
        #expect(session.mode == .grid(focused: tileA))
        #expect(!session.focus(.leftward))
        #expect(session.select(tileA) == .broughtForward)
        #expect(session.cycleForeground(forward: true))
        #expect(session.mode == .foreground(tileB))
        #expect(session.select(tileB) == .showControls)
        #expect(session.overlays == [.controls])
        #expect(session.back())
        #expect(session.back())
        #expect(!session.back())
        #expect(session.moveTile(tileA, by: 1))
        #expect(session.tiles.map(\.id) == [tileB, tileA])
        session.stopAll()
        #expect(session.isEmpty)
        #expect(shop.made.allSatisfy { $0.stopCount == 1 })
    }
}
