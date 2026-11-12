import CoreGraphics
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Click debounce in the event engine")
struct ClickDebounceEngineTests {
    /// Timers are held until the test fires them; time is the real uptime plus an offset the test moves.
    final class FakeClock: ClickClock, @unchecked Sendable {
        private let lock = NSLock()
        private var offset: TimeInterval = 0
        private var timers: [Int: @Sendable () -> Void] = [:]
        private var next = 0

        var now: TimeInterval { ProcessInfo.processInfo.systemUptime + lock.withLock { offset } }
        var pending: Int { lock.withLock { timers.count } }

        func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
            let id = lock.withLock { () -> Int in
                next += 1
                timers[next] = body
                return next
            }
            return { [weak self] in _ = self?.lock.withLock { self?.timers[id] = nil } }
        }

        func advance(by seconds: TimeInterval) {
            let due = lock.withLock { () -> [@Sendable () -> Void] in
                offset += seconds
                defer { timers.removeAll() }
                return Array(timers.values)
            }
            due.forEach { $0() }
        }
    }

    static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)

    static func makeEngine(_ recorder: EventEngineTests.Recorder, _ clock: FakeClock, buttons: [Int] = [3], device: @escaping @Sendable () -> DeviceAttribution? = { mouse }) -> EventEngine {
        let engine = EventEngine(synthesizer: recorder, attribute: { _, _ in device() }, frontmostApp: { nil }, clock: clock)
        engine.update(settings(buttons: buttons))
        return engine
    }

    static func settings(buttons: [Int]?) -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = []
        let config = buttons.map { ClickDebounceSettings(buttons: $0, interval: 0.1) }
        settings.devices[mouse.id] = DeviceSettings(clickDebounce: config)
        return settings
    }

    static func event(_ type: CGEventType, button: Int = 3, count: Int64 = 1) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: CGPoint(x: 4, y: 5), mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.setIntegerValueField(.mouseEventClickState, value: count)
        return event
    }

    /// A click that is delivered, so the next press counts as a repeat.
    static func firstClick(_ engine: EventEngine) {
        #expect(engine.handle(.otherMouseDown, event(.otherMouseDown)) != nil)
        #expect(engine.handle(.otherMouseUp, event(.otherMouseUp)) != nil)
    }

    @Test func aShortRepeatPairNeverReachesTheApp() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeEngine(recorder, FakeClock())
        Self.firstClick(engine)
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) == nil)
        #expect(recorder.calls.isEmpty)
    }

    @Test func aPressHeldPastTheIntervalIsPostedInPlaceAndItsReleaseGoesThrough() {
        let recorder = EventEngineTests.Recorder()
        let clock = FakeClock()
        let engine = Self.makeEngine(recorder, clock)
        Self.firstClick(engine)
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        #expect(clock.pending == 1)
        clock.advance(by: 1)
        #expect(recorder.calls == [.init(action: .click(button: 3, modifiers: []), phase: .down, clickState: 2)])
        #expect(clock.pending == 0)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) != nil)
    }

    @Test func aDragFlushesThePressBeforeItAndTheDragCarriesOn() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeEngine(recorder, FakeClock())
        Self.firstClick(engine)
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        #expect(engine.handle(.otherMouseDragged, Self.event(.otherMouseDragged, count: 2)) != nil)
        #expect(recorder.calls.map(\.phase) == [.down])
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) != nil)
    }

    @Test func aCountThePairLeftBehindIsPutRight() throws {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeEngine(recorder, FakeClock())
        Self.firstClick(engine)
        _ = engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2))
        _ = engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2))
        let third = Self.event(.otherMouseDown, count: 3)
        // Posted in-process only to read the field back; the repeat is far enough from the release to pass.
        Thread.sleep(forTimeInterval: 0.15)
        let passed = try #require(engine.handle(.otherMouseDown, third)).takeUnretainedValue()
        #expect(passed.getIntegerValueField(.mouseEventClickState) == 2)
    }

    @Test func changingSettingsDropsTheHeldPressAndItsRelease() {
        let recorder = EventEngineTests.Recorder()
        let clock = FakeClock()
        let engine = Self.makeEngine(recorder, clock)
        Self.firstClick(engine)
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        engine.update(Self.settings(buttons: nil))
        #expect(clock.pending == 0)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) == nil)
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown)) != nil)
        #expect(recorder.calls.isEmpty)
    }

    @Test func standingDownOrLosingTheMouseLeavesNothingHeld() {
        for cleanup in [{ (engine: EventEngine) in engine.releaseAll() }, { $0.devicesChanged(connected: []) }] {
            let recorder = EventEngineTests.Recorder()
            let clock = FakeClock()
            let engine = Self.makeEngine(recorder, clock)
            Self.firstClick(engine)
            _ = engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2))
            cleanup(engine)
            #expect(clock.pending == 0)
            clock.advance(by: 1)
            #expect(recorder.calls.isEmpty)
        }
    }

    @Test func otherDevicesAndTheWheelAreNotFiltered() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeEngine(recorder, FakeClock(), device: { DeviceAttribution(id: "1234:5678", exact: true) })
        Self.firstClick(engine)
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) != nil)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) != nil)
    }

    @Test func aHeldPressOfAMappedButtonRunsItsActionWhenFlushed() {
        let recorder = EventEngineTests.Recorder()
        let clock = FakeClock()
        let engine = Self.makeEngine(recorder, clock)
        var settings = Self.settings(buttons: [3])
        let action = Action.click(button: 1, modifiers: [])
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: action)]
        engine.update(settings)
        // The first click runs its action; the repeat is held and, once flushed, runs it once more.
        _ = engine.handle(.otherMouseDown, Self.event(.otherMouseDown))
        _ = engine.handle(.otherMouseUp, Self.event(.otherMouseUp))
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        #expect(recorder.calls.map(\.phase) == [.down, .up])
        clock.advance(by: 1)
        #expect(recorder.calls.map(\.phase) == [.down, .up, .down])
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) == nil)
        #expect(recorder.calls.map(\.phase) == [.down, .up, .down, .up])
    }

    /// The primary button swapped with the secondary one, and the primary button filtered.
    private static func swappingEngine(_ recorder: EventEngineTests.Recorder, _ clock: FakeClock) -> EventEngine {
        var settings = Self.settings(buttons: [0])
        settings.general.allowPrimaryButtonRemap = true
        settings.devices[mouse.id]?.swapPrimarySecondary = true
        let engine = EventEngine(synthesizer: recorder, attribute: { _, _ in mouse }, frontmostApp: { nil }, clock: clock)
        engine.update(settings)
        return engine
    }

    @Test func theFilterJudgesThePhysicalButtonBeforeAnySwap() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.swappingEngine(recorder, FakeClock())
        let right = Action.click(button: 1, modifiers: [])
        #expect(engine.handle(.leftMouseDown, Self.event(.leftMouseDown, button: 0)) == nil)
        #expect(engine.handle(.leftMouseUp, Self.event(.leftMouseUp, button: 0)) == nil)
        #expect(recorder.calls == [
            .init(action: right, phase: .down, clickState: 1),
            .init(action: right, phase: .up, clickState: 1),
        ])

        #expect(engine.handle(.leftMouseDown, Self.event(.leftMouseDown, button: 0, count: 2)) == nil)
        #expect(engine.handle(.leftMouseUp, Self.event(.leftMouseUp, button: 0, count: 2)) == nil)
        #expect(recorder.calls.count == 2)
    }

    @Test func aSwappedPressHeldBackByTheFilterIsDeliveredAsTheOtherButtonOnceItIsKept() {
        let recorder = EventEngineTests.Recorder()
        let clock = FakeClock()
        let engine = Self.swappingEngine(recorder, clock)
        let right = Action.click(button: 1, modifiers: [])
        _ = engine.handle(.leftMouseDown, Self.event(.leftMouseDown, button: 0))
        _ = engine.handle(.leftMouseUp, Self.event(.leftMouseUp, button: 0))
        #expect(engine.handle(.leftMouseDown, Self.event(.leftMouseDown, button: 0, count: 2)) == nil)
        clock.advance(by: 1)
        #expect(recorder.calls.suffix(1) == [.init(action: right, phase: .down, clickState: 2)])
        #expect(engine.handle(.leftMouseUp, Self.event(.leftMouseUp, button: 0, count: 2)) == nil)
        #expect(recorder.calls.map(\.phase) == [.down, .up, .down, .up])
        #expect(recorder.calls.allSatisfy { $0.action == right })
    }

    // MARK: Interruptions

    @Test @MainActor func syntheticEventsAreNeverFilteredOrCounted() async {
        let recorder = EventEngineTests.Recorder()
        let clock = FakeClock()
        let engine = Self.makeEngine(recorder, clock)
        let reports = Reports.watching(engine)
        engine.setClickFilterTest(device: Self.mouse.id)
        Self.firstClick(engine)
        for type in [CGEventType.otherMouseDown, .otherMouseUp, .otherMouseDown, .otherMouseUp] {
            let synthetic = Self.event(type, count: 2)
            synthetic.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.marker)
            #expect(engine.handle(type, synthetic) != nil)
        }
        #expect(clock.pending == 0)
        // A real repeat is still measured from the real click's release.
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        await Self.drainMainQueue()
        #expect(reports.latest?[3] == ClickFilterTally.Counts(accepted: 1))
    }

    @Test func aPausedTapDiscardsTheHeldPressAndSwallowsItsRelease() throws {
        let recorder = EventEngineTests.Recorder()
        let clock = FakeClock()
        let engine = Self.makeEngine(recorder, clock)
        Self.firstClick(engine)
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        #expect(engine.handle(.tapDisabledByTimeout, try #require(CGEvent(source: nil))) != nil)
        #expect(clock.pending == 0)
        clock.advance(by: 1)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) == nil)
        #expect(recorder.calls.isEmpty)
        // The next click is a fresh one.
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown)) != nil)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp)) != nil)
    }

    @Test func recordingAButtonSwallowsOnlyTheReleaseOfAPressItDiscarded() {
        let recorder = EventEngineTests.Recorder()
        let clock = FakeClock()
        let engine = Self.makeEngine(recorder, clock)
        Self.firstClick(engine)
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        engine.setCapturing(true)
        #expect(clock.pending == 0)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) == nil)
        // Everything else reaches the recorder untouched.
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown)) != nil)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp)) != nil)
        engine.setCapturing(false)
        #expect(recorder.calls.isEmpty)
    }

    @Test func aDroppedPairOfAMappedButtonRunsNoAction() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeEngine(recorder, FakeClock())
        var settings = Self.settings(buttons: [3])
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .click(button: 1, modifiers: []))]
        engine.update(settings)
        _ = engine.handle(.otherMouseDown, Self.event(.otherMouseDown))
        _ = engine.handle(.otherMouseUp, Self.event(.otherMouseUp))
        #expect(engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2)) == nil)
        #expect(engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2)) == nil)
        #expect(recorder.calls.map(\.phase) == [.down, .up])
    }

    // MARK: Local test

    /// Copies of the local test as the settings window receives them.
    @MainActor final class Reports {
        var values: [ClickFilterTally?] = []
        var latest: ClickFilterTally? { values.last ?? nil }

        static func watching(_ engine: EventEngine) -> Reports {
            let reports = Reports()
            engine.onClickFilterTest = { reports.values.append($0) }
            return reports
        }
    }

    /// Runs everything already queued on the main queue, where the engine hands over its copies.
    @MainActor static func drainMainQueue() async {
        await withCheckedContinuation { (done: CheckedContinuation<Void, Never>) in DispatchQueue.main.async { done.resume() } }
    }

    @Test @MainActor func theLocalTestReachesTheMainQueueAndFollowsTheSettingsAndTheMouse() async {
        let recorder = EventEngineTests.Recorder()
        let clock = FakeClock()
        let engine = Self.makeEngine(recorder, clock)
        let reports = Reports.watching(engine)
        let fresh = ClickFilterTally(device: Self.mouse.id, buttons: [3])
        engine.setClickFilterTest(device: Self.mouse.id)
        Self.firstClick(engine)
        _ = engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 2))
        _ = engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 2))
        _ = engine.handle(.otherMouseDown, Self.event(.otherMouseDown, count: 3))
        clock.advance(by: 1)
        _ = engine.handle(.otherMouseUp, Self.event(.otherMouseUp, count: 3))
        // The tap thread never waits for the settings window: copies arrive once the main queue runs.
        #expect(reports.values.isEmpty)
        await Self.drainMainQueue()
        #expect(reports.latest?[3] == ClickFilterTally.Counts(accepted: 2, filtered: 1))

        // A change that doesn't decide what the filter does keeps the counts.
        var unrelated = Self.settings(buttons: [3])
        unrelated.devices[Self.mouse.id]?.wheel.invertVertical = true
        engine.update(unrelated)
        await Self.drainMainQueue()
        #expect(reports.latest?[3] == ClickFilterTally.Counts(accepted: 2, filtered: 1))

        // Sleep starts them again from zero, and so does a change to the filter.
        engine.releaseAll(because: .sleep)
        await Self.drainMainQueue()
        #expect(reports.latest == fresh)
        Self.firstClick(engine)
        var shorter = Self.settings(buttons: [3])
        shorter.devices[Self.mouse.id]?.clickDebounce?.interval = 0.05
        engine.update(shorter)
        await Self.drainMainQueue()
        #expect(reports.latest == fresh)

        // Switching the filter off ends the test, and so does losing the mouse.
        engine.update(Self.settings(buttons: nil))
        await Self.drainMainQueue()
        #expect(reports.values.last == .some(nil))
        engine.update(Self.settings(buttons: [3]))
        engine.setClickFilterTest(device: Self.mouse.id)
        engine.devicesChanged(connected: [])
        await Self.drainMainQueue()
        #expect(Array(reports.values.suffix(2)) == [fresh, nil])
    }
}
