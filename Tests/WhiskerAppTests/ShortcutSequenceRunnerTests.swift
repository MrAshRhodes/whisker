import Foundation
import Testing
import WhiskerCore
@testable import Whisker

/// A keyboard, front app and event system under a test's control. Records each posted key as a down and an up.
private final class FakeEnvironment: SequenceEnvironment, @unchecked Sendable {
    private let lock = NSLock()
    private var _front: ApplicationInstance? = ApplicationInstance(processID: 100, activation: 1)
    private var _modifiers: ModifierSet = []
    private var _heldKeys: Set<UInt16> = []
    private var _failFrom: Int?
    private var _events: [String] = []
    private var _prepared = 0

    var front: ApplicationInstance? {
        get { lock.withLock { _front } }
        set { lock.withLock { _front = newValue } }
    }
    var modifiers: ModifierSet {
        get { lock.withLock { _modifiers } }
        set { lock.withLock { _modifiers = newValue } }
    }
    var heldKeys: Set<UInt16> {
        get { lock.withLock { _heldKeys } }
        set { lock.withLock { _heldKeys = newValue } }
    }
    /// The step (counting from 0) from which the system refuses to create events.
    var failFrom: Int? {
        get { lock.withLock { _failFrom } }
        set { lock.withLock { _failFrom = newValue } }
    }
    var events: [String] { lock.withLock { _events } }

    func frontmostInstance() -> ApplicationInstance? { front }
    func heldModifiers() -> ModifierSet { modifiers }
    func isKeyHeld(_ keyCode: UInt16) -> Bool { heldKeys.contains(keyCode) }

    func prepare(_ shortcut: KeyShortcut) -> (@Sendable () -> Void)? {
        let fails = lock.withLock { () -> Bool in
            defer { _prepared += 1 }
            return _failFrom.map { _prepared >= $0 } ?? false
        }
        if fails { return nil }
        return { [self] in
            lock.withLock { _events += ["down \(shortcut.keyCode)", "up \(shortcut.keyCode)"] }
        }
    }
}

private final class StopLog: @unchecked Sendable {
    private let lock = NSLock()
    private var _stops: [SequenceStop] = []
    private var _changes = 0
    var stops: [SequenceStop] { lock.withLock { _stops } }
    var changes: Int { lock.withLock { _changes } }
    func stopped(_ stop: SequenceStop) { lock.withLock { _stops.append(stop) } }
    func changed() { lock.withLock { _changes += 1 } }
}

private func step(_ code: UInt16, _ modifiers: ModifierSet = .command, delay: Int = 0) -> SequenceStep {
    SequenceStep(shortcut: KeyShortcut(keyCode: code, modifiers: modifiers), delayAfterMs: delay)
}

private func pair(_ code: UInt16) -> [String] { ["down \(code)", "up \(code)"] }

@Suite("Shortcut sequence runner")
struct ShortcutSequenceRunnerTests {
    private let clock = ManualClock()
    private let environment = FakeEnvironment()
    private let log = StopLog()
    private let runner: ShortcutSequenceRunner
    private let steps = [step(0, delay: 100), step(8, delay: 200), step(9)]

    init() {
        runner = ShortcutSequenceRunner(
            clock: clock, environment: environment, stopped: { [log] in log.stopped($0) }, changed: { [log] in log.changed() }
        )
    }

    @Test func nothingIsPostedOnTheCallingThreadAndStepsFollowTheirDelays() {
        runner.activate(steps)
        #expect(environment.events.isEmpty)
        #expect(runner.isRunning)

        clock.advance(by: 0)
        #expect(environment.events == pair(0))
        clock.advance(by: 0.09)
        #expect(environment.events == pair(0))
        clock.advance(by: 0.01)
        #expect(environment.events == pair(0) + pair(8))
        clock.advance(by: 0.2)
        #expect(environment.events == pair(0) + pair(8) + pair(9))
        #expect(!runner.isRunning)
        #expect(clock.pending == 0)
        #expect(log.stops.isEmpty)
        #expect(log.changes == 2)
    }

    @Test func everyKeyDownIsFollowedByItsUp() {
        runner.activate(steps)
        clock.advance(by: 1)
        let events = environment.events
        #expect(events.count == 6)
        for index in stride(from: 0, to: events.count, by: 2) {
            #expect(events[index].replacingOccurrences(of: "down", with: "up") == events[index + 1])
        }
    }

    @Test func usingTheSameMappingAgainCancelsAndNothingMoreIsPosted() {
        runner.activate(steps)
        clock.advance(by: 0)
        runner.activate(steps)
        clock.advance(by: 5)
        #expect(environment.events == pair(0))
        #expect(log.stops == [.retriggered])
        #expect(!runner.isRunning)
        #expect(clock.pending == 0)
    }

    @Test func anotherSequenceIsIgnoredWhileOneRunsAndNothingIsQueued() {
        runner.activate(steps)
        runner.activate([step(1), step(2)])
        runner.activate([step(3), step(4)])
        clock.advance(by: 5)
        #expect(environment.events == pair(0) + pair(8) + pair(9))
        #expect(log.stops.isEmpty)

        // Once it has finished the mapping works again, and the ignored ones didn't wait in line.
        runner.activate([step(1), step(2)])
        clock.advance(by: 5)
        #expect(environment.events.suffix(4) == pair(1)[...] + pair(2)[...])
        #expect(environment.events.count == 10)
    }

    @Test func aTimerThatWasCalledOffButAlreadyRunningPostsNothing() {
        runner.activate(steps)
        clock.advance(by: 0)
        runner.cancel(.lifecycle)
        clock.runCalledOffTimers()
        clock.advance(by: 5)
        #expect(environment.events == pair(0))
    }

    @Test(arguments: [SequenceStop.lifecycle, .applicationChanged, .userCancelled])
    func cancellationBetweenStepsStopsEverythingAndLeavesNoKeyDown(reason: SequenceStop) {
        runner.activate(steps)
        clock.advance(by: 0.1)
        #expect(environment.events == pair(0) + pair(8))
        runner.cancel(reason)
        clock.advance(by: 5)
        #expect(environment.events == pair(0) + pair(8))
        #expect(log.stops == [reason])
        #expect(!runner.isRunning)
        runner.cancel(.lifecycle)
        #expect(log.stops == [reason])
    }

    @Test func cancellingBeforeTheFirstStepPostsNothing() {
        runner.activate(steps)
        runner.cancel(.lifecycle)
        clock.advance(by: 5)
        #expect(environment.events.isEmpty)
    }

    @Test func theFrontAppChangingStopsTheNextStep() {
        runner.activate(steps)
        clock.advance(by: 0)
        environment.front = ApplicationInstance(processID: 200, activation: 2)
        clock.advance(by: 5)
        #expect(environment.events == pair(0))
        #expect(log.stops == [.applicationChanged])
    }

    @Test func leavingAnAppAndComingBackStillStopsTheSequence() {
        runner.activate(steps)
        clock.advance(by: 0)
        environment.front = ApplicationInstance(processID: 100, activation: 3)
        clock.advance(by: 5)
        #expect(environment.events == pair(0))
        #expect(log.stops == [.applicationChanged])
    }

    @Test func anUnidentifiedFrontAppRefusesToStart() {
        environment.front = nil
        runner.activate(steps)
        clock.advance(by: 5)
        #expect(environment.events.isEmpty)
        #expect(log.stops == [.unknownApplication])
        #expect(!runner.isRunning)
    }

    @Test func aHeldModifierThatIsNotInTheStepRefusesItAndStops() {
        environment.modifiers = [.command, .option]
        runner.activate(steps)
        clock.advance(by: 5)
        #expect(environment.events.isEmpty)
        #expect(log.stops == [.physicalKeys])
    }

    @Test func theTriggersOwnModifierIsFineWhenTheStepHasIt() {
        environment.modifiers = .command
        runner.activate(steps)
        clock.advance(by: 5)
        #expect(environment.events.count == 6)
    }

    @Test func aStepsKeyAlreadyHeldRefusesIt() {
        environment.heldKeys = [8]
        runner.activate(steps)
        clock.advance(by: 5)
        #expect(environment.events == pair(0))
        #expect(log.stops == [.physicalKeys])
    }

    @Test func anEventThatCannotBeCreatedStopsWithoutPostingHalfAStep() {
        environment.failFrom = 1
        runner.activate(steps)
        clock.advance(by: 5)
        #expect(environment.events == pair(0))
        #expect(log.stops == [.eventFailure])
        #expect(log.stops.allSatisfy { $0.needsFeedback })
        #expect(!runner.isRunning)
        #expect(clock.pending == 0)
    }
}
