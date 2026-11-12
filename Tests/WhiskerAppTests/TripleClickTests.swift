import CoreGraphics
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

/// A clock moved by hand. A timer runs only when a test advances time past it, in the order the timers come due.
final class ManualClock: ClickClock, @unchecked Sendable {
    private struct Timer {
        let id: Int
        let due: TimeInterval
        let body: @Sendable () -> Void
        var calledOff = false
    }

    private let lock = NSLock()
    private var current: TimeInterval = 1000
    private var timers: [Timer] = []
    private var issued = 0

    var now: TimeInterval { lock.withLock { current } }

    /// Timers waiting to run that haven't been called off.
    var pending: Int { lock.withLock { timers.filter { !$0.calledOff }.count } }

    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        lock.withLock {
            issued += 1
            let id = issued
            timers.append(Timer(id: id, due: current + delay, body: body))
            return { [weak self] in self?.callOff(id) }
        }
    }

    /// Moves time forward, running every timer that comes due on the way (including ones those timers set).
    func advance(by interval: TimeInterval) {
        let target = now + interval
        while let timer = nextDue(by: target) { timer.body() }
        lock.withLock { current = target }
    }

    /// Runs the timers that were called off, as a real queue can when a timer had already started by then.
    func runCalledOffTimers() {
        let late = lock.withLock { () -> [Timer] in
            let late = timers.filter(\.calledOff)
            timers.removeAll { $0.calledOff }
            return late
        }
        for timer in late { timer.body() }
    }

    private func callOff(_ id: Int) {
        lock.withLock {
            if let index = timers.firstIndex(where: { $0.id == id }) { timers[index].calledOff = true }
        }
    }

    private func nextDue(by target: TimeInterval) -> Timer? {
        lock.withLock {
            let due = timers.indices.filter { !timers[$0].calledOff && timers[$0].due <= target }
            guard let index = due.min(by: { (timers[$0].due, timers[$0].id) < (timers[$1].due, timers[$1].id) }) else { return nil }
            let timer = timers.remove(at: index)
            current = max(current, timer.due)
            return timer
        }
    }
}

/// What a click gesture posted, in order, and where.
final class PostLog: @unchecked Sendable {
    struct Entry: Equatable {
        var step: ClickStep
        var location: CGPoint
        var flags: CGEventFlags
    }

    private let lock = NSLock()
    private var recorded: [Entry] = []

    var entries: [Entry] { lock.withLock { recorded } }
    var steps: [ClickStep] { entries.map(\.step) }

    func record(_ step: ClickStep, _ location: CGPoint, _ flags: CGEventFlags) {
        lock.withLock { recorded.append(Entry(step: step, location: location, flags: flags)) }
    }
}

private func press(_ count: Int64) -> ClickStep { ClickStep(button: 0, isDown: true, clickState: count) }
private func release(_ count: Int64) -> ClickStep { ClickStep(button: 0, isDown: false, clickState: count) }
private let wholeGesture = [press(1), release(1), press(2), release(2), press(3), release(3)]

@Suite("Click scheduler")
struct ClickSchedulerTests {
    private static let spot = CGPoint(x: 120, y: 80)
    private static let flags: CGEventFlags = .maskShift

    private func makeScheduler() -> (scheduler: ClickScheduler, clock: ManualClock, log: PostLog) {
        let clock = ManualClock()
        let log = PostLog()
        return (ClickScheduler(clock: clock, post: { log.record($0, $1, $2) }), clock, log)
    }

    @Test func backToBackClicksAreAllPostedBeforeStartReturns() {
        let (scheduler, clock, log) = makeScheduler()
        scheduler.start(.tripleClick, timing: .immediate, at: Self.spot, flags: Self.flags)

        #expect(log.steps == wholeGesture)
        #expect(!scheduler.isActive)
        #expect(clock.pending == 0)
    }

    @Test func spacedClicksComeOnePairPerSpacing() {
        let (scheduler, clock, log) = makeScheduler()
        // A 0.5 s double-click interval spaces the presses 0.125 s apart.
        scheduler.start(.tripleClick, timing: .spaced(withinInterval: 0.5), at: Self.spot, flags: Self.flags)
        #expect(log.steps == [press(1), release(1)])
        #expect(scheduler.isActive)

        clock.advance(by: 0.0625)
        #expect(log.steps.count == 2)
        clock.advance(by: 0.0625)
        #expect(log.steps == [press(1), release(1), press(2), release(2)])
        clock.advance(by: 0.125)
        #expect(log.steps == wholeGesture)
        #expect(!scheduler.isActive)
        #expect(clock.pending == 0)
        #expect(log.entries.allSatisfy { $0.location == Self.spot && $0.flags == Self.flags })
    }

    @Test func callingOffBetweenPairsPostsNothingMore() {
        let (scheduler, clock, log) = makeScheduler()
        scheduler.start(.tripleClick, timing: .spaced(withinInterval: 0.5), at: Self.spot, flags: Self.flags)
        clock.advance(by: 0.125)
        scheduler.cancel()
        clock.advance(by: 1)

        #expect(log.steps == [press(1), release(1), press(2), release(2)])
        #expect(!scheduler.isActive)
        #expect(clock.pending == 0)
    }

    @Test func aPressThatWasPostedGetsItsReleaseWhereItWasMade() {
        let (scheduler, clock, log) = makeScheduler()
        scheduler.start(.tripleClick, timing: ClickTiming(spacing: 0.5, hold: 0.25), at: Self.spot, flags: Self.flags)
        #expect(log.steps == [press(1)])

        scheduler.cancel()
        #expect(log.entries == [
            .init(step: press(1), location: Self.spot, flags: Self.flags),
            .init(step: release(1), location: Self.spot, flags: Self.flags),
        ])
        clock.advance(by: 2)
        #expect(log.steps.count == 2)
        #expect(!scheduler.isActive)
    }

    @Test func startingAgainFinishesTheOldGestureBeforeTheNewOneBegins() {
        let (scheduler, clock, log) = makeScheduler()
        let timing = ClickTiming(spacing: 0.5, hold: 0.25)
        let elsewhere = CGPoint(x: 10, y: 20)
        scheduler.start(.tripleClick, timing: timing, at: Self.spot, flags: Self.flags)
        scheduler.start(.tripleClick, timing: timing, at: elsewhere, flags: [])
        clock.advance(by: 2)

        #expect(log.entries == [
            .init(step: press(1), location: Self.spot, flags: Self.flags),
            .init(step: release(1), location: Self.spot, flags: Self.flags),
        ] + wholeGesture.map { PostLog.Entry(step: $0, location: elsewhere, flags: []) })
    }

    @Test func aTimerLeftBehindByACalledOffGestureDoesNothing() {
        let (scheduler, clock, log) = makeScheduler()
        scheduler.start(.tripleClick, timing: .spaced(withinInterval: 0.5), at: Self.spot, flags: Self.flags)
        scheduler.cancel()
        scheduler.start(.tripleClick, timing: .spaced(withinInterval: 0.5), at: Self.spot, flags: Self.flags)
        clock.runCalledOffTimers()
        #expect(log.steps == [press(1), release(1), press(1), release(1)])

        clock.advance(by: 0.125)
        #expect(log.steps.suffix(2) == [press(2), release(2)])
    }
}

@Suite("Triple click in the event engine")
struct TripleClickEngineTests {
    private static let spot = CGPoint(x: 300, y: 200)

    /// The real engine and synthesizer, with the clicks they post going to a log and their timers to a clock moved by hand.
    struct Rig {
        let engine: EventEngine
        let clock: ManualClock
        let log: PostLog
        let scheduler: ClickScheduler
        let settings: WhiskerSettings

        init(timing: ClickTiming, action: Action = .tripleClick(modifiers: [])) {
            clock = ManualClock()
            let log = PostLog()
            self.log = log
            scheduler = ClickScheduler(clock: clock, post: { log.record($0, $1, $2) })
            let synthesizer = EventSynthesizer(switchApp: { _ in }, clicks: scheduler, tripleClickTiming: { timing })
            engine = EventEngine(
                synthesizer: synthesizer,
                attribute: { _, _ in DeviceAttribution(id: "A", exact: true) },
                frontmostApp: { nil }
            )
            var settings = WhiskerSettings()
            settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: action)]
            self.settings = settings
            engine.update(settings)
        }

        @discardableResult
        func triggerDown(clickState: Int64 = 1, flags: CGEventFlags = []) -> Unmanaged<CGEvent>? {
            engine.handle(.otherMouseDown, TripleClickEngineTests.trigger(.otherMouseDown, clickState: clickState, flags: flags))
        }

        @discardableResult
        func triggerUp(clickState: Int64 = 1) -> Unmanaged<CGEvent>? {
            engine.handle(.otherMouseUp, TripleClickEngineTests.trigger(.otherMouseUp, clickState: clickState, flags: []))
        }
    }

    private static func trigger(_ type: CGEventType, clickState: Int64, flags: CGEventFlags) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: spot, mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.flags = flags
        return event
    }

    /// Everything that can call off a gesture, as the app reaches the engine with it.
    enum Interruption: CaseIterable {
        case physicalClick, physicalWheel
        case disabled, settingsChanged
        case permissionRevoked, quit
        case deviceDisconnected, tapPaused, sleep, appChanged

        func happens(to rig: Rig) {
            switch self {
            case .physicalClick:
                let event = CGEvent(mouseEventSource: nil, mouseType: .leftMouseDown, mouseCursorPosition: TripleClickEngineTests.spot, mouseButton: .left)!
                #expect(rig.engine.handle(.leftMouseDown, event) != nil, "the real click still gets through")
            case .physicalWheel:
                let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 1, wheel2: 0, wheel3: 0)!
                #expect(rig.engine.handle(.scrollWheel, event) != nil, "the real notch still gets through")
            case .disabled:
                var settings = rig.settings
                settings.general.enabled = false
                rig.engine.update(settings)
            case .settingsChanged:
                var settings = rig.settings
                settings.profiles[0].mappings = []
                rig.engine.update(settings)
            case .permissionRevoked, .quit:
                // The app stops the engine in both cases.
                rig.engine.stop()
            case .deviceDisconnected:
                rig.engine.devicesChanged(connected: ["B"])
            case .tapPaused:
                _ = rig.engine.handle(.tapDisabledByTimeout, CGEvent(source: nil)!)
            case .sleep:
                rig.engine.releaseAll()
            case .appChanged:
                rig.engine.frontmostAppChanged()
            }
        }
    }

    @Test func oneActivationIsThreeClicksAtTheTriggerWhateverClickCountItCarried() {
        let rig = Rig(timing: .immediate, action: .tripleClick(modifiers: .command))
        #expect(rig.triggerDown(clickState: 3, flags: .maskShift) == nil)

        #expect(rig.log.steps == wholeGesture)
        let held = CGEventFlags([.maskShift, .maskCommand])
        #expect(rig.log.entries.allSatisfy { $0.location == Self.spot && $0.flags == held })
        #expect(!rig.scheduler.isActive)
        #expect(rig.clock.pending == 0)

        #expect(rig.triggerUp(clickState: 3) == nil)
        #expect(rig.log.steps == wholeGesture)
    }

    @Test func spacedClicksFinishOnTheirOwnAndTheTriggersReleaseLeavesThemBe() {
        let rig = Rig(timing: .spaced(withinInterval: 0.5))
        rig.triggerDown()
        #expect(rig.log.steps == [press(1), release(1)])

        #expect(rig.triggerUp() == nil)
        rig.clock.advance(by: 0.125)
        #expect(rig.log.steps == [press(1), release(1), press(2), release(2)])
        rig.clock.advance(by: 0.125)
        #expect(rig.log.steps == wholeGesture)
        #expect(!rig.scheduler.isActive)
    }

    @Test(arguments: Interruption.allCases)
    func anInterruptionBetweenClicksDropsTheRest(interruption: Interruption) {
        let rig = Rig(timing: .spaced(withinInterval: 0.5))
        rig.triggerDown()
        interruption.happens(to: rig)
        rig.clock.advance(by: 2)

        #expect(rig.log.steps == [press(1), release(1)])
        #expect(!rig.scheduler.isActive)
        #expect(rig.clock.pending == 0)
    }

    @Test(arguments: Interruption.allCases)
    func anInterruptionWhileAClickIsDownStillReleasesIt(interruption: Interruption) {
        let rig = Rig(timing: ClickTiming(spacing: 0.5, hold: 0.25))
        rig.triggerDown(flags: .maskShift)
        #expect(rig.log.steps == [press(1)])
        interruption.happens(to: rig)
        rig.clock.advance(by: 2)

        let held = CGEventFlags.maskShift
        #expect(rig.log.entries == [
            .init(step: press(1), location: Self.spot, flags: held),
            .init(step: release(1), location: Self.spot, flags: held),
        ])
        #expect(!rig.scheduler.isActive)
    }

    @Test func theMouseThatStartedAGestureStayingConnectedKeepsItGoing() {
        let rig = Rig(timing: .spaced(withinInterval: 0.5))
        rig.triggerDown()
        rig.engine.devicesChanged(connected: ["A", "B"])
        rig.clock.advance(by: 0.25)

        #expect(rig.log.steps == wholeGesture)
    }

    @Test func aSecondActivationFinishesTheFirstAndStartsOver() {
        let rig = Rig(timing: .spaced(withinInterval: 0.5))
        rig.triggerDown()
        rig.triggerUp()
        rig.triggerDown()
        rig.clock.advance(by: 1)

        #expect(rig.log.steps == [press(1), release(1)] + wholeGesture)
        #expect(!rig.scheduler.isActive)
    }
}
