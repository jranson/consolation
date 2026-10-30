import CoreGraphics
@testable import PlayerKit
import Testing

struct GeometryTests {
    let tvSize = CGSize(width: 1920, height: 1080)
    let metrics = MultiViewMetrics(spacing: 10, padding: 0)

    @Test(arguments: [(1, 1, 1), (2, 2, 1), (3, 2, 2), (4, 2, 2), (5, 3, 2), (6, 3, 2), (7, 3, 3), (8, 3, 3),
                      (9, 3, 3)])
    func nearSquareShape(count: Int, columns: Int, rows: Int) {
        #expect(MultiViewGeometry.shape(count: count, container: tvSize) == GridShape(columns: columns, rows: rows))
    }

    @Test func twoTilesStackInPortrait() {
        let portrait = CGSize(width: 390, height: 844)
        #expect(MultiViewGeometry.shape(count: 2, container: portrait) == GridShape(columns: 1, rows: 2))
    }

    @Test(arguments: 1...9)
    func cellsAre16x9InsideTheContainerWithoutOverlap(count: Int) {
        let cells = MultiViewGeometry.cellFrames(count: count, in: tvSize, metrics: metrics)
        #expect(cells.count == count)
        let bounds = CGRect(origin: .zero, size: tvSize)
        for (index, cell) in cells.enumerated() {
            #expect(abs(cell.width / cell.height - 16 / 9) < 0.001)
            #expect(bounds.insetBy(dx: -0.01, dy: -0.01).contains(cell))
            for other in cells[(index + 1)...] { #expect(cell.intersection(other).width < 0.01) }
        }
    }

    @Test func gridIsCenteredAndShortRowsAreCentered() {
        let cells = MultiViewGeometry.cellFrames(count: 3, in: tvSize, metrics: metrics)
        let union = cells.dropFirst().reduce(cells[0]) { $0.union($1) }
        #expect(abs(union.midX - tvSize.width / 2) < 0.01)
        #expect(abs(union.midY - tvSize.height / 2) < 0.01)
        #expect(abs(cells[2].midX - tvSize.width / 2) < 0.01)
    }

    @Test func singleTileFillsTheContainer() {
        let cells = MultiViewGeometry.cellFrames(count: 1, in: tvSize, metrics: MultiViewMetrics(padding: 0))
        #expect(cells[0] == CGRect(origin: .zero, size: tvSize))
    }

    @Test func foregroundIsInsetFivePercentAtLeast24Points() {
        let frame = MultiViewGeometry.foregroundFrame(in: tvSize, metrics: MultiViewMetrics())
        #expect(frame == CGRect(x: 96, y: 54, width: 1728, height: 972))
        let small = MultiViewGeometry.foregroundFrame(in: CGSize(width: 320, height: 180), metrics: MultiViewMetrics())
        #expect(small.minY >= 24 - 0.001)
        #expect(small.minX >= 24 - 0.001)
    }

    @Test func aspectFitCentersTheVideo() {
        let fitted = MultiViewGeometry.aspectFit(4 / 3, in: CGRect(x: 0, y: 0, width: 160, height: 90))
        #expect(fitted == CGRect(x: 20, y: 0, width: 120, height: 90))
    }

    @Test func neighborsInATwoByTwoGrid() {
        let shape = GridShape(columns: 2, rows: 2)
        #expect(MultiViewGeometry.neighbor(of: 0, toward: .rightward, count: 4, shape: shape) == 1)
        #expect(MultiViewGeometry.neighbor(of: 0, toward: .downward, count: 4, shape: shape) == 2)
        #expect(MultiViewGeometry.neighbor(of: 3, toward: .upward, count: 4, shape: shape) == 1)
        #expect(MultiViewGeometry.neighbor(of: 3, toward: .leftward, count: 4, shape: shape) == 2)
        #expect(MultiViewGeometry.neighbor(of: 1, toward: .rightward, count: 4, shape: shape) == nil)
        #expect(MultiViewGeometry.neighbor(of: 2, toward: .downward, count: 4, shape: shape) == nil)
    }

    @Test func neighborsWithACenteredShortRow() {
        let shape = GridShape(columns: 3, rows: 2)
        // Row 0: 0 1 2; row 1 (centered): 3 4.
        #expect(MultiViewGeometry.neighbor(of: 0, toward: .downward, count: 5, shape: shape) == 3)
        #expect(MultiViewGeometry.neighbor(of: 2, toward: .downward, count: 5, shape: shape) == 4)
        #expect(MultiViewGeometry.neighbor(of: 1, toward: .downward, count: 5, shape: shape) == 3)
        #expect(MultiViewGeometry.neighbor(of: 4, toward: .rightward, count: 5, shape: shape) == nil)
        #expect(MultiViewGeometry.neighbor(of: 2, toward: .rightward, count: 5, shape: shape) == nil)
        #expect(MultiViewGeometry.neighbor(of: 3, toward: .upward, count: 5, shape: shape) == 0)
    }

    @Test func stackedNeighbors() {
        let shape = GridShape(columns: 1, rows: 2)
        #expect(MultiViewGeometry.neighbor(of: 0, toward: .downward, count: 2, shape: shape) == 1)
        #expect(MultiViewGeometry.neighbor(of: 0, toward: .rightward, count: 2, shape: shape) == nil)
    }

    @Test func placementsPerMode() {
        let tileA = TileID()
        let tileB = TileID()
        var state = MultiViewState(tile: tileA)
        let single = MultiViewGeometry.placements(for: state, in: tvSize, metrics: metrics)
        #expect(single[tileA] == TilePlacement(frame: CGRect(origin: .zero, size: tvSize)))

        state.add(tileB)
        state.select(tileB)
        let front = MultiViewGeometry.placements(for: state, in: tvSize, metrics: metrics)
        #expect(front[tileB]?.isForeground == true)
        #expect(front[tileB]?.zIndex == 1)
        #expect(front[tileB]?.cornerRadius == metrics.foregroundCornerRadius)
        #expect(front[tileA]?.isDimmed == true)
        #expect(front[tileA]?.isInteractive == false)

        let mini = MultiViewGeometry.placements(for: state, presentation: .mini, audibleTile: tileB, in: tvSize,
                                                metrics: metrics)
        #expect(mini[tileB]?.isVisible == true)
        #expect(mini[tileB]?.frame == CGRect(origin: .zero, size: tvSize))
        #expect(mini[tileA]?.isVisible == false)
        #expect(mini.values.allSatisfy { !$0.isInteractive })
        let hidden = MultiViewGeometry.placements(for: state, presentation: .hidden, in: tvSize, metrics: metrics)
        #expect(hidden.values.allSatisfy { !$0.isVisible })
    }
}
