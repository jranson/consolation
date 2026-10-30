//
//  RingJog.swift
//  Consolation
//
//  Apple TV's ring jog, the math: touching and holding (without pressing) the outer ring of the Siri Remote's clickpad,
//  then swirling around it, fine-tunes the scrub-to time. A touch that rests on the ring for half a second, without
//  moving or clicking, starts a jog; from then on the angle the finger travels around the ring moves the timeline's
//  dot, clockwise forward and counterclockwise back, until the finger lifts or clicks. Positions are the clickpad's
//  absolute touch values (−1…1 on each axis, y pointing up, (0, 0) once the finger lifts). RemoteRingJog.swift feeds it
//  from GameController; this type is pure so it can be tested anywhere.
//

import Foundation

struct RingJog {
    enum Event: Equatable {
        case began
        /// Seconds to move the dot: positive (clockwise) forward, negative back.
        case moved(Double)
        case ended
    }

    /// The outer ring: a touch at least this far from the centre.
    static let ringRadius = 0.7
    /// While jogging, angles are read only this far out (near the centre a small slip is a big angle).
    static let trackRadius = 0.35
    /// Nearer the centre than this nothing touches: the surface reads (0, 0) once the finger lifts.
    static let liftRadius = 0.02
    /// How far a resting finger may drift before the touch counts as a swipe instead.
    static let stillTolerance = 0.15
    static let holdDuration: Duration = .milliseconds(500)
    /// One full turn of the ring. Fine-tuning: about a second for every 6°, the same on a half-hour show and a
    /// three-hour film. Clicks (10 s and up) and swipes (the whole timeline per swipe) cover the long moves; a few
    /// turns still reach a few minutes.
    static let secondsPerTurn = 60.0

    private(set) var isJogging = false
    private struct Landing {
        let xValue: Double
        let yValue: Double
        let time: ContinuousClock.Instant
    }

    /// Where and when the current touch landed; nil while nothing touches.
    private var landing: Landing?
    /// The current touch moved, clicked or met a swipe: it can't become a jog before the finger lifts.
    private var spoiled = false
    /// While jogging, the finger's last angle on the ring (radians, counterclockwise from the right).
    private var lastAngle: Double?

    /// When the resting touch becomes a jog if it stays as it is; nil when it can't.
    var holdDeadline: ContinuousClock.Instant? {
        guard let landing, !spoiled, !isJogging,
              Self.radius(landing.xValue, landing.yValue) >= Self.ringRadius else { return nil }
        return landing.time + Self.holdDuration
    }

    /// A new touch position (or the lift, at (0, 0)); `isPressed` is whether the clickpad is clicked down.
    mutating func touch(xValue: Double, yValue: Double, isPressed: Bool,
                        now: ContinuousClock.Instant = .now) -> Event? {
        let radius = Self.radius(xValue, yValue)
        if radius < Self.liftRadius { return reset() }
        guard let landing else {
            landing = Landing(xValue: xValue, yValue: yValue, time: now)
            spoiled = isPressed
            return nil
        }
        if isJogging {
            if isPressed { return end() }
            return turn(to: atan2(yValue, xValue), radius: radius)
        }
        if isPressed || Self.radius(xValue - landing.xValue, yValue - landing.yValue) > Self.stillTolerance {
            spoiled = true
        }
        return holdElapsed(isPressed: isPressed, now: now)
    }

    /// Time passed with the finger resting (no new position since): the jog begins once the hold is long enough.
    mutating func holdElapsed(isPressed: Bool, now: ContinuousClock.Instant = .now) -> Event? {
        if isPressed, landing != nil { spoiled = true }
        guard let deadline = holdDeadline, now >= deadline else { return nil }
        isJogging = true
        // The next position sets the starting angle, so the drift allowed while resting never moves the dot.
        lastAngle = nil
        return .began
    }

    /// A swipe is in progress: the current touch can't become a jog.
    mutating func blockHold() {
        if landing != nil { spoiled = true }
    }

    /// The finger lifted, or the remote or the timeline let go: ends a jog in progress.
    mutating func reset() -> Event? {
        let wasJogging = isJogging
        isJogging = false
        lastAngle = nil
        landing = nil
        spoiled = false
        return wasJogging ? .ended : nil
    }

    /// A click ends the jog; the finger must lift before the next one.
    private mutating func end() -> Event {
        isJogging = false
        lastAngle = nil
        spoiled = true
        return .ended
    }

    private mutating func turn(to angle: Double, radius: Double) -> Event? {
        guard radius >= Self.trackRadius else {
            lastAngle = nil
            return nil
        }
        let previous = lastAngle
        lastAngle = angle
        guard let previous else { return nil }
        let seconds = Self.seconds(turning: Self.angleDelta(from: previous, to: angle))
        return seconds == 0 ? nil : .moved(seconds)
    }

    /// The shortest signed turn from one angle to another (radians, −π…π), across the ±π seam too.
    static func angleDelta(from start: Double, to end: Double) -> Double {
        var delta = (end - start).truncatingRemainder(dividingBy: 2 * .pi)
        if delta > .pi {
            delta -= 2 * .pi
        } else if delta < -.pi {
            delta += 2 * .pi
        }
        return delta
    }

    /// Seconds for a turn. The surface's y axis points up, so angles grow counterclockwise: clockwise (a negative
    /// delta) goes forward.
    static func seconds(turning delta: Double) -> Double {
        -delta / (2 * .pi) * secondsPerTurn
    }

    static func radius(_ xValue: Double, _ yValue: Double) -> Double {
        (xValue * xValue + yValue * yValue).squareRoot()
    }
}
