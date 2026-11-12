import CoreGraphics
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Smooth scrolling in the event engine")
struct SmoothScrollEngineTests {
    static func makeSmoothEngine(_ recorder: EventEngineTests.Recorder, app: String? = "com.example.app", attribution: DeviceAttribution? = EventEngineTests.ball, configure: (inout WhiskerSettings) -> Void = { _ in }) -> EventEngine {
        var settings = WhiskerSettings()
        settings.profiles[0].scroll = ScrollSettings(smoothScrolling: true, smoothDuration: 150)
        configure(&settings)
        let engine = EventEngine(synthesizer: recorder, attribute: { _, _ in attribution }, frontmostApp: { app })
        engine.update(settings)
        return engine
    }

    static func wheel(_ lines: Int32, flags: CGEventFlags = []) -> CGEvent {
        let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: lines, wheel2: 0, wheel3: 0)!
        event.flags = flags
        return event
    }

    @Test func aNotchIsHandedToSmoothingAndTheOriginalIsDropped() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeSmoothEngine(recorder)
        #expect(engine.handle(.scrollWheel, Self.wheel(-2, flags: .maskShift)) == nil)
        let smooth = recorder.smooth
        #expect(smooth.count == 1)
        #expect(smooth[0].vertical == -20 && smooth[0].horizontal == 0 && smooth[0].duration == 150)
        #expect(smooth[0].context.flags & CGEventFlags.maskShift.rawValue != 0)
        #expect(smooth[0].context.device == EventEngineTests.ball.id && smooth[0].context.app == "com.example.app")
    }

    @Test func aRefusedAdmissionPassesTheEventThroughUnchanged() {
        let recorder = EventEngineTests.Recorder()
        recorder.acceptsSmoothing = false
        let engine = Self.makeSmoothEngine(recorder)
        let event = Self.wheel(-2)
        #expect(engine.handle(.scrollWheel, event) != nil)
        #expect(event.getIntegerValueField(.scrollWheelEventDeltaAxis1) == -2)
        #expect(recorder.smooth.isEmpty)
    }

    @Test func reduceMotionBypassesSmoothingLiveAndEndsWhatWasPending() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeSmoothEngine(recorder)
        _ = engine.handle(.scrollWheel, Self.wheel(-1))
        let before = recorder.smoothCancels
        engine.setReduceMotion(true)
        #expect(recorder.smoothCancels == before + 1)
        #expect(engine.handle(.scrollWheel, Self.wheel(-1)) != nil)
        #expect(recorder.smooth.count == 1)
        engine.setReduceMotion(false)
        #expect(engine.handle(.scrollWheel, Self.wheel(-1)) == nil)
        #expect(recorder.smooth.count == 2)
    }

    @Test func unsureAttributionAndContinuousInputBypassSmoothing() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeSmoothEngine(recorder, attribution: DeviceAttribution(id: "046d:c52b", exact: false))
        #expect(engine.handle(.scrollWheel, Self.wheel(-1)) != nil)
        let sure = Self.makeSmoothEngine(recorder)
        let pixels = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: -4, wheel2: 0, wheel3: 0)!
        #expect(sure.handle(.scrollWheel, pixels) != nil)
        #expect(recorder.smooth.isEmpty)
    }

    @Test func syntheticEventsAreNeverProcessedAgain() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeSmoothEngine(recorder)
        let event = Self.wheel(-1)
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.marker)
        #expect(engine.handle(.scrollWheel, event) != nil)
        #expect(recorder.smooth.isEmpty)
    }

    @Test func lifecycleChangesCancelPendingSmoothing() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeSmoothEngine(recorder)
        var cancels = recorder.smoothCancels
        func expectCancel(_ what: String, _ act: () -> Void) {
            act()
            #expect(recorder.smoothCancels > cancels, Comment(rawValue: what))
            cancels = recorder.smoothCancels
        }
        expectCancel("capture") { engine.setCapturing(true) }
        expectCancel("sleep or session change") { engine.releaseAll() }
        expectCancel("app change") { engine.frontmostAppChanged() }
        expectCancel("settings change") { engine.update(WhiskerSettings()) }
        expectCancel("teardown") { engine.stop() }
    }

    @Test func standingAsideForAnAppCancelsAndNothingIsSmoothedThere() {
        let recorder = EventEngineTests.Recorder()
        let front = EventEngineTests.Motion()
        _ = front
        final class Front: @unchecked Sendable { var app: String? = "com.example.app" }
        let box = Front()
        var settings = WhiskerSettings()
        settings.profiles[0].scroll = ScrollSettings(smoothScrolling: true)
        settings.general.bypassApps = ["com.example.game"]
        let engine = EventEngine(synthesizer: recorder, attribute: { _, _ in EventEngineTests.ball }, frontmostApp: { box.app })
        engine.update(settings)
        box.app = "com.example.game"
        let before = recorder.smoothCancels
        engine.frontmostAppChanged()
        #expect(recorder.smoothCancels > before)
        #expect(engine.handle(.scrollWheel, Self.wheel(-1)) != nil)
        #expect(recorder.smooth.isEmpty)
    }

    @Test func startingAHoldCancelsPendingSmoothing() {
        let recorder = EventEngineTests.Recorder()
        let engine = Self.makeSmoothEngine(recorder) {
            $0.profiles[0].mappings = [Mapping(trigger: .button(3), action: .holdToScroll(HoldScroll(axes: .free)))]
        }
        _ = engine.handle(.scrollWheel, Self.wheel(-1))
        let before = recorder.smoothCancels
        #expect(engine.handle(.otherMouseDown, EventEngineTests.holdPress()) == nil)
        #expect(recorder.smoothCancels > before)
        // While held, the wheel is not smoothed.
        _ = engine.handle(.scrollWheel, Self.wheel(-1))
        #expect(recorder.smooth.count == 1)
    }

    @Test func aMouseThatGoesAwayCancelsOnlyItsOwnSmoothing() {
        final class Connected: ActionPerforming, @unchecked Sendable {
            var seen: [Set<String>] = []
            func perform(_ action: Action, phase: ActionPhase, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {}
            func cancelPendingClicks() {}
            func cancelSequence(_ reason: SequenceStop) {}
            func releaseAll() {}
            func cancelSmoothScroll(unlessConnected connected: Set<String>) { seen.append(connected) }
        }
        let synth = Connected()
        let engine = EventEngine(synthesizer: synth, attribute: { _, _ in nil }, frontmostApp: { nil })
        engine.devicesChanged(connected: ["a"])
        #expect(synth.seen == [["a"]])
    }
}
