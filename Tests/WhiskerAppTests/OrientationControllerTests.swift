import Foundation
import Testing
@testable import Whisker
@testable import WhiskerCore

@Suite("Orientation controller")
@MainActor
struct OrientationControllerTests {
    final class FakeEngine: OrientationEngine {
        var previews: [PointerOrientationPreview?] = []
        var calibrating: [String?] = []
        var strokes: [PointerVector] = []

        func setOrientationPreview(_ preview: PointerOrientationPreview?) { previews.append(preview) }
        func setOrientationCalibration(_ deviceID: String?) { calibrating.append(deviceID) }
        func orientationCalibrationStrokes() -> [PointerVector] { strokes }
    }

    @MainActor final class Rig {
        let engine = FakeEngine()
        let store: PointerSettingsSource
        var clock = Date(timeIntervalSinceReferenceDate: 1000)
        lazy var controller = OrientationController(store: store, engine: engine, timeout: 5, now: { [unowned self] in self.clock })

        init(store: PointerSettingsSource? = nil) {
            self.store = store ?? DetachedSettings(WhiskerSettings())
        }

        var saved: Double? { store.settings.devices["m"]?.rotationDegrees }
    }

    @Test func previewIsLiveButNotSavedUntilKept() {
        let rig = Rig()
        rig.controller.propose(90, on: "m", name: "Mouse")
        #expect(rig.controller.displayedAngle(on: "m") == 90)
        #expect(rig.controller.confirmedAngle(on: "m") == 0)
        #expect(rig.engine.previews.last??.proposed == 90)
        #expect(rig.saved == nil)
        #expect(rig.controller.needsMotionTracking(rig.store.settings))

        rig.clock.addTimeInterval(4)
        rig.controller.confirm(name: "Mouse")
        #expect(rig.saved == 90)
        #expect(rig.store.settings.devices["m"]?.name == "Mouse")
        #expect(rig.controller.preview == nil)
        #expect(rig.engine.previews.last == .some(nil))
        #expect(rig.controller.needsMotionTracking(rig.store.settings))
    }

    @Test func previewRevertsByItselfAfterTheTimeout() {
        let rig = Rig()
        rig.controller.propose(-45, on: "m", name: "Mouse")
        rig.clock.addTimeInterval(4.9)
        rig.controller.expireIfDue()
        #expect(rig.controller.preview != nil)
        rig.clock.addTimeInterval(0.1)
        rig.controller.expireIfDue()
        #expect(rig.controller.preview == nil)
        #expect(rig.controller.displayedAngle(on: "m") == 0)
        #expect(rig.engine.previews.last == .some(nil))
        rig.controller.confirm()
        #expect(rig.saved == nil)
        #expect(!rig.controller.needsMotionTracking(rig.store.settings))
    }

    @Test func confirmingTooLateKeepsTheOldAngle() {
        let rig = Rig()
        rig.controller.propose(180, on: "m", name: "Mouse")
        rig.clock.addTimeInterval(6)
        rig.controller.confirm()
        #expect(rig.saved == nil)
        #expect(rig.controller.preview == nil)
    }

    @Test func resetSavesAtOnceAndRevertRestores() {
        let rig = Rig()
        rig.store.settings.devices["m"] = DeviceSettings(name: "Mouse", rotationDegrees: 90)
        rig.controller.propose(180, on: "m", name: "Mouse")
        rig.controller.revert()
        #expect(rig.controller.displayedAngle(on: "m") == 90)
        #expect(rig.saved == 90)
        rig.controller.propose(0, on: "m", name: "Mouse")
        #expect(rig.saved == 0)
        #expect(rig.controller.preview == nil)
    }

    @Test func interruptionsRollBack() {
        let rig = Rig()
        rig.store.settings.devices["m"] = DeviceSettings(name: "Mouse")
        rig.controller.propose(90, on: "m", name: "Mouse")
        rig.controller.interrupt()
        #expect(rig.controller.preview == nil)

        rig.controller.propose(90, on: "m", name: "Mouse")
        rig.controller.devicesChanged(connected: ["m"])
        #expect(rig.controller.preview != nil)
        rig.controller.devicesChanged(connected: [])
        #expect(rig.controller.preview == nil)

        rig.controller.propose(90, on: "m", name: "Mouse")
        var off = rig.store.settings
        off.general.enabled = false
        rig.controller.settingsChanged(off)
        #expect(rig.controller.preview == nil)

        rig.controller.propose(90, on: "m", name: "Mouse")
        var imported = rig.store.settings
        imported.devices["m"]?.rotationDegrees = 30
        rig.controller.settingsChanged(imported)
        #expect(rig.controller.preview == nil)
        #expect(rig.saved == 0)
    }

    @Test func calibrationPreviewsAWholeDegreeAngleAndAcceptKeepsIt() {
        let rig = Rig()
        rig.controller.startCalibration(on: "m")
        #expect(rig.engine.calibrating == ["m"])
        #expect(rig.controller.needsMotionTracking(rig.store.settings))
        rig.engine.strokes = Array(repeating: PointerVector(dx: 50, dy: 0.4), count: 3)
        rig.controller.refreshStrokeCount()
        #expect(rig.controller.calibration == .recording(deviceID: "m", strokes: 3))

        rig.controller.finishCalibration(name: "Mouse")
        #expect(rig.engine.calibrating == ["m", nil])
        let proposed = rig.controller.preview?.proposed
        #expect(proposed != nil && proposed == proposed?.rounded())
        #expect(rig.saved == nil)
        rig.controller.acceptCalibration(name: "Mouse")
        #expect(rig.saved == proposed)
        #expect(rig.controller.calibration == .idle)
    }

    @Test func cancellingACalibrationResultRevertsItsPreview() {
        let rig = Rig()
        rig.controller.startCalibration(on: "m")
        rig.engine.strokes = Array(repeating: PointerVector(dx: 0, dy: 50), count: 3)
        rig.controller.finishCalibration(name: "Mouse")
        #expect(rig.controller.preview != nil)
        rig.controller.cancelCalibration()
        #expect(rig.controller.preview == nil)
        #expect(rig.controller.calibration == .idle)
        #expect(rig.saved == nil)
    }

    @Test func tooFewStrokesProposeNothing() {
        let rig = Rig()
        rig.controller.startCalibration(on: "m")
        rig.engine.strokes = [PointerVector(dx: 0, dy: 50)]
        rig.controller.finishCalibration(name: "Mouse")
        #expect(rig.controller.preview == nil)
        guard case .result(_, let assessment) = rig.controller.calibration else {
            Issue.record("expected a result")
            return
        }
        #expect(assessment.correctionDegrees == nil)
    }

    @Test func quittingMidPreviewLeavesTheConfirmedAngleOnDisk() throws {
        let directory = try SettingsStoreTests.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        store.settings.devices["046d:c52b"] = DeviceSettings(name: "Mouse", rotationDegrees: 90)
        store.saveNow()

        let rig = Rig(store: store)
        rig.controller.propose(180, on: "046d:c52b", name: "Mouse")
        #expect(rig.controller.displayedAngle(on: "046d:c52b") == -180)
        #expect(SettingsStore(directory: directory).settings.devices["046d:c52b"]?.rotationDegrees == 90)

        rig.controller.confirm()
        #expect(SettingsStore(directory: directory).settings.devices["046d:c52b"]?.rotationDegrees == -180)
    }
}
