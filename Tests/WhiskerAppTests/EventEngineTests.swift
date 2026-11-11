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
