import Foundation
import Testing
@testable import Consolation

/// The Apple TV ring jog's rules: which touches start one, and how far a turn moves the dot.
struct RingJogTests {
    private let start = ContinuousClock.now
    private let hold = RingJog.holdDuration

    /// A touch resting on the ring (at the top) until the jog begins.
    private func jogging() -> RingJog {
        var jog = RingJog()
        #expect(jog.touch(xValue: 0, yValue: 0.9, isPressed: false, now: start) == nil)
        #expect(jog.holdElapsed(isPressed: false, now: start + hold) == .began)
        return jog
    }

    @Test func aStillTouchOnTheRingBeginsAJogAfterTheHold() {
        var jog = RingJog()
        #expect(jog.touch(xValue: 0.8, yValue: 0, isPressed: false, now: start) == nil)
        #expect(jog.holdDeadline == start + hold)
        #expect(jog.holdElapsed(isPressed: false, now: start + .milliseconds(300)) == nil, "too soon")
        #expect(jog.touch(xValue: 0.82, yValue: 0.03, isPressed: false, now: start + .milliseconds(400)) == nil,
                "a little drift is still resting")
        #expect(jog.touch(xValue: 0.81, yValue: 0.02, isPressed: false, now: start + hold) == .began,
                "a new position after the hold begins it too")
        #expect(jog.isJogging)
        #expect(jog.holdDeadline == nil)
    }

    @Test func touchesThatMoveClickOrSitInsideTheRingNeverBeginAJog() {
        var centre = RingJog()
        _ = centre.touch(xValue: 0.2, yValue: 0.1, isPressed: false, now: start)
        #expect(centre.holdDeadline == nil)
        #expect(centre.holdElapsed(isPressed: false, now: start + .seconds(2)) == nil, "inside the ring")

        var swipe = RingJog()
        _ = swipe.touch(xValue: 0.75, yValue: 0, isPressed: false, now: start)
        _ = swipe.touch(xValue: 0.75, yValue: 0.4, isPressed: false, now: start + .milliseconds(100))
        #expect(swipe.holdElapsed(isPressed: false, now: start + .seconds(2)) == nil, "it moved: a swipe")

        var click = RingJog()
        _ = click.touch(xValue: 0.9, yValue: 0, isPressed: false, now: start)
        #expect(click.holdElapsed(isPressed: true, now: start + hold) == nil, "a click (the right edge) never jogs")
        #expect(click.holdElapsed(isPressed: false, now: start + .seconds(2)) == nil, "not until the finger lifts")

        var blocked = RingJog()
        _ = blocked.touch(xValue: 0, yValue: -0.9, isPressed: false, now: start)
        blocked.blockHold()
        #expect(blocked.holdElapsed(isPressed: false, now: start + hold) == nil, "a swipe was in progress")

        // A lift starts over: the next resting touch may jog.
        #expect(blocked.touch(xValue: 0, yValue: 0, isPressed: false, now: start + .seconds(1)) == nil)
        _ = blocked.touch(xValue: -0.9, yValue: 0, isPressed: false, now: start + .seconds(2))
        #expect(blocked.holdElapsed(isPressed: false, now: start + .seconds(2) + hold) == .began)
    }

    @Test func clockwiseMovesForwardAtSixtySecondsATurn() throws {
        var jog = jogging()
        // The first position after the start only sets the angle (the drift while resting never moves the dot).
        #expect(jog.touch(xValue: 0, yValue: 0.9, isPressed: false) == nil)
        // Top to right is a quarter turn clockwise (y points up).
        let forward = try #require(seconds(jog.touch(xValue: 0.9, yValue: 0, isPressed: false)))
        #expect(abs(forward - 15) < 1e-9)
        // And back to the top, counterclockwise.
        let back = try #require(seconds(jog.touch(xValue: 0, yValue: 0.9, isPressed: false)))
        #expect(abs(back + 15) < 1e-9)
    }

    @Test func turnsAcrossTheLeftSideWrapAround() throws {
        var jog = jogging()
        // Just above the left (angle near +π) to just below it (near −π): a small counterclockwise turn.
        _ = jog.touch(xValue: -0.9, yValue: 0.02, isPressed: false)
        let small = try #require(seconds(jog.touch(xValue: -0.9, yValue: -0.02, isPressed: false)))
        #expect(small < 0 && small > -1, "a sliver back, not most of a turn forward")

        #expect(abs(RingJog.angleDelta(from: 3, to: -3) - (2 * .pi - 6)) < 1e-9)
        #expect(abs(RingJog.angleDelta(from: -3, to: 3) + (2 * .pi - 6)) < 1e-9)
        #expect(abs(RingJog.angleDelta(from: 0.5, to: 1) - 0.5) < 1e-9)
        #expect(RingJog.seconds(turning: -2 * .pi) == RingJog.secondsPerTurn, "a full turn clockwise")
    }

    @Test func nearTheCentreTheAngleIsNotRead() throws {
        var jog = jogging()
        _ = jog.touch(xValue: 0, yValue: 0.9, isPressed: false)
        #expect(jog.touch(xValue: 0.1, yValue: -0.1, isPressed: false) == nil, "a slip across the middle")
        #expect(jog.touch(xValue: 0, yValue: -0.9, isPressed: false) == nil, "back on the ring: a new start")
        let forward = try #require(seconds(jog.touch(xValue: -0.9, yValue: 0, isPressed: false)))
        #expect(abs(forward - 15) < 1e-9, "bottom to left is clockwise")
        #expect(jog.isJogging)
    }

    @Test func liftingOrClickingEndsTheJog() {
        var lifted = jogging()
        #expect(lifted.touch(xValue: 0, yValue: 0, isPressed: false) == .ended)
        #expect(!lifted.isJogging)
        #expect(lifted.reset() == nil, "already over")

        var clicked = jogging()
        #expect(clicked.touch(xValue: 0.1, yValue: 0.9, isPressed: true) == .ended)
        #expect(clicked.touch(xValue: 0.3, yValue: 0.85, isPressed: false) == nil, "no moves after the click")
        #expect(clicked.holdElapsed(isPressed: false, now: .now + .seconds(5)) == nil, "no new jog before a lift")

        var dropped = jogging()
        #expect(dropped.reset() == .ended, "the timeline let go of the remote")
    }

    private func seconds(_ event: RingJog.Event?) -> Double? {
        if case .moved(let seconds) = event { return seconds }
        return nil
    }
}
