import Foundation
import Testing
@testable import Consolation

/// The timeline scrubber's remote steps and the controls' time labels.
struct TimelineScrubberTests {
    @Test func stepsStartFromTheTimelineLengthAndGrowWhilePressesComeQuickly() {
        #expect(ScrubStepper.baseStep(duration: 300) == 10)
        #expect(ScrubStepper.baseStep(duration: 3_000) == 30)
        #expect(ScrubStepper.baseStep(duration: 9_000) == 60)

        var stepper = ScrubStepper()
        let start = ContinuousClock.now
        #expect(stepper.next(duration: 3_000, now: start) == 30)
        #expect(stepper.next(duration: 3_000, now: start + .milliseconds(200)) == 60)
        #expect(stepper.next(duration: 3_000, now: start + .milliseconds(400)) == 120)
        #expect(stepper.next(duration: 3_000, now: start + .milliseconds(600)) == 240)
        #expect(stepper.next(duration: 3_000, now: start + .milliseconds(800)) == 240, "at most eight times the base")
        #expect(stepper.next(duration: 3_000, now: start + .seconds(3)) == 30, "a pause starts over")
    }

    @Test func timeLabels() {
        #expect(TimeLabel.text(0) == "0:00")
        #expect(TimeLabel.text(65.4) == "1:05")
        #expect(TimeLabel.text(3_723) == "1:02:03")
        // Labels reserve the widest time the timeline can show, so the track between them never moves.
        #expect(TimeLabel.widest(for: 59 * 60) == "00:00")
        #expect(TimeLabel.widest(for: 7_316) == "0:00:00")
        #expect(TimeLabel.widest(for: 40_000) == "00:00:00")
        #expect(TimeLabel.text(-5) == "0:00")
    }
}
