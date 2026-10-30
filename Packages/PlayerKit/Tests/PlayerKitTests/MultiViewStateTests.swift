@testable import PlayerKit
import Testing

/// The multi-view state machine's transitions.
struct MultiViewStateTests {
    let tileA = TileID()
    let tileB = TileID()
    let tileC = TileID()
    let tileD = TileID()
    let wide = GridShape(columns: 2, rows: 2)

    private func grid(_ tiles: [TileID]) -> MultiViewState {
        var state = MultiViewState(tile: tiles[0])
        for tile in tiles.dropFirst() { state.add(tile) }
        return state
    }

    @Test func playingAnItemIsSingle() {
        let state = MultiViewState(tile: tileA)
        #expect(state.mode == .single(tileA))
        #expect(state.audibleTile(followsFocus: true) == tileA)
        #expect(!state.isMultiView)
    }

    @Test func addingFromSingleFocusesTheNewTileAndKeepsAudio() {
        var state = MultiViewState(tile: tileA)
        let step1 = state.add(tileB)
        #expect(step1)
        #expect(state.mode == .grid(focused: tileB))
        #expect(state.tiles == [tileA, tileB])
        // Audio stays on A until the session commits the focus dwell.
        #expect(state.audibleTile(followsFocus: true) == tileA)
        #expect(state.audibleTile(followsFocus: false) == tileA)
        let step2 = state.add(tileB)
        #expect(!step2)
    }

    @Test func gridFocusMovesToNeighborsWithoutWrapping() {
        var state = grid([tileA, tileB, tileC, tileD])
        state.focus(tileA)
        let step3 = state.move(.rightward, shape: wide)
        #expect(step3)
        #expect(state.mode == .grid(focused: tileB))
        let step4 = state.move(.rightward, shape: wide)
        #expect(!step4)
        let step5 = state.move(.upward, shape: wide)
        #expect(!step5)
        let step6 = state.move(.downward, shape: wide)
        #expect(step6)
        #expect(state.mode == .grid(focused: tileD))
        let step7 = state.move(.leftward, shape: wide)
        #expect(step7)
        #expect(state.mode == .grid(focused: tileC))
        let step8 = state.move(.leftward, shape: wide)
        #expect(!step8)
    }

    @Test func selectBringsForwardThenShowsControls() {
        var state = grid([tileA, tileB])
        let step9 = state.select(tileA)
        #expect(step9 == .broughtForward)
        #expect(state.mode == .foreground(tileA))
        #expect(state.audibleTile(followsFocus: false) == tileA)
        let step10 = state.select(tileA)
        #expect(step10 == .showControls)
        #expect(state.overlays == [.controls])
        let step11 = state.select(TileID())
        #expect(step11 == .ignored)
    }

    @Test func selectInSingleShowsControls() {
        var state = MultiViewState(tile: tileA)
        let step12 = state.select(tileA)
        #expect(step12 == .showControls)
        #expect(state.topOverlay == .controls)
    }

    @Test func backPopsOverlaysThenForegroundThenNothing() {
        var state = grid([tileA, tileB])
        state.select(tileB)
        state.select(tileB)
        state.present(.arrangement)
        #expect(state.overlays == [.controls, .arrangement])
        let step13 = state.back()
        #expect(step13)
        #expect(state.overlays == [.controls])
        let step14 = state.back()
        #expect(step14)
        #expect(state.mode == .foreground(tileB))
        let step15 = state.back()
        #expect(step15)
        #expect(state.mode == .grid(focused: tileB))
        let step16 = state.back()
        #expect(!step16)
    }

    @Test func presentingAnOverlayAgainMovesItToTheTop() {
        var state = MultiViewState(tile: tileA)
        state.present(.arrangement)
        state.present(.controls)
        state.present(.arrangement)
        #expect(state.overlays == [.controls, .arrangement])
        state.dismiss(.controls)
        #expect(state.overlays == [.arrangement])
    }

    @Test func foregroundArrowsCycleInReadingOrderAndUpReturns() {
        var state = grid([tileA, tileB, tileC])
        state.select(tileC)
        let step17 = state.move(.rightward, shape: wide)
        #expect(step17)
        #expect(state.mode == .foreground(tileA))
        let step18 = state.move(.leftward, shape: wide)
        #expect(step18)
        #expect(state.mode == .foreground(tileC))
        #expect(state.audibleTile(followsFocus: true) == tileC)
        let step19 = state.move(.downward, shape: wide)
        #expect(!step19)
        let step20 = state.move(.upward, shape: wide)
        #expect(step20)
        #expect(state.mode == .grid(focused: tileC))
    }

    @Test func singleIgnoresDirections() {
        var state = MultiViewState(tile: tileA)
        for direction in TileDirection.allCases {
            let moved = state.move(direction, shape: wide)
            #expect(!moved)
        }
    }

    @Test func removingDownToOneTileIsSingle() {
        var state = grid([tileA, tileB])
        state.present(.controls)
        let step21 = state.remove(tileB)
        #expect(step21)
        #expect(state.mode == .single(tileA))
        #expect(state.overlays.isEmpty)
        let step22 = state.remove(tileA)
        #expect(!step22)
    }

    @Test func removingTheFocusedTileFocusesANeighbor() {
        var state = grid([tileA, tileB, tileC])
        state.focus(tileB)
        state.remove(tileB)
        #expect(state.mode == .grid(focused: tileC))
        state.remove(tileC)
        #expect(state.mode == .single(tileA))
    }

    @Test func removingTheFrontTileReturnsToTheGrid() {
        var state = grid([tileA, tileB, tileC])
        state.select(tileC)
        state.remove(tileC)
        #expect(state.mode == .grid(focused: tileB))
        #expect(state.audibleTile(followsFocus: false) == tileB)
    }

    @Test func removingAnotherTileKeepsTheFront() {
        var state = grid([tileA, tileB, tileC])
        state.select(tileA)
        state.remove(tileB)
        #expect(state.mode == .foreground(tileA))
    }

    @Test func replaceKeepsPositionFocusAndAudio() {
        var state = grid([tileA, tileB])
        state.select(tileB)
        let step23 = state.replace(tileB, with: tileC)
        #expect(step23)
        #expect(state.tiles == [tileA, tileC])
        #expect(state.mode == .foreground(tileC))
        #expect(state.audibleTile(followsFocus: true) == tileC)
        let step24 = state.replace(tileB, with: tileD)
        #expect(!step24)
    }

    @Test func moveSwapsWithTheNeighborInReadingOrder() {
        var state = grid([tileA, tileB, tileC])
        let step25 = state.moveTile(tileA, by: 1)
        #expect(step25)
        #expect(state.tiles == [tileB, tileA, tileC])
        let step26 = state.moveTile(tileB, by: -1)
        #expect(!step26)
        let step27 = state.moveTile(tileC, by: 1)
        #expect(!step27)
    }

    @Test func exitMultiViewKeepsTheFrontTile() {
        var state = grid([tileA, tileB, tileC])
        state.select(tileB)
        state.select(tileB)
        let removed = state.exitMultiView()
        #expect(Set(removed) == [tileA, tileC])
        #expect(state.mode == .single(tileB))
        #expect(state.overlays.isEmpty)
    }

    @Test func exitMultiViewFromTheGridKeepsTheFocusedOrChosenTile() {
        var state = grid([tileA, tileB, tileC])
        state.focus(tileA)
        state.exitMultiView()
        #expect(state.mode == .single(tileA))
        var other = grid([tileA, tileB, tileC])
        other.exitMultiView(keeping: tileC)
        #expect(other.tiles == [tileC])
    }

    @Test func gridAudioFollowsCommittedFocusOrStaysOnLastForeground() {
        var state = grid([tileA, tileB, tileC])
        state.select(tileA)
        _ = state.back()
        state.focus(tileC)
        #expect(state.audibleTile(followsFocus: true) == tileA)
        state.commitAudioFocus(tileC)
        #expect(state.audibleTile(followsFocus: true) == tileC)
        #expect(state.audibleTile(followsFocus: false) == tileA)
    }

    @Test func showAndReorderValidateTheirInput() {
        var state = grid([tileA, tileB])
        let step28 = state.show(.single(tileA))
        #expect(!step28)
        let step29 = state.show(.foreground(tileA))
        #expect(step29)
        let step30 = state.reorder([tileA])
        #expect(!step30)
        let step31 = state.reorder([tileB, tileA])
        #expect(step31)
        #expect(state.tiles == [tileB, tileA])
    }
}
