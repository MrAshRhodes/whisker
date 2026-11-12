import CoreGraphics
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Click Lock in the event engine")
struct ClickLockEngineTests {
    typealias Reports = AutoScrollEngineTests.Reports

    static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)
    static let notes = "com.example.notes"
    static let elsewhere = "com.example.elsewhere"

    /// What the engine posts for the lock, and the auto-scroll it was last told to run.
    final class Recorder: ActionPerforming, @unchecked Sendable {
        struct Call: Equatable {
            var action: Action
            var phase: ActionPhase

            /// The one press that holds the primary button down, and the one release that lets go of it.
            static let press = Call(action: .clickLock, phase: .down)
            static let release = Call(action: .clickLock, phase: .up)
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _running: AutoScrollSession?
        private var _autoScrollsStarted = 0

        var calls: [Call] { lock.withLock { _calls } }
        var running: AutoScrollSession? { lock.withLock { _running } }
        var autoScrollsStarted: Int { lock.withLock { _autoScrollsStarted } }

        func perform(_ action: Action, phase: ActionPhase, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {
            lock.withLock { _calls.append(Call(action: action, phase: phase)) }
        }

        func cancelPendingClicks() {}
        func cancelSequence(_ reason: SequenceStop) {}
        func releaseAll() {}

        func startAutoScroll(_ session: AutoScrollSession) {
            lock.withLock {
                _running = session
                _autoScrollsStarted += 1
            }
        }

        func cancelAutoScroll() {
            lock.withLock { _running = nil }
        }
    }

    /// Stands in for the second tap, which would retype movement as a drag while a lock is held.
    final class Movement: ClickLockMovement, @unchecked Sendable {
        private let lock = NSLock()
        private var _ready: Bool
        private var _enabled = false
        private var _invalidations = 0

        init(ready: Bool = true) { _ready = ready }

        var isReady: Bool {
            get { lock.withLock { _ready } }
            set { lock.withLock { _ready = newValue } }
        }
        var enabled: Bool { lock.withLock { _enabled } }
        var invalidations: Int { lock.withLock { _invalidations } }

        func setEnabled(_ enabled: Bool) { lock.withLock { _enabled = enabled } }

        func invalidate() {
            lock.withLock {
                _invalidations += 1
                _enabled = false
            }
        }
    }

    /// The movement factory the engine is given: hands out the stand-in (or nothing) and keeps the hooks it was given.
    final class Maker: @unchecked Sendable {
        let movement: Movement?
        private let lock = NSLock()
        private var _hooks: ClickLockMovementHooks?
        private var _made = 0

        init(_ movement: Movement?) { self.movement = movement }

        var hooks: ClickLockMovementHooks? { lock.withLock { _hooks } }
        /// How many times the engine asked for a movement tap.
        var made: Int { lock.withLock { _made } }

        func make(_ hooks: ClickLockMovementHooks) -> (any ClickLockMovement)? {
            lock.withLock {
                _hooks = hooks
                _made += 1
            }
            return movement
        }
    }

    struct Rig {
        let recorder: Recorder
        let reports: Reports
        let front: EventEngineBypassTests.FrontApp
        let maker: Maker
        let engine: EventEngine

        var movement: Movement? { maker.movement }
        var hooks: ClickLockMovementHooks? { maker.hooks }

        init(
            _ settings: WhiskerSettings = ClickLockEngineTests.settings(), movement: Movement? = Movement(),
            clock: any ClickClock = SystemClickClock()
        ) {
            let recorder = Recorder()
            let reports = Reports()
            let front = EventEngineBypassTests.FrontApp()
            front.activate(ClickLockEngineTests.notes)
            let maker = Maker(movement)
            let engine = EventEngine(
                synthesizer: recorder, attribute: { _, _ in ClickLockEngineTests.mouse }, frontmostApp: { front.bundleID },
                clock: clock, movement: { _, hooks in maker.make(hooks) }
            )
            engine.onClickLockChange = { reports.add($0) }
            engine.update(settings)
            self.recorder = recorder
            self.reports = reports
            self.front = front
            self.maker = maker
            self.engine = engine
        }

        /// Presses and releases the lock's button: the primary button is held from then on.
        func begin() {
            #expect(engine.handle(.otherMouseDown, ClickLockEngineTests.press()) == nil)
            #expect(engine.handle(.otherMouseUp, ClickLockEngineTests.release()) == nil)
        }
    }

    /// The lock is on button 5; an auto-scroll, when there is one, is on button 3.
    static func settings(optIn: Bool = true, enabled: Bool = true, autoScroll: Bool = false) -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.general.enabled = enabled
        settings.general.experimentalClickLock = optIn
        settings.profiles[0].mappings = [Mapping(trigger: .button(5), action: .clickLock)]
        if autoScroll {
            settings.profiles[0].mappings.append(Mapping(trigger: .button(3), action: .autoScroll(AutoScroll())))
        }
        return settings
    }

    /// The mouse chatters on button 5, so a press that follows its release closely is held back by the filter.
    static func filteredSettings() -> WhiskerSettings {
        var settings = Self.settings()
        settings.devices[mouse.id] = DeviceSettings(clickDebounce: ClickDebounceSettings(buttons: [5], interval: 0.1))
        return settings
    }

    static func press(_ button: Int = 5) -> CGEvent { AutoScrollEngineTests.trigger(button, down: true) }
    static func release(_ button: Int = 5) -> CGEvent { AutoScrollEngineTests.trigger(button, down: false) }

    static func drag(_ button: Int = 5) -> CGEvent {
        let event = CGEvent(
            mouseEventSource: nil, mouseType: .otherMouseDragged, mouseCursorPosition: AutoScrollEngineTests.anchor, mouseButton: .center
        )!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return event
    }

    /// Waits for what the engine queued for the main queue, which is only ever posted there.
    static func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    // MARK: Holding and letting go

    @Test func twoPressesHoldAndLetGoOfThePrimaryButtonOnce() async throws {
        let rig = Rig()
        let hooks = try #require(rig.hooks)
        #expect(!hooks.isLockActive())

        #expect(rig.engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(rig.recorder.calls == [.press])
        #expect(hooks.isLockActive())
        #expect(rig.movement?.enabled == true)

        // Moving with the trigger still down is movement of the held button, and letting go of it ends nothing.
        let dragging = Self.drag()
        #expect(rig.engine.handle(.otherMouseDragged, dragging) != nil)
        #expect(dragging.type == .leftMouseDragged)
        #expect(dragging.getIntegerValueField(.mouseEventButtonNumber) == 0)
        #expect(rig.engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(rig.recorder.calls == [.press])

        // The press that lets go is used up too, and movement under it is only movement.
        #expect(rig.engine.handle(.otherMouseDown, Self.press()) == nil)
        let moving = Self.drag()
        #expect(rig.engine.handle(.otherMouseDragged, moving) != nil)
        #expect(moving.type == .mouseMoved)
        #expect(rig.engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(!hooks.isLockActive())
        #expect(rig.movement?.enabled == false)

        await Self.drainMainQueue()
        #expect(rig.reports.values == [true, false])
        #expect(rig.reports.allOnMain)
    }

    @Test func aPrimaryPressLetsGoFirstAndThenReachesTheAppAsItWas() {
        let rig = Rig()
        rig.begin()

        let primary = AutoScrollEngineTests.click(.leftMouseDown)
        #expect(rig.engine.handle(.leftMouseDown, primary) != nil)
        #expect(primary.type == .leftMouseDown)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.movement?.enabled == false)
        #expect(rig.engine.handle(.leftMouseUp, AutoScrollEngineTests.click(.leftMouseUp)) != nil)
        #expect(rig.recorder.calls == [.press, .release])
    }

    @Test func aPressOfTheLocksButtonIsLeftAloneWhileClickLockIsSwitchedOff() {
        let rig = Rig(Self.settings(optIn: false))
        #expect(rig.engine.handle(.otherMouseDown, Self.press()) != nil)
        #expect(rig.engine.handle(.otherMouseUp, Self.release()) != nil)
        #expect(rig.recorder.calls.isEmpty)
        #expect(rig.maker.made == 0)
    }

    @Test func releasingWithNothingHeldPostsNothing() async {
        let rig = Rig()
        rig.engine.releaseClickLock(.menu)
        rig.engine.releaseClickLock(.permissionLoss)
        #expect(rig.recorder.calls.isEmpty)
        await Self.drainMainQueue()
        #expect(rig.reports.values.isEmpty)
    }

    // MARK: Every way out

    enum Interruption: CaseIterable {
        case settingsEdited, switchedOff, sleep, quit, accessRevoked, menuCommand, appChanged, mouseUnplugged
        case tapPaused, tapSwitchedOff, movementTapPaused, buttonCapture

        func apply(to rig: Rig) {
            let engine = rig.engine
            switch self {
            case .settingsEdited: engine.update(ClickLockEngineTests.settings())
            case .switchedOff: engine.update(ClickLockEngineTests.settings(enabled: false))
            case .sleep: engine.releaseAll(because: .sleep)
            case .quit: engine.releaseAll()
            case .accessRevoked:
                engine.releaseClickLock(.permissionLoss)
                engine.stop()
            case .menuCommand: engine.releaseClickLock(.menu)
            case .appChanged: engine.frontmostAppChanged()
            case .mouseUnplugged: engine.devicesChanged(connected: [])
            case .tapPaused: _ = engine.handle(.tapDisabledByTimeout, CGEvent(source: nil)!)
            case .tapSwitchedOff: _ = engine.handle(.tapDisabledByUserInput, CGEvent(source: nil)!)
            case .movementTapPaused: rig.hooks?.interrupted()
            case .buttonCapture: engine.setCapturing(true)
            }
        }
    }

    @Test(arguments: Interruption.allCases)
    func everyWayOfLosingTheLockLetsGoOfTheButtonExactlyOnce(_ interruption: Interruption) async {
        let rig = Rig()
        rig.begin()
        #expect(rig.recorder.calls == [.press])

        interruption.apply(to: rig)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.movement?.enabled == false)

        // Whatever comes next finds nothing left to let go of.
        interruption.apply(to: rig)
        rig.engine.releaseClickLock(.menu)
        rig.engine.releaseAll()
        rig.engine.frontmostAppChanged()
        #expect(rig.recorder.calls == [.press, .release])

        await Self.drainMainQueue()
        #expect(rig.reports.values == [true, false])
        #expect(rig.reports.allOnMain)
    }

    @Test func aLockThatBeganInAnotherAppLetsGoBeforeTheNextEventIsHandled() async {
        let rig = Rig()
        rig.begin()

        // The front-app monitor hasn't spoken yet, but the tap already sees another app in front.
        rig.front.activate(Self.elsewhere)
        #expect(rig.engine.handle(.scrollWheel, AutoScrollEngineTests.wheel(1)) != nil)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.engine.handle(.scrollWheel, AutoScrollEngineTests.wheel(1)) != nil)
        rig.engine.frontmostAppChanged()
        #expect(rig.recorder.calls == [.press, .release])

        await Self.drainMainQueue()
        #expect(rig.reports.values == [true, false])
    }

    @Test func aChangeOfMiceKeepsTheLockWhileTheMouseThatBeganItIsStillThere() {
        let rig = Rig()
        rig.begin()

        rig.engine.devicesChanged(connected: [Self.mouse.id, "1234:5678"])
        #expect(rig.recorder.calls == [.press])
        #expect(rig.movement?.enabled == true)

        rig.engine.devicesChanged(connected: ["1234:5678"])
        #expect(rig.recorder.calls == [.press, .release])
    }

    // MARK: Without a movement tap

    @Test(arguments: [nil, Movement(ready: false)])
    func aLockNeverBeginsWithoutAMovementTapThatCanBeSwitchedOn(_ movement: Movement?) async {
        let rig = Rig(movement: movement)

        // The press is used up, not passed on as a click of the button, and nothing is held.
        #expect(rig.engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(rig.engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(rig.recorder.calls.isEmpty)
        #expect(rig.movement?.enabled != true)
        #expect(rig.engine.handle(.leftMouseDown, AutoScrollEngineTests.click(.leftMouseDown)) != nil)
        #expect(rig.recorder.calls.isEmpty)

        await Self.drainMainQueue()
        #expect(rig.reports.values.isEmpty)
    }

    @Test func aMovementTapThatBecomesReadyLetsTheNextPressBeginALock() {
        let movement = Movement(ready: false)
        let rig = Rig(movement: movement)
        #expect(rig.engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(rig.engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(rig.recorder.calls.isEmpty)

        movement.isReady = true
        rig.begin()
        #expect(rig.recorder.calls == [.press])
        #expect(movement.enabled)
    }

    @Test func theMovementTapIsOnlyMadeWhileClickLockIsOnAndMappedAndGoesWhenItIsNot() {
        #expect(Rig(Self.settings(optIn: false)).maker.made == 0)
        #expect(Rig(Self.settings(enabled: false)).maker.made == 0)
        var unmapped = Self.settings()
        unmapped.profiles[0].mappings = []
        #expect(Rig(unmapped).maker.made == 0)

        let rig = Rig()
        #expect(rig.maker.made == 1)
        // Editing something else keeps the tap that is there.
        rig.engine.update(Self.settings())
        #expect(rig.maker.made == 1)
        #expect(rig.movement?.invalidations == 0)

        rig.engine.update(Self.settings(optIn: false))
        #expect(rig.movement?.invalidations == 1)
        rig.engine.update(Self.settings())
        #expect(rig.maker.made == 2)
    }

    @Test func aStoppedEngineDropsTheMovementTapAndDoesNotMakeAnotherUntilItStarts() {
        let rig = Rig()
        rig.begin()
        rig.engine.stop()
        #expect(rig.movement?.invalidations == 1)
        #expect(rig.recorder.calls == [.press, .release])

        rig.engine.update(Self.settings())
        #expect(rig.maker.made == 1)
        // Presses go through untouched while it is stopped.
        #expect(rig.engine.handle(.otherMouseDown, Self.press()) != nil)
        #expect(rig.recorder.calls == [.press, .release])
    }

    @Test func movementBecomesADragOfThePrimaryButton() {
        let moved = CGEvent(mouseEventSource: nil, mouseType: .mouseMoved, mouseCursorPosition: CGPoint(x: 5, y: 6), mouseButton: .left)!
        ClickLockMovementTap.becomeDrag(moved)
        #expect(moved.type == .leftMouseDragged)
        #expect(moved.getIntegerValueField(.mouseEventButtonNumber) == 0)
        #expect(moved.getIntegerValueField(.mouseEventClickState) == 1)
        #expect(moved.location == CGPoint(x: 5, y: 6))
    }

    // MARK: Presses the filter held back

    @Test func primaryEscapeIsNeverDebouncedAndItsReleaseHasNoDelayedTail() {
        let clock = ClickDebounceEngineTests.FakeClock()
        var settings = Self.settings()
        settings.general.allowPrimaryButtonRemap = true
        settings.devices[Self.mouse.id] = DeviceSettings(clickDebounce: ClickDebounceSettings(buttons: [0], interval: 0.1))
        let rig = Rig(settings, clock: clock)
        #expect(rig.engine.handle(.leftMouseDown, AutoScrollEngineTests.click(.leftMouseDown)) != nil)
        #expect(rig.engine.handle(.leftMouseUp, AutoScrollEngineTests.click(.leftMouseUp)) != nil)
        rig.begin()
        #expect(rig.engine.handle(.leftMouseDown, AutoScrollEngineTests.click(.leftMouseDown)) != nil)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.movement?.enabled == false)
        #expect(clock.pending == 0)
        #expect(rig.engine.handle(.leftMouseUp, AutoScrollEngineTests.click(.leftMouseUp)) != nil)
        // Only the escape is exempt: an ordinary short repeat is still filtered as a complete pair.
        #expect(rig.engine.handle(.leftMouseDown, AutoScrollEngineTests.click(.leftMouseDown)) == nil)
        #expect(rig.engine.handle(.leftMouseUp, AutoScrollEngineTests.click(.leftMouseUp)) == nil)
        #expect(clock.pending == 0)
        clock.advance(by: 1)
        #expect(rig.recorder.calls == [.press, .release])
    }

    @Test func primaryEscapeKeepsPendingClicksOrderedEvenIfAReplayEndsTheLock() {
        let clock = ClickDebounceEngineTests.FakeClock()
        var settings = Self.filteredSettings()
        settings.general.allowPrimaryButtonRemap = true
        settings.devices[Self.mouse.id]?.clickDebounce = ClickDebounceSettings(buttons: [0, 5], interval: 0.1)
        settings.profiles[0].mappings.append(Mapping(trigger: .button(0), action: .none))
        let rig = Rig(settings, clock: clock)
        #expect(rig.engine.handle(.leftMouseDown, AutoScrollEngineTests.click(.leftMouseDown)) == nil)
        #expect(rig.engine.handle(.leftMouseUp, AutoScrollEngineTests.click(.leftMouseUp)) == nil)
        rig.begin()
        #expect(rig.engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(clock.pending == 1)
        // Replaying the waiting trigger lets go first; the physical escape still passes unchanged.
        #expect(rig.engine.handle(.leftMouseDown, AutoScrollEngineTests.click(.leftMouseDown)) != nil)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.engine.handle(.leftMouseUp, AutoScrollEngineTests.click(.leftMouseUp)) != nil)
        #expect(rig.engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(clock.pending == 0)
        clock.advance(by: 1)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.movement?.enabled == false)
    }

    @Test func aPressTheFilterHeldBackCannotBeginALock() async {
        let clock = ClickDebounceEngineTests.FakeClock()
        let rig = Rig(Self.filteredSettings(), clock: clock)
        rig.begin()
        rig.engine.releaseClickLock(.menu)
        #expect(rig.recorder.calls == [.press, .release])

        // The next press follows the release closely, so it waits; by the time it is let through, the user's
        // moment has passed and a lock must not begin.
        #expect(rig.engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(clock.pending == 1)
        clock.advance(by: 1)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.movement?.enabled == false)
        #expect(rig.engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(rig.recorder.calls == [.press, .release])

        await Self.drainMainQueue()
        #expect(rig.reports.values == [true, false])
    }

    @Test func aPressTheFilterHeldBackStillLetsGoOfALockThatIsOn() async {
        let clock = ClickDebounceEngineTests.FakeClock()
        let rig = Rig(Self.filteredSettings(), clock: clock)
        rig.begin()

        #expect(rig.engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(rig.recorder.calls == [.press])
        clock.advance(by: 1)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.movement?.enabled == false)

        await Self.drainMainQueue()
        #expect(rig.reports.values == [true, false])
    }

    // MARK: Auto-scroll

    @Test func aLockBeginningEndsARunningAutoScrollAndNoneStartsWhileItIsHeld() {
        let rig = Rig(Self.settings(autoScroll: true))
        #expect(rig.engine.handle(.otherMouseDown, Self.press(3)) == nil)
        #expect(rig.engine.handle(.otherMouseUp, Self.release(3)) == nil)
        #expect(rig.recorder.running != nil)

        // The press that begins the lock ends the auto-scroll first, and the two never run together.
        rig.begin()
        #expect(rig.recorder.running == nil)
        #expect(rig.recorder.calls == [.press])

        #expect(rig.engine.handle(.otherMouseDown, Self.press(3)) == nil)
        #expect(rig.engine.handle(.otherMouseUp, Self.release(3)) == nil)
        #expect(rig.recorder.running == nil)
        #expect(rig.recorder.autoScrollsStarted == 1)

        // Once the lock lets go, the same button starts an auto-scroll again.
        rig.engine.releaseClickLock(.menu)
        #expect(rig.recorder.calls == [.press, .release])
        #expect(rig.engine.handle(.otherMouseDown, Self.press(3)) == nil)
        #expect(rig.engine.handle(.otherMouseUp, Self.release(3)) == nil)
        #expect(rig.recorder.running != nil)
        #expect(rig.recorder.autoScrollsStarted == 2)
    }
}
