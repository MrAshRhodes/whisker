import CoreGraphics
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Auto-scroll in the event engine")
struct AutoScrollEngineTests {
    /// Stands in for the synthesizer, which would run a session on a timer. This one only remembers which session
    /// it was last told to run, so what the engine starts and stops can be read straight off it.
    final class Recorder: ActionPerforming, @unchecked Sendable {
        private let lock = NSLock()
        private var _started: [AutoScrollSession] = []
        private var _running: AutoScrollSession?
        private var _cancels = 0
        private var _performed: [Action] = []

        var started: [AutoScrollSession] { lock.withLock { _started } }
        var running: AutoScrollSession? { lock.withLock { _running } }
        var cancels: Int { lock.withLock { _cancels } }
        var performed: [Action] { lock.withLock { _performed } }

        func perform(_ action: Action, phase: ActionPhase, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {
            lock.withLock { _performed.append(action) }
        }

        func cancelPendingClicks() {}
        func cancelSequence(_ reason: SequenceStop) {}
        func releaseAll() {}

        func startAutoScroll(_ session: AutoScrollSession) {
            lock.withLock {
                _started.append(session)
                _running = session
            }
        }

        func cancelAutoScroll() {
            lock.withLock {
                _cancels += 1
                _running = nil
            }
        }
    }

    final class Reports: @unchecked Sendable {
        private let lock = NSLock()
        private var _values: [Bool] = []
        private var _onMain: [Bool] = []
        var values: [Bool] { lock.withLock { _values } }
        var allOnMain: Bool { lock.withLock { _onMain.allSatisfy { $0 } } }

        func add(_ active: Bool) {
            lock.withLock {
                _values.append(active)
                _onMain.append(Thread.isMainThread)
            }
        }
    }

    static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)
    static let notes = "com.example.notes"
    static let game = "com.example.game"
    static let anchor = CGPoint(x: 200, y: 150)

    static func settings(_ config: AutoScroll = AutoScroll(), invertWheel: Bool = false, enabled: Bool = true) -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.general.enabled = enabled
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .autoScroll(config))]
        if invertWheel { settings.devices[mouse.id] = DeviceSettings(wheel: WheelSettings(invertVertical: true)) }
        return settings
    }

    static func frontApp(_ bundleID: String? = notes) -> EventEngineBypassTests.FrontApp {
        let front = EventEngineBypassTests.FrontApp()
        front.activate(bundleID)
        return front
    }

    static func makeEngine(
        _ recorder: Recorder, _ settings: WhiskerSettings = settings(), front: EventEngineBypassTests.FrontApp = frontApp()
    ) -> EventEngine {
        let engine = EventEngine(synthesizer: recorder, attribute: { _, _ in mouse }, frontmostApp: { front.bundleID })
        engine.update(settings)
        return engine
    }

    static func trigger(_ button: Int = 3, down: Bool, at point: CGPoint = anchor) -> CGEvent {
        let event = CGEvent(
            mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp, mouseCursorPosition: point, mouseButton: .center
        )!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        return event
    }

    /// A press or release of the primary, secondary or a further button, by the event type that carries it.
    static func click(_ type: CGEventType, at point: CGPoint = CGPoint(x: 500, y: 400)) -> CGEvent {
        let button: CGMouseButton
        switch type {
        case .leftMouseDown, .leftMouseUp: button = .left
        case .rightMouseDown, .rightMouseUp: button = .right
        default: button = .center
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)!
        if button == .center { event.setIntegerValueField(.mouseEventButtonNumber, value: 4) }
        return event
    }

    static func wheel(_ lines: Int32, momentum: Bool = false) -> CGEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: lines, wheel2: 0, wheel3: 0)!
        if momentum { event.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2) }
        return event
    }

    // MARK: Starting and stopping

    @Test func pressingTheTriggerAnchorsWhereThePointerIsAndSwallowsTheButton() {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder)

        #expect(engine.handle(.otherMouseDown, Self.trigger(down: true)) == nil)
        #expect(recorder.started.count == 1)
        #expect(recorder.running?.anchor == PointerPoint(x: 200, y: 150))
        #expect(recorder.running?.generation == 1)
        #expect(recorder.running?.config == AutoScroll())

        // Letting go doesn't end it: it runs until something else does.
        #expect(engine.handle(.otherMouseUp, Self.trigger(down: false, at: CGPoint(x: 260, y: 300))) == nil)
        #expect(recorder.running?.generation == 1)
        #expect(recorder.cancels == 0)
        // It isn't an action to perform: the scroller runs it.
        #expect(recorder.performed.isEmpty)
    }

    @Test func theTriggerPressedAgainStopsItAndStartsNothingNew() {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder)
        _ = engine.handle(.otherMouseDown, Self.trigger(down: true))
        _ = engine.handle(.otherMouseUp, Self.trigger(down: false))

        #expect(engine.handle(.otherMouseDown, Self.trigger(down: true)) == nil)
        #expect(recorder.running == nil)
        #expect(recorder.started.count == 1)
        #expect(recorder.cancels == 1)
        #expect(engine.handle(.otherMouseUp, Self.trigger(down: false)) == nil)

        // The press after that anchors a new one.
        #expect(engine.handle(.otherMouseDown, Self.trigger(down: true)) == nil)
        #expect(recorder.started.map(\.generation) == [1, 2])
        #expect(recorder.running?.generation == 2)
    }

    @Test func aTriggerOfAnotherAutoScrollReplacesTheRunningOneWithoutTheAppSeeingItStop() async {
        var settings = Self.settings()
        settings.profiles[0].mappings.append(Mapping(trigger: .button(4), action: .autoScroll(AutoScroll(axes: .twoAxis))))
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder, settings)
        let reports = Reports()
        engine.onAutoScrollActive = { reports.add($0) }

        _ = engine.handle(.otherMouseDown, Self.trigger(down: true))
        #expect(engine.handle(.otherMouseDown, Self.trigger(4, down: true, at: CGPoint(x: 300, y: 320))) == nil)

        #expect(recorder.started.map(\.generation) == [1, 2])
        #expect(recorder.running?.config.axes == .twoAxis)
        #expect(recorder.running?.anchor == PointerPoint(x: 300, y: 320))
        #expect(recorder.cancels == 0)
        for _ in 0..<100 where reports.values.isEmpty { try? await Task.sleep(nanoseconds: 20_000_000) }
        try? await Task.sleep(nanoseconds: 50_000_000)
        #expect(reports.values == [true])
    }

    @Test func anyOtherClickEndsItAndStillReachesWhatIsUnderThePointer() {
        let clicks: [(down: CGEventType, up: CGEventType)] = [
            (.leftMouseDown, .leftMouseUp), (.rightMouseDown, .rightMouseUp), (.otherMouseDown, .otherMouseUp),
        ]
        for (down, up) in clicks {
            let recorder = Recorder()
            let engine = Self.makeEngine(recorder)
            _ = engine.handle(.otherMouseDown, Self.trigger(down: true))
            _ = engine.handle(.otherMouseUp, Self.trigger(down: false))
            #expect(recorder.running != nil)

            let press = Self.click(down)
            #expect(engine.handle(down, press) != nil)
            // Already stopped when the click is handed on, so nothing can scroll under it.
            #expect(recorder.running == nil)
            #expect(press.type == down)
            #expect(press.location == CGPoint(x: 500, y: 400))
            #expect(engine.handle(up, Self.click(up)) != nil)
            #expect(recorder.started.count == 1)
            #expect(recorder.performed.isEmpty)
        }
    }

    @Test func aRealWheelTurnEndsItButMomentumAndEmptyEventsDoNot() {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder)
        _ = engine.handle(.otherMouseDown, Self.trigger(down: true))

        #expect(engine.handle(.scrollWheel, Self.wheel(1, momentum: true)) != nil)
        #expect(engine.handle(.scrollWheel, Self.wheel(0)) != nil)
        #expect(recorder.running != nil)

        let notch = Self.wheel(-1)
        #expect(engine.handle(.scrollWheel, notch) != nil)
        #expect(notch.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1)
        #expect(recorder.running == nil)
    }

    @Test func theMasterSwitchAndBypassedAppsStartNothing() {
        let off = Recorder()
        let disabled = Self.makeEngine(off, Self.settings(enabled: false))
        #expect(disabled.handle(.otherMouseDown, Self.trigger(down: true)) != nil)
        #expect(off.started.isEmpty)

        var settings = Self.settings()
        settings.general.bypassApps = [Self.game]
        let bypassed = Recorder()
        let engine = Self.makeEngine(bypassed, settings, front: Self.frontApp(Self.game))
        #expect(engine.handle(.otherMouseDown, Self.trigger(down: true)) != nil)
        #expect(bypassed.started.isEmpty)
    }

    // MARK: Whatever changes underneath it

    @Test func everyChangeOfSituationEndsIt() {
        let changes: [(reason: String, apply: (EventEngine) -> Void)] = [
            ("settings changed", { $0.update(Self.settings(AutoScroll(maxSpeed: 2000))) }),
            ("master switch off", { $0.update(Self.settings(enabled: false)) }),
            ("app in front changed", { $0.frontmostAppChanged() }),
            ("a mouse connected", { $0.devicesChanged(connected: [Self.mouse.id, "1234:5678"]) }),
            ("a mouse disconnected", { $0.devicesChanged(connected: []) }),
            ("button capture began", { $0.setCapturing(true) }),
            ("sleep or user switch", { $0.releaseAll() }),
            ("quit or access revoked", { $0.stop() }),
            ("Space or display change", { $0.cancelAutoScroll() }),
            ("tap paused by the system", { _ = $0.handle(.tapDisabledByTimeout, CGEvent(source: nil)!) }),
            ("tap disabled by input", { _ = $0.handle(.tapDisabledByUserInput, CGEvent(source: nil)!) }),
        ]
        for (reason, apply) in changes {
            let recorder = Recorder()
            let engine = Self.makeEngine(recorder)
            _ = engine.handle(.otherMouseDown, Self.trigger(down: true))
            #expect(recorder.running != nil, Comment(rawValue: reason))

            apply(engine)
            #expect(recorder.running == nil, Comment(rawValue: reason))
            #expect(recorder.cancels == 1, Comment(rawValue: reason))
            #expect(recorder.started.count == 1, Comment(rawValue: reason))
        }
    }

    @Test func changesWithNothingRunningLeaveTheScrollerAlone() {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder)
        engine.update(Self.settings())
        engine.frontmostAppChanged()
        engine.devicesChanged(connected: [])
        engine.setCapturing(true)
        engine.setCapturing(false)
        engine.releaseAll()
        engine.cancelAutoScroll()
        #expect(recorder.cancels == 0)
        #expect(recorder.started.isEmpty)
    }

    @Test func aProfileThatBelongsToAnAppEndsItWhenTheAppGoesAndDecidesWhatTheButtonDoesNext() {
        var settings = Self.settings()
        settings.profiles[0].mappings = []
        settings.profiles.append(Profile(
            name: "Notes", match: ProfileMatch(apps: [Self.notes]), inherits: nil,
            mappings: [Mapping(trigger: .button(3), action: .autoScroll(AutoScroll()))]
        ))
        let recorder = Recorder()
        let front = Self.frontApp(Self.notes)
        let engine = Self.makeEngine(recorder, settings, front: front)
        #expect(engine.handle(.otherMouseDown, Self.trigger(down: true)) == nil)
        #expect(recorder.running != nil)

        front.activate(Self.game)
        engine.frontmostAppChanged()
        #expect(recorder.running == nil)
        // The press was swallowed, so its release is too; after that the button belongs to the other profile.
        #expect(engine.handle(.otherMouseUp, Self.trigger(down: false)) == nil)
        #expect(engine.handle(.otherMouseDown, Self.trigger(down: true)) != nil)
        #expect(recorder.started.count == 1)
    }

    // MARK: Generated events and callbacks

    @Test func eventsWhiskerGeneratesAreNeverRemappedAndNeverEndIt() {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder, Self.settings(invertWheel: true))
        _ = engine.handle(.otherMouseDown, Self.trigger(down: true))

        // What the scroller posts carries the marker, and the tap hands it on as it is.
        let generated = Self.wheel(-3)
        generated.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.marker)
        #expect(engine.handle(.scrollWheel, generated) != nil)
        #expect(generated.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -3)
        let click = Self.click(.leftMouseDown)
        click.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.marker)
        #expect(engine.handle(.leftMouseDown, click) != nil)
        #expect(recorder.running != nil)
        #expect(recorder.cancels == 0)

        // A real turn of the wheel is remapped like any other, and ends it.
        let real = Self.wheel(-3)
        #expect(engine.handle(.scrollWheel, real) != nil)
        #expect(real.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 3)
        #expect(recorder.running == nil)
    }

    @Test func theAppIsToldOnTheMainQueueAndTheTapNeverWaitsForIt() async {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder)
        let reports = Reports()
        engine.onAutoScrollActive = { reports.add($0) }

        // With the main queue held up, a tap callback that waited for the UI would hang here.
        let held = DispatchSemaphore(value: 0)
        DispatchQueue.main.async { _ = held.wait(timeout: .now() + 5) }
        let finished = DispatchSemaphore(value: 0)
        let tap = Thread {
            _ = engine.handle(.otherMouseDown, Self.trigger(down: true))
            _ = engine.handle(.otherMouseUp, Self.trigger(down: false))
            _ = engine.handle(.leftMouseDown, Self.click(.leftMouseDown))
            finished.signal()
        }
        tap.start()
        #expect(finished.wait(timeout: .now() + 3) == .success)
        #expect(reports.values.isEmpty)
        held.signal()

        for _ in 0..<150 where reports.values.count < 2 { try? await Task.sleep(nanoseconds: 20_000_000) }
        #expect(reports.values == [true, false])
        #expect(reports.allOnMain)
    }
}
