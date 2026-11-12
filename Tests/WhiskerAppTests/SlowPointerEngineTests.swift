import CoreGraphics
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Slow pointer engine")
@MainActor
struct SlowPointerEngineTests {
    @MainActor final class Rig {
        let engine: EventEngine
        var commands: [SlowPointerCommand] = []
        var onMain = true
        var settings = WhiskerSettings()

        init() {
            settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .slowPointer(factor: 0.5))]
            engine = EventEngine(
                synthesizer: EventEngineTests.Recorder(),
                attribute: { _, _ in DeviceAttribution(id: "046d:c52b", exact: true) },
                frontmostApp: { "com.example.front" }
            )
            engine.update(settings)
            engine.onSlowPointer = { [weak self] command in
                self?.commands.append(command)
                self?.onMain = Thread.isMainThread
            }
            engine.setSlowPointerDevices(["046d:c52b"])
        }

        func press() {
            #expect(engine.handle(.otherMouseDown, EventEngineTests.button3(down: true)) == nil)
        }

        func release() {
            #expect(engine.handle(.otherMouseUp, EventEngineTests.button3(down: false)) == nil)
        }
    }

    func drainMainQueue() async {
        await withCheckedContinuation { continuation in
            DispatchQueue.main.async { continuation.resume() }
        }
    }

    @Test func releaseBeforeQueuedBeginNeverAppliesSlowdown() async {
        let rig = Rig()
        rig.press()
        rig.release()
        #expect(rig.commands.isEmpty)
        await drainMainQueue()
        #expect(rig.commands.count == 1)
        #expect(rig.commands.last?.factors == [:])
        #expect(rig.onMain)
    }

    @Test func allLifecycleInterruptionsClearActiveAndQueuedStarts() async {
        for interruption in 0..<11 {
            for alreadyApplied in [false, true] {
                let rig = Rig()
                rig.press()
                if alreadyApplied {
                    await drainMainQueue()
                    #expect(rig.commands.last?.factors == ["046d:c52b": 0.5])
                }
                switch interruption {
                case 0: rig.engine.releaseAll() // Sleep and session switch.
                case 1: rig.engine.frontmostAppChanged()
                case 2:
                    rig.settings.general.enabled = false
                    rig.engine.update(rig.settings)
                case 3: rig.engine.devicesChanged(connected: [])
                case 4: _ = rig.engine.handle(.tapDisabledByTimeout, EventEngineTests.button3(down: false))
                case 5: _ = rig.engine.handle(.tapDisabledByUserInput, EventEngineTests.button3(down: false))
                case 6: rig.engine.stop()
                case 7: rig.engine.setCapturing(true)
                case 8: rig.engine.cancelSlowPointer()
                case 9:
                    rig.settings.general.setBypassed("com.example.front", true)
                    rig.engine.update(rig.settings)
                default: rig.engine.update(rig.settings) // A profile/settings edit.
                }
                await drainMainQueue()
                #expect(rig.commands.last?.factors == [:])
                if !alreadyApplied { #expect(rig.commands.allSatisfy { $0.factors.isEmpty }) }
                #expect(rig.onMain)
            }
        }
    }

    @Test func profileChangePreservesPhysicalReleaseAndPreventsDuplicateRestart() async {
        let rig = Rig()
        rig.press()
        rig.settings.profiles[0].mappings.removeAll()
        rig.engine.update(rig.settings)
        rig.press()
        rig.release()
        await drainMainQueue()
        #expect(rig.commands.allSatisfy { $0.factors.isEmpty })
        #expect(rig.engine.handle(.otherMouseUp, EventEngineTests.button3(down: false)) != nil)
    }
}
