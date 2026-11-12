import CoreGraphics
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Event engine")
struct EventEngineTests {
    /// Records what the engine asks for. A gate can hold a `.down` inside `perform` to widen race windows.
    final class Recorder: ActionPerforming, @unchecked Sendable {
        struct Call: Equatable {
            var action: Action
            var phase: ActionPhase
            var clickState: Int64
        }

        private let lock = NSLock()
        private var _calls: [Call] = []
        private var _releases = 0
        var gate: DispatchSemaphore?
        let enteredDown = DispatchSemaphore(value: 0)

        var calls: [Call] { lock.withLock { _calls } }
        var releases: Int { lock.withLock { _releases } }

        func perform(_ action: Action, phase: ActionPhase, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {
            if phase == .down, let gate {
                enteredDown.signal()
                _ = gate.wait(timeout: .now() + 2)
            }
            lock.withLock { _calls.append(Call(action: action, phase: phase, clickState: clickState)) }
        }

        func cancelPendingClicks() {}

        func releaseAll() {
            lock.withLock { _releases += 1 }
        }
    }

    static let remap = Action.click(button: 0, modifiers: [])

    static func makeEngine(_ recorder: Recorder) -> EventEngine {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: remap)]
        let engine = EventEngine(synthesizer: recorder, attribute: { _, _ in nil }, frontmostApp: { nil })
        engine.update(settings)
        return engine
    }

    static func button3(down: Bool, clickState: Int64 = 1) -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: down ? .otherMouseDown : .otherMouseUp, mouseCursorPosition: .zero, mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        return event
    }

    @Test func cleanupWaitsForAPressThatIsBeingPosted() {
        let recorder = Recorder()
        let gate = DispatchSemaphore(value: 0)
        recorder.gate = gate
        let engine = Self.makeEngine(recorder)

        let tap = Thread { _ = engine.handle(.otherMouseDown, Self.button3(down: true)) }
        tap.start()
        #expect(recorder.enteredDown.wait(timeout: .now() + 2) == .success)
        let cleanup = Thread { engine.releaseAll() }
        cleanup.start()
        Thread.sleep(forTimeInterval: 0.15)
        gate.signal()
        for _ in 0..<100 where recorder.calls.count < 2 {
            Thread.sleep(forTimeInterval: 0.02)
        }

        #expect(recorder.calls.map(\.phase) == [.down, .up])
    }

    @Test func stoppedEngineLetsPressesThrough() {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder)
        engine.stop()

        #expect(engine.handle(.otherMouseDown, Self.button3(down: true)) != nil)
        #expect(recorder.calls.isEmpty)
    }

    @Test func pausedTapReleasesHeldButtonsAndRepeats() {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder)
        #expect(engine.handle(.otherMouseDown, Self.button3(down: true)) == nil)

        let releasesBefore = recorder.releases
        let notice = CGEvent(source: nil)!
        _ = engine.handle(.tapDisabledByTimeout, notice)

        #expect(recorder.calls.map(\.phase) == [.down, .up])
        #expect(recorder.releases == releasesBefore + 1)
        // The real release afterwards isn't turned into a second synthetic one.
        #expect(engine.handle(.otherMouseUp, Self.button3(down: false)) != nil)
        #expect(recorder.calls.count == 2)
    }

    @Test func remappedClicksKeepTheClickCount() {
        let recorder = Recorder()
        let engine = Self.makeEngine(recorder)
        _ = engine.handle(.otherMouseDown, Self.button3(down: true, clickState: 2))
        _ = engine.handle(.otherMouseUp, Self.button3(down: false, clickState: 2))

        #expect(recorder.calls == [
            .init(action: Self.remap, phase: .down, clickState: 2),
            .init(action: Self.remap, phase: .up, clickState: 2),
        ])
    }
}

@Suite("Event engine application bypass")
struct EventEngineBypassTests {
    typealias Recorder = EventEngineTests.Recorder

    /// The app in front, switched the way the front-app monitor switches it.
    final class FrontApp: @unchecked Sendable {
        private let lock = NSLock()
        private var app = FrontmostApp()

        var bundleID: String? { lock.withLock { app.bundleID } }
        func activate(_ bundleID: String?) { lock.withLock { app.activated(bundleID) } }
    }

    static let game = "com.example.game"
    static let notes = "com.example.notes"
    static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)

    static func settings(
        action: Action = EventEngineTests.remap,
        bypassing: [String] = [game],
        enabled: Bool = true,
        invertWheel: Bool = false
    ) -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.general.enabled = enabled
        settings.general.bypassApps = bypassing
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: action)]
        if invertWheel { settings.devices[mouse.id] = DeviceSettings(wheel: WheelSettings(invertVertical: true)) }
        return settings
    }

    /// Starting while a listed app is in front stands aside once, so tests count releases relative to this.
    static func makeEngine(_ recorder: Recorder, front: FrontApp, _ settings: WhiskerSettings = settings()) -> EventEngine {
        let engine = EventEngine(synthesizer: recorder, attribute: { _, _ in mouse }, frontmostApp: { front.bundleID })
        engine.update(settings)
        return engine
    }

    static func press() -> CGEvent { EventEngineTests.button3(down: true) }
    static func release() -> CGEvent { EventEngineTests.button3(down: false) }

    static func drag() -> CGEvent {
        let event = CGEvent(mouseEventSource: nil, mouseType: .otherMouseDragged, mouseCursorPosition: .zero, mouseButton: .center)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: 3)
        return event
    }

    static func wheelNotch() -> CGEvent {
        CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 1, wheel1: 1, wheel2: 0, wheel3: 0)!
    }

    @Test func standingAsideEndsWhatWasHeldOnce() {
        let recorder = Recorder()
        let front = FrontApp()
        front.activate(Self.notes)
        let engine = Self.makeEngine(recorder, front: front)
        #expect(engine.handle(.otherMouseDown, Self.press()) == nil)

        front.activate(Self.game)
        engine.frontmostAppChanged()
        engine.frontmostAppChanged()
        #expect(recorder.calls.map(\.phase) == [.down, .up])

        // The button is still down: it keeps moving the pointer, but the app sees no drag and no release.
        let drag = Self.drag()
        #expect(engine.handle(.otherMouseDragged, drag) != nil)
        #expect(drag.type == .mouseMoved)
        #expect(engine.handle(.otherMouseUp, Self.release()) == nil)
        // The next press and release are the app's own.
        #expect(engine.handle(.otherMouseDown, Self.press()) != nil)
        #expect(engine.handle(.otherMouseUp, Self.release()) != nil)
        #expect(recorder.calls.map(\.phase) == [.down, .up])
    }

    @Test func aRepeatingShortcutStopsWhenWhiskerStandsAside() {
        let recorder = Recorder()
        let front = FrontApp()
        front.activate(Self.notes)
        let repeating = Action.shortcut(KeyShortcut(keyCode: 0x7C), repeatWhileHeld: true)
        let engine = Self.makeEngine(recorder, front: front, Self.settings(action: repeating))
        #expect(engine.handle(.otherMouseDown, Self.press()) == nil)
        let releasesBefore = recorder.releases

        front.activate(Self.game)
        engine.frontmostAppChanged()

        #expect(recorder.calls == [
            .init(action: repeating, phase: .down, clickState: 1),
            .init(action: repeating, phase: .up, clickState: 1),
        ])
        #expect(recorder.releases == releasesBefore + 1)
        #expect(engine.handle(.otherMouseUp, Self.release()) == nil)
        engine.frontmostAppChanged()
        #expect(recorder.calls.count == 2)
        #expect(recorder.releases == releasesBefore + 1)
    }

    @Test func leavingABypassedAppNeedsNoCleanUp() {
        let recorder = Recorder()
        let front = FrontApp()
        front.activate(Self.game)
        let engine = Self.makeEngine(recorder, front: front)
        #expect(engine.handle(.otherMouseDown, Self.press()) != nil)
        #expect(engine.handle(.otherMouseUp, Self.release()) != nil)
        let releasesBefore = recorder.releases

        front.activate(Self.notes)
        engine.frontmostAppChanged()

        #expect(recorder.calls.isEmpty)
        #expect(recorder.releases == releasesBefore)
        #expect(engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(recorder.calls.map(\.phase) == [.down, .up])
    }

    @Test func rapidFocusChangesNeverLeaveAPressStuckOrReleasedTwice() {
        let recorder = Recorder()
        let front = FrontApp()
        front.activate(Self.notes)
        let engine = Self.makeEngine(recorder, front: front)
        for _ in 0..<5 {
            #expect(engine.handle(.otherMouseDown, Self.press()) == nil)
            for app in [Self.game, Self.notes, Self.game] {
                front.activate(app)
                engine.frontmostAppChanged()
            }
            #expect(engine.handle(.otherMouseUp, Self.release()) == nil)
            front.activate(Self.notes)
            engine.frontmostAppChanged()
        }

        #expect(recorder.calls.map(\.phase) == Array(repeating: [ActionPhase.down, .up], count: 5).flatMap { $0 })
    }

    @Test func theWheelIsLeftAloneInABypassedApp() {
        let recorder = Recorder()
        let front = FrontApp()
        front.activate(Self.game)
        let engine = Self.makeEngine(recorder, front: front, Self.settings(invertWheel: true))

        let inTheGame = Self.wheelNotch()
        #expect(engine.handle(.scrollWheel, inTheGame) != nil)
        #expect(inTheGame.getIntegerValueField(.scrollWheelEventDeltaAxis1) == 1)

        front.activate(Self.notes)
        let inNotes = Self.wheelNotch()
        #expect(engine.handle(.scrollWheel, inNotes) != nil)
        #expect(inNotes.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -1)
    }

    @Test func sleepSessionChangesAndUnidentifiableAppsKeepTheBypassState() {
        for (app, bypassed) in [(Self.game, true), (Self.notes, false)] {
            let recorder = Recorder()
            let front = FrontApp()
            front.activate(app)
            let engine = Self.makeEngine(recorder, front: front)

            // Sleep and switching users let go of what is held; an app without an identity, or none, is no answer.
            engine.releaseAll()
            let releasesAfterSleep = recorder.releases
            for unknown in [nil, ""] {
                front.activate(unknown)
                engine.frontmostAppChanged()
            }

            #expect(recorder.releases == releasesAfterSleep)
            #expect((engine.handle(.otherMouseDown, Self.press()) != nil) == bypassed)
            #expect((engine.handle(.otherMouseUp, Self.release()) != nil) == bypassed)
            #expect(recorder.calls.map(\.phase) == (bypassed ? [] : [.down, .up]))
        }
    }

    @Test func editingTheListWhileAnAppIsInFront() {
        let recorder = Recorder()
        let front = FrontApp()
        front.activate(Self.game)
        let engine = Self.makeEngine(recorder, front: front, Self.settings(bypassing: []))
        #expect(engine.handle(.otherMouseDown, Self.press()) == nil)

        // Adding the app in front lets go of the held press, as if the app had just come to the front.
        engine.update(Self.settings(bypassing: [Self.game]))
        #expect(recorder.calls.map(\.phase) == [.down, .up])
        #expect(engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(engine.handle(.otherMouseDown, Self.press()) != nil)
        #expect(engine.handle(.otherMouseUp, Self.release()) != nil)

        // Taking it off brings the mapping back straight away.
        engine.update(Self.settings(bypassing: []))
        #expect(engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(recorder.calls.map(\.phase) == [.down, .up, .down, .up])
    }

    @Test func theMasterSwitchWinsOverTheList() {
        let recorder = Recorder()
        let front = FrontApp()
        for app in [Self.game, Self.notes] {
            front.activate(app)
            let engine = Self.makeEngine(recorder, front: front, Self.settings(enabled: false))
            #expect(engine.handle(.otherMouseDown, Self.press()) != nil)
            #expect(engine.handle(.otherMouseUp, Self.release()) != nil)
        }
        #expect(recorder.calls.isEmpty)

        // Turned back on while a listed app is in front, Whisker still leaves that app alone.
        front.activate(Self.game)
        let engine = Self.makeEngine(recorder, front: front, Self.settings(enabled: false))
        engine.update(Self.settings())
        #expect(engine.handle(.otherMouseDown, Self.press()) != nil)
        #expect(engine.handle(.otherMouseUp, Self.release()) != nil)
        front.activate(Self.notes)
        #expect(engine.handle(.otherMouseDown, Self.press()) == nil)
        #expect(engine.handle(.otherMouseUp, Self.release()) == nil)
        #expect(recorder.calls.map(\.phase) == [.down, .up])
    }
}
