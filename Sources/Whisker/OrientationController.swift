import AppKit
import Foundation
import WhiskerCore

/// What the orientation controller needs of the event engine.
protocol OrientationEngine: AnyObject {
    func setOrientationPreview(_ preview: PointerOrientationPreview?)
    func setOrientationCalibration(_ deviceID: String?)
    func orientationCalibrationStrokes() -> [PointerVector]
}

extension EventEngine: OrientationEngine {}

/// Orientation for the Pointer pane: quarter turns, a typed angle, Reset and the guided calibration.
///
/// A non-zero angle is only ever tried live first and goes back by itself unless kept within
/// `PointerMath.confirmationTimeout`, like a big speed increase. The tried angle lives in memory and in the event
/// tap only; settings receive an angle once it is kept, so quitting or crashing mid-preview leaves the confirmed one.
@MainActor
final class OrientationController: ObservableObject {
    enum Calibration: Equatable {
        case idle
        /// Recording forward strokes from one device; `strokes` is how many have ended so far.
        case recording(deviceID: String, strokes: Int)
        /// The strokes were assessed; an accepted assessment is being previewed (or was, until it ran out).
        case result(deviceID: String, assessment: PointerCalibration.Assessment)
    }

    /// Strokes the guide asks for. The assessment needs at least three.
    static let suggestedStrokes = 4

    @Published private(set) var preview: PointerOrientationPreview?
    @Published private(set) var calibration: Calibration = .idle
    /// Whether orientation now needs device movement to be attributed changed (a preview or calibration began or ended).
    var onNeedsMotionChange: (() -> Void)?

    private var trial = PointerOrientationTrial()
    private let store: PointerSettingsSource
    private let engine: any OrientationEngine
    private let timeout: TimeInterval
    private let now: () -> Date
    private var revertTimer: Timer?
    private var pollTimer: Timer?

    init(
        store: PointerSettingsSource, engine: any OrientationEngine,
        timeout: TimeInterval = PointerMath.confirmationTimeout, now: @escaping () -> Date = Date.init
    ) {
        self.store = store
        self.engine = engine
        self.timeout = timeout
        self.now = now
    }

    func confirmedAngle(on deviceID: String) -> Double {
        PointerOrientationMath.normalisedDegrees(store.settings.devices[deviceID]?.rotationDegrees ?? 0) ?? 0
    }

    /// The angle in use for the device right now: a preview's when one is running, otherwise the confirmed one.
    func displayedAngle(on deviceID: String) -> Double {
        if let preview, preview.deviceID == deviceID { return preview.proposed }
        return confirmedAngle(on: deviceID)
    }

    /// Whether device movement must be attributed for orientation under `settings`.
    func needsMotionTracking(_ settings: WhiskerSettings) -> Bool {
        if preview != nil { return true }
        if case .recording = calibration { return true }
        return !PointerOrientationMath.effectiveAngles(devices: settings.devices, enabled: settings.general.enabled).isEmpty
    }

    // MARK: Preview

    /// Asks for an angle. Zero (Reset) is saved at once; any other angle is previewed and has to be kept.
    @discardableResult
    func propose(_ degrees: Double, on deviceID: String, name: String) -> PointerOrientationTrial.Outcome {
        let outcome = trial.propose(degrees, on: deviceID, confirmed: confirmedAngle(on: deviceID), now: now(), timeout: timeout)
        switch outcome {
        case .previewing(let next):
            startRevertTimer()
            publish(next)
            Log.pointer.info("Previewing a \(next.proposed, privacy: .public)° orientation for \(deviceID, privacy: .public)")
        case .commit(let angle):
            stopRevertTimer()
            save(angle, on: deviceID, name: name)
            publish(nil)
        case .unchanged:
            stopRevertTimer()
            publish(nil)
        case .rejected:
            NSSound.beep()
        }
        return outcome
    }

    /// Keeps the angle being previewed. Too late, and it has already gone back.
    func confirm(name: String? = nil) {
        stopRevertTimer()
        let deviceID = trial.preview?.deviceID
        if let kept = trial.confirm(now: now()) {
            // Saved before the preview is dropped, so the angle never lapses in between.
            save(kept.degrees, on: kept.deviceID, name: name ?? store.settings.devices[kept.deviceID]?.name ?? "")
            Log.pointer.info("Orientation kept for \(kept.deviceID, privacy: .public)")
        } else if let deviceID {
            Log.pointer.info("Orientation preview ran out before it was kept; reverting \(deviceID, privacy: .public)")
        }
        publish(nil)
        if case .result = calibration { calibration = .idle }
    }

    /// Goes back to the confirmed angle. Also what the timeout and every interruption do.
    func revert() {
        stopRevertTimer()
        guard let dropped = trial.cancel() else { return }
        Log.pointer.info("Orientation preview not kept; reverting \(dropped.deviceID, privacy: .public)")
        publish(nil)
    }

    /// Called by the timer; also callable directly, so tests don't need to wait.
    func expireIfDue() {
        guard trial.expire(now: now()) != nil else { return }
        stopRevertTimer()
        Log.pointer.info("Orientation preview timed out; reverting")
        publish(nil)
    }

    /// The system paused the orientation tap, Whisker is going to sleep, or the settings window closed.
    func interrupt() {
        revert()
        stopCalibrationRecording()
        if calibration != .idle { calibration = .idle }
    }

    /// A preview ends when its device goes away.
    func devicesChanged(connected: Set<String>) {
        let confirmed = store.settings.devices.mapValues(\.rotationDegrees)
        if trial.reconcile(connected: connected, confirmed: confirmed) != nil {
            stopRevertTimer()
            publish(nil)
        }
        switch calibration {
        case .recording(let id, _), .result(let id, _):
            if !connected.contains(id) { interrupt() }
        case .idle:
            break
        }
    }

    /// A preview ends when Whisker or its device is switched off, or its confirmed angle changed underneath
    /// (an import or reset). `settings` are the new ones, which the store may not hold yet.
    func settingsChanged(_ settings: WhiskerSettings) {
        guard let preview else { return }
        let device = settings.devices[preview.deviceID]
        let saved = PointerOrientationMath.normalisedDegrees(device?.rotationDegrees ?? 0) ?? 0
        if !settings.general.enabled || device?.enabled == false || saved != preview.previous { revert() }
    }

    // MARK: Calibration

    /// Starts recording forward strokes from one device. Any preview goes back first, so strokes are judged
    /// against the confirmed angle the user can see.
    func startCalibration(on deviceID: String) {
        revert()
        stopCalibrationRecording()
        calibration = .recording(deviceID: deviceID, strokes: 0)
        engine.setOrientationCalibration(deviceID)
        pollTimer = Timer.scheduledTimer(withTimeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refreshStrokeCount() }
        }
        onNeedsMotionChange?()
    }

    func refreshStrokeCount() {
        guard case .recording(let id, let count) = calibration else { return }
        let strokes = engine.orientationCalibrationStrokes().count
        if strokes != count { calibration = .recording(deviceID: id, strokes: strokes) }
    }

    /// Stops recording, assesses the strokes and previews a proposed angle when they agree.
    func finishCalibration(name: String) {
        guard case .recording(let id, _) = calibration else { return }
        let strokes = engine.orientationCalibrationStrokes()
        stopCalibrationRecording()
        var assessment = PointerCalibration.assess(strokes: strokes)
        // Whole degrees: the calibration is not more precise than that, and the angle is shown as typed.
        if let proposed = assessment.correctionDegrees {
            assessment = PointerCalibration.Assessment(
                correctionDegrees: PointerOrientationMath.normalisedDegrees(proposed.rounded()),
                confidence: assessment.confidence, rejection: nil
            )
        }
        calibration = .result(deviceID: id, assessment: assessment)
        if let proposed = assessment.correctionDegrees { propose(proposed, on: id, name: name) }
        onNeedsMotionChange?()
    }

    /// Keeps the calibrated angle, or previews it again when the preview already ran out.
    func acceptCalibration(name: String) {
        guard case let .result(id, assessment) = calibration, let proposed = assessment.correctionDegrees else { return }
        if let preview, preview.deviceID == id, preview.proposed == proposed {
            confirm(name: name)
        } else if case .previewing = propose(proposed, on: id, name: name) {
            return
        } else {
            // Already the confirmed angle (or zero, saved at once): nothing is left to keep.
            calibration = .idle
        }
    }

    func retryCalibration() {
        guard case .result(let id, _) = calibration else { return }
        startCalibration(on: id)
    }

    func cancelCalibration() {
        let wasResult: Bool
        if case .result = calibration { wasResult = true } else { wasResult = false }
        stopCalibrationRecording()
        calibration = .idle
        if wasResult { revert() }
        onNeedsMotionChange?()
    }

    // MARK: Private

    private func stopCalibrationRecording() {
        pollTimer?.invalidate()
        pollTimer = nil
        if case .recording = calibration { engine.setOrientationCalibration(nil) }
    }

    private func save(_ degrees: Double, on deviceID: String, name: String) {
        var device = store.settings.devices[deviceID] ?? DeviceSettings(name: name)
        if device.name.isEmpty { device.name = name }
        device.rotationDegrees = degrees
        store.settings.devices[deviceID] = device
        store.saveNow()
    }

    private func publish(_ next: PointerOrientationPreview?) {
        let changed = (preview == nil) != (next == nil)
        preview = next
        engine.setOrientationPreview(next)
        if changed { onNeedsMotionChange?() }
    }

    private func startRevertTimer() {
        revertTimer?.invalidate()
        revertTimer = Timer.scheduledTimer(withTimeInterval: timeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.expireIfDue() }
        }
    }

    private func stopRevertTimer() {
        revertTimer?.invalidate()
        revertTimer = nil
    }
}
