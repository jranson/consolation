import CoreGraphics
import PlaybackKit
@testable import PlayerKit
import Testing

struct RolesTests {
    let tileA = TileID()
    let tileB = TileID()
    let tileC = TileID()

    private func grid() -> MultiViewState {
        var state = MultiViewState(tile: tileA)
        state.add(tileB)
        state.add(tileC)
        return state
    }

    @Test func singleTileIsFullFieldRateWithAudio() {
        let roles = TileRoles.assign(state: MultiViewState(tile: tileA), presentation: .full, audioFollowsFocus: true)
        #expect(roles[tileA] == TileRole(tier: .full(fieldRate: true), playsAudio: true))
    }

    @Test func gridTilesAreFrameRateAndOnlyTheAudibleOneSounds() {
        let roles = TileRoles.assign(state: grid(), presentation: .full, audioFollowsFocus: true)
        #expect(roles[tileA] == TileRole(tier: .full(fieldRate: false), playsAudio: true))
        #expect(roles[tileB] == TileRole(tier: .full(fieldRate: false), playsAudio: false))
        #expect(roles[tileC] == TileRole(tier: .full(fieldRate: false), playsAudio: false))
    }

    @Test func tilesBehindTheForegroundAreReducedAndSilent() {
        var state = grid()
        state.select(tileB)
        let roles = TileRoles.assign(state: state, presentation: .full, audioFollowsFocus: true)
        #expect(roles[tileB] == TileRole(tier: .full(fieldRate: true), playsAudio: true))
        #expect(roles[tileA] == TileRole(tier: .reduced, playsAudio: false))
        #expect(roles[tileC] == TileRole(tier: .reduced, playsAudio: false))
    }

    @Test(arguments: [PlayerPresentation.mini, .hidden])
    func miniAndHiddenDecodeOnlyTheAudibleTile(presentation: PlayerPresentation) {
        var state = grid()
        state.select(tileC)
        let roles = TileRoles.assign(state: state, presentation: presentation, audioFollowsFocus: true)
        #expect(roles[tileC] == TileRole(tier: .full(fieldRate: true), playsAudio: true))
        #expect(roles[tileA]?.tier == .suspended)
        #expect(roles[tileB]?.tier == .suspended)
    }

    @Test func reducedResourcesDegradeAllButThePrimaryTile() {
        var state = grid()
        let gridRoles = TileRoles.assign(state: state, presentation: .full, audioFollowsFocus: true,
                                         reducedResources: true)
        #expect(gridRoles[tileA]?.tier == .full(fieldRate: false))
        #expect(gridRoles[tileB]?.tier == .reduced)
        state.select(tileB)
        let frontRoles = TileRoles.assign(state: state, presentation: .full, audioFollowsFocus: true,
                                          reducedResources: true)
        #expect(frontRoles[tileB]?.tier == .full(fieldRate: true))
        #expect(frontRoles[tileA]?.tier == .keyframesOnly)
    }

    @Test func degradeSteps() {
        #expect(TileRoles.degraded(.full(fieldRate: true)) == .full(fieldRate: false))
        #expect(TileRoles.degraded(.full(fieldRate: false)) == .reduced)
        #expect(TileRoles.degraded(.reduced) == .keyframesOnly)
        #expect(TileRoles.degraded(.keyframesOnly) == .suspended)
        #expect(TileRoles.degraded(.suspended) == .suspended)
    }
}

struct BudgetTests {
    @Test func capsComeFromCPUGridAndWidth() {
        let budget = TileBudget(maximumTiles: 6)
        #expect(budget.limit(containerWidth: 1200) == 6)
        #expect(budget.limit(containerWidth: 390) == 2)
        #expect(budget.limit(containerWidth: nil) == 6)
        #expect(TileBudget(maximumTiles: 12).limit(containerWidth: 1920) == 9)
        #expect(budget.admitsTile(after: 5, containerWidth: 1200))
        #expect(!budget.admitsTile(after: 6, containerWidth: 1200))
        #expect(!budget.admitsTile(after: 2, containerWidth: 390))
    }

    @Test func platformDefault() {
        #if os(macOS)
        #expect(TileBudget.platformDefault.maximumTiles == 6)
        #else
        #expect(TileBudget.platformDefault.maximumTiles == 4)
        #endif
    }
}
