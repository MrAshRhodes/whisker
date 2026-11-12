import Foundation
import Testing
@testable import WhiskerCore

@Suite("Click sequence")
struct ClickSequenceTests {
    private func press(_ count: Int64, button: Int = 0) -> ClickStep {
        ClickStep(button: button, isDown: true, clickState: count)
    }

    private func release(_ count: Int64, button: Int = 0) -> ClickStep {
        ClickStep(button: button, isDown: false, clickState: count)
    }

    /// Runs a gesture to its end, jumping to each due time, and records when every step came out.
    private func timeline(_ plan: ClickPlan, _ timing: ClickTiming, from start: TimeInterval = 100) -> [(at: TimeInterval, step: ClickStep)] {
        var sequencer = ClickSequencer()
        var log = sequencer.begin(plan, timing: timing, now: start).map { (at: start, step: $0) }
        while let due = sequencer.nextDue {
            log += sequencer.advance(to: due).map { (at: due, step: $0) }
        }
        return log
    }

    // MARK: Plan

    @Test func tripleClickIsThreeClicksCountedOneTwoThree() {
        #expect(ClickPlan.tripleClick.steps == [press(1), release(1), press(2), release(2), press(3), release(3)])
    }

    @Test func aPlanWithoutClicksHasNoSteps() {
        #expect(ClickPlan(button: 0, clicks: 0).steps.isEmpty)
        #expect(ClickPlan(button: 0, clicks: -2).steps.isEmpty)
    }

    // MARK: Timing

    @Test func immediateTimingHandsOutEveryStepAtOnce() {
        var sequencer = ClickSequencer()
        #expect(sequencer.begin(.tripleClick, timing: .immediate, now: 10) == ClickPlan.tripleClick.steps)
        #expect(!sequencer.isActive)
        #expect(sequencer.nextDue == nil)
        #expect(sequencer.advance(to: 11).isEmpty)
    }

    @Test func spacedTimingHandsOutOnePairAtATime() {
        var sequencer = ClickSequencer()
        #expect(sequencer.begin(.tripleClick, timing: ClickTiming(spacing: 0.25), now: 10) == [press(1), release(1)])
        #expect(sequencer.isActive)
        #expect(sequencer.nextDue == 10.25)
        #expect(sequencer.advance(to: 10.2).isEmpty)
        #expect(sequencer.advance(to: 10.25) == [press(2), release(2)])
        #expect(sequencer.nextDue == 10.5)
        #expect(sequencer.advance(to: 10.5) == [press(3), release(3)])
        #expect(!sequencer.isActive)
        #expect(sequencer.nextDue == nil)
    }

    @Test(arguments: [0.15, 0.5, 1.0, 5.0])
    func spacedClicksStayInsideTheDoubleClickInterval(interval: TimeInterval) {
        let log = timeline(.tripleClick, .spaced(withinInterval: interval))
        let presses = log.filter(\.step.isDown).map(\.at)

        #expect(log.map(\.step) == ClickPlan.tripleClick.steps)
        #expect(presses.count == 3)
        for (earlier, later) in zip(presses, presses.dropFirst()) {
            #expect(later > earlier)
            #expect(later - earlier < interval)
        }
    }

    @Test func anUnusableIntervalFallsBackToBackToBack() {
        for interval in [0, -1, TimeInterval.nan, .infinity] {
            #expect(ClickTiming.spaced(withinInterval: interval) == .immediate)
        }
        #expect(ClickTiming(spacing: -0.5, hold: .nan) == .immediate)
    }

    @Test func aHoldLongerThanTheSpacingNeverReordersSteps() {
        let log = timeline(.tripleClick, ClickTiming(spacing: 0.1, hold: 0.5))
        #expect(log.map(\.step) == ClickPlan.tripleClick.steps)
        #expect(log.map(\.at) == log.map(\.at).sorted())
    }

    @Test func aLateAdvanceCatchesUpOnceAndInOrder() {
        var sequencer = ClickSequencer()
        _ = sequencer.begin(.tripleClick, timing: ClickTiming(spacing: 0.25), now: 10)
        #expect(sequencer.advance(to: 30) == [press(2), release(2), press(3), release(3)])
        #expect(sequencer.advance(to: 31).isEmpty)
        #expect(!sequencer.isActive)
    }

    // MARK: Calling off

    @Test func cancellingBetweenPairsDropsTheRest() {
        var sequencer = ClickSequencer()
        _ = sequencer.begin(.tripleClick, timing: ClickTiming(spacing: 0.25), now: 10)
        #expect(sequencer.advance(to: 10.25) == [press(2), release(2)])

        // Both events of the second click are out, so nothing is owed.
        #expect(sequencer.cancel().isEmpty)
        #expect(!sequencer.isActive)
        #expect(sequencer.nextDue == nil)
        #expect(sequencer.advance(to: 20).isEmpty)
    }

    @Test func cancellingWhileAPressIsDownOwesItsRelease() {
        var sequencer = ClickSequencer()
        #expect(sequencer.begin(.tripleClick, timing: ClickTiming(spacing: 0.25, hold: 0.125), now: 10) == [press(1)])
        #expect(sequencer.advance(to: 10.125) == [release(1)])
        #expect(sequencer.advance(to: 10.25) == [press(2)])

        #expect(sequencer.cancel() == [release(2)])
        #expect(sequencer.cancel().isEmpty)
        #expect(sequencer.advance(to: 20).isEmpty)
    }

    @Test func cancellingAFinishedGestureChangesNothing() {
        var sequencer = ClickSequencer()
        _ = sequencer.begin(.tripleClick, timing: .immediate, now: 10)
        let generation = sequencer.generation
        #expect(sequencer.cancel().isEmpty)
        #expect(sequencer.generation == generation)
    }

    @Test func startingAndCallingOffMoveOnTheGeneration() {
        var sequencer = ClickSequencer()
        let idle = sequencer.generation
        _ = sequencer.begin(.tripleClick, timing: ClickTiming(spacing: 0.25), now: 0)
        let running = sequencer.generation
        _ = sequencer.cancel()

        #expect(running != idle)
        #expect(sequencer.generation != running)
    }

    @Test func inputThatReachesAnAppCallsAGestureOff() {
        let wheel = InputKind.scroll(ScrollSample(vertical: .lines(1)))
        #expect(ClickInterruption.isCalledOffBy(.buttonDown(0), plan: .passThrough))
        #expect(ClickInterruption.isCalledOffBy(.buttonUp(1), plan: .passThrough))
        #expect(ClickInterruption.isCalledOffBy(wheel, plan: .passThrough))
        #expect(ClickInterruption.isCalledOffBy(wheel, plan: .scroll(ScrollSample(vertical: .lines(-1)), removing: [])))
        // Another action takes over from it.
        #expect(ClickInterruption.isCalledOffBy(.buttonDown(3), plan: .perform(.navigate(.back), .once)))
        #expect(ClickInterruption.isCalledOffBy(wheel, plan: .perform(.tripleClick(modifiers: []), .once)))
    }

    @Test func theTriggersReleaseAndDragsLeaveAGestureAlone() {
        #expect(!ClickInterruption.isCalledOffBy(.buttonUp(3), plan: .swallow))
        #expect(!ClickInterruption.isCalledOffBy(.scroll(ScrollSample(vertical: .lines(1))), plan: .swallow))
        #expect(!ClickInterruption.isCalledOffBy(.buttonDragged(3), plan: .dragAsMove))
        #expect(!ClickInterruption.isCalledOffBy(.buttonDragged(2), plan: .dragAs(button: 0, modifiers: [])))
        #expect(!ClickInterruption.isCalledOffBy(.buttonDragged(0), plan: .passThrough))
    }

    @Test func aMouseThatIsGoneCallsItsGestureOff() {
        #expect(!ClickInterruption.isCalledOffByDeviceChange(startedBy: "a", connected: ["a", "b"]))
        #expect(ClickInterruption.isCalledOffByDeviceChange(startedBy: "a", connected: ["b"]))
        #expect(ClickInterruption.isCalledOffByDeviceChange(startedBy: "a", connected: []))
        // Without knowing which mouse it was, any change might be it.
        #expect(ClickInterruption.isCalledOffByDeviceChange(startedBy: nil, connected: ["a"]))
    }
}
