import Foundation
import Testing
@testable import WhiskerCore

@Suite("Pointer orientation foundation")
struct PointerOrientationTests {
    @Test(arguments: [
        (0.0, 0.0), (-0.0, 0.0), (360.0, 0.0), (-720.0, 0.0),
        (90.0, 90.0), (450.0, 90.0), (-450.0, -90.0),
        (180.0, -180.0), (-180.0, -180.0), (540.0, -180.0),
        (-540.0, -180.0), (721.25, 1.25), (-721.25, -1.25),
    ])
    func equivalentAnglesHaveOneRepresentation(input: Double, expected: Double) throws {
        let result = try #require(PointerOrientationMath.normalisedDegrees(input))
        #expect(result == expected)
        if result == 0 { #expect(result.sign == .plus) }
    }

    @Test(arguments: [Double.nan, .infinity, -.infinity])
    func nonFiniteAnglesAreRejected(angle: Double) {
        #expect(PointerOrientationMath.normalisedDegrees(angle) == nil)
        #expect(PointerRotation(degrees: angle) == nil)
        #expect(PointerRotationAccumulator(degrees: angle) == nil)
    }

    @Test(arguments: [Double.greatestFiniteMagnitude, -Double.greatestFiniteMagnitude])
    func hugeFiniteAnglesNormaliseWithoutOverflow(angle: Double) throws {
        let result = try #require(PointerOrientationMath.normalisedDegrees(angle))
        #expect((-180..<180).contains(result))
        #expect(PointerOrientationMath.normalisedDegrees(result) == result)
    }

    @Test(arguments: [
        (0.0, 7.0, -3.0), (90.0, 3.0, 7.0), (-90.0, -3.0, -7.0),
        (180.0, -7.0, 3.0), (270.0, -3.0, -7.0), (360.0, 7.0, -3.0),
    ])
    func quarterTurnsAreExact(angle: Double, x: Double, y: Double) throws {
        let rotation = try #require(PointerRotation(degrees: angle))
        #expect(rotation.apply(to: PointerVector(dx: 7, dy: -3)) == PointerVector(dx: x, dy: y))
        var accumulator = try #require(PointerRotationAccumulator(degrees: angle))
        for _ in 0..<100 {
            #expect(accumulator.apply(PointerMotion(dx: 7, dy: -3)) == PointerMotion(dx: Int(x), dy: Int(y)))
        }
    }

    @Test(arguments: [-179.25, -37.5, 15.0, 45.0, 123.45])
    func arbitraryAnglesPreserveDistanceAndInvert(angle: Double) throws {
        let rotation = try #require(PointerRotation(degrees: angle))
        let inverse = try #require(PointerRotation(degrees: -angle))
        let input = PointerVector(dx: 16.25, dy: -7.5)
        let output = try #require(rotation.apply(to: input))
        #expect(abs(hypot(output.dx, output.dy) - hypot(input.dx, input.dy)) < 1e-12)
        let restored = try #require(inverse.apply(to: output))
        #expect(abs(restored.dx - input.dx) < 1e-12)
        #expect(abs(restored.dy - input.dy) < 1e-12)
    }

    @Test func positiveAnglesTurnClockwiseInScreenCoordinates() throws {
        let rotation = try #require(PointerRotation(degrees: 30))
        let output = try #require(rotation.apply(to: PointerVector(dx: 2, dy: 0)))
        #expect(abs(output.dx - sqrt(3)) < 1e-12)
        #expect(abs(output.dy - 1) < 1e-12)
    }

    @Test func invalidVectorsAndOverflowAreRejected() throws {
        let rotation = try #require(PointerRotation(degrees: 45))
        for vector in [
            PointerVector(dx: .nan, dy: 0), PointerVector(dx: 0, dy: .infinity),
            PointerVector(dx: -.infinity, dy: 1),
            PointerVector(dx: .greatestFiniteMagnitude, dy: .greatestFiniteMagnitude),
        ] {
            #expect(rotation.apply(to: vector) == nil)
        }
    }

    @Test(arguments: [-37.5, 30.0, 45.0, 123.0])
    func fractionalCountsSurviveLongRunsAndReversals(angle: Double) throws {
        let rotation = try #require(PointerRotation(degrees: angle))
        var accumulator = try #require(PointerRotationAccumulator(degrees: angle))
        var totalX = 0, totalY = 0
        var exactX = 0.0, exactY = 0.0
        let movements = Array(repeating: PointerMotion(dx: 1, dy: -2), count: 1000)
            + Array(repeating: PointerMotion(dx: -1, dy: 2), count: 1000)
        for motion in movements {
            let exact = try #require(rotation.apply(to: PointerVector(dx: Double(motion.dx), dy: Double(motion.dy))))
            let applied = accumulator.apply(motion)
            let actual = try #require(applied)
            exactX += exact.dx
            exactY += exact.dy
            totalX += actual.dx
            totalY += actual.dy
            #expect(abs(Double(totalX) - exactX) <= 0.500_001)
            #expect(abs(Double(totalY) - exactY) <= 0.500_001)
        }
        #expect(totalX == 0)
        #expect(totalY == 0)
    }

    @Test func resetAndNewDeviceStateDoNotLeakFractions() throws {
        var first = try #require(PointerRotationAccumulator(degrees: 45))
        var other = try #require(PointerRotationAccumulator(degrees: 45))
        let motion = PointerMotion(dx: 1, dy: 0)
        let initial = first.apply(motion)
        #expect(first.apply(PointerMotion(dx: 0, dy: 0)) == PointerMotion(dx: 0, dy: 0))
        #expect(first.apply(motion) != initial)
        #expect(other.apply(motion) == initial)
        first.reset()
        #expect(first.apply(motion) == initial)
    }

    @Test func halfCountResidualDoesNotMoveAStationaryPointer() throws {
        let angle = 30.0.nextUp
        let rotation = try #require(PointerRotation(degrees: angle))
        #expect(rotation.apply(to: PointerVector(dx: 1, dy: 0))?.dy == 0.5)
        var accumulator = try #require(PointerRotationAccumulator(degrees: angle))
        _ = accumulator.apply(PointerMotion(dx: 1, dy: 0))
        for _ in 0..<20 {
            #expect(accumulator.apply(PointerMotion(dx: 0, dy: 0)) == PointerMotion(dx: 0, dy: 0))
        }
    }

    @Test func unrepresentableMotionFailsOpenAndClearsBothResiduals() throws {
        var accumulator = try #require(PointerRotationAccumulator(degrees: 45))
        let motion = PointerMotion(dx: 1, dy: 0)
        let initial = accumulator.apply(motion)
        #expect(accumulator.apply(PointerMotion(dx: Int.max, dy: 0)) == nil)
        #expect(accumulator.apply(motion) == initial)
        var halfTurn = try #require(PointerRotationAccumulator(degrees: 180))
        #expect(halfTurn.apply(PointerMotion(dx: Int.min, dy: 0)) == nil)
        var zero = try #require(PointerRotationAccumulator(degrees: 0))
        #expect(zero.apply(PointerMotion(dx: Int.max, dy: Int.min)) == PointerMotion(dx: Int.max, dy: Int.min))
    }

    @Test(arguments: [
        (0.0, -40.0, 0.0), (40.0, 0.0, -90.0),
        (0.0, 40.0, -180.0), (-40.0, 0.0, 90.0),
        (40.0, -40.0, -45.0),
    ])
    func calibrationProposesCorrectionTowardsScreenUp(x: Double, y: Double, expected: Double) throws {
        let stroke = PointerVector(dx: x, dy: y)
        let assessment = PointerCalibration.assess(strokes: [stroke, stroke, stroke])
        let correction = try #require(assessment.correctionDegrees)
        #expect(abs(correction - expected) < 1e-12)
        #expect(abs(assessment.confidence - 1) < 1e-12)
        #expect(assessment.rejection == nil)
        let rotation = try #require(PointerRotation(degrees: correction))
        let corrected = try #require(rotation.apply(to: stroke))
        #expect(abs(corrected.dx) < 1e-12)
        #expect(corrected.dy < 0)
    }

    @Test func calibrationHandlesTheAngleBoundaryAndSmallScatter() throws {
        let assessment = PointerCalibration.assess(strokes: [
            PointerVector(dx: -100, dy: -1), PointerVector(dx: -100, dy: 1), PointerVector(dx: -100, dy: 0),
        ])
        #expect(abs(try #require(assessment.correctionDegrees) - 90) < 1e-12)
        #expect(assessment.confidence > 0.99)
        #expect(assessment.confidence < 1)
    }

    @Test func calibrationRefusesShortOrMissingStrokes() {
        let forward = PointerVector(dx: 0, dy: -100)
        for strokes in [[], [forward], [forward, forward]] {
            let assessment = PointerCalibration.assess(strokes: strokes)
            #expect(assessment.rejection == .tooFewStrokes)
            #expect(assessment.correctionDegrees == nil)
        }
        for short in [PointerVector(dx: 0, dy: 0), PointerVector(dx: 0, dy: -19.9)] {
            let assessment = PointerCalibration.assess(strokes: [forward, forward, short])
            #expect(assessment.rejection == .insufficientMovement)
            #expect(assessment.correctionDegrees == nil)
        }
    }

    @Test func calibrationRejectsInvalidMovement() {
        for invalid in [
            PointerVector(dx: .nan, dy: 0), PointerVector(dx: 0, dy: .infinity),
            PointerVector(dx: .greatestFiniteMagnitude, dy: .greatestFiniteMagnitude),
        ] {
            let assessment = PointerCalibration.assess(strokes: [invalid, invalid, invalid])
            #expect(assessment.rejection == .invalidMovement)
            #expect(assessment.correctionDegrees == nil)
        }
    }

    @Test func confidenceDetectsOppositionEvenWithOneLongStroke() {
        let assessment = PointerCalibration.assess(strokes: [
            PointerVector(dx: 0, dy: -1_000_000),
            PointerVector(dx: 0, dy: 100), PointerVector(dx: 0, dy: 100),
        ])
        #expect(assessment.rejection == .inconsistentDirections)
        #expect(assessment.correctionDegrees == nil)
        #expect(abs(assessment.confidence - 1.0 / 3) < 1e-12)
        let opposed = PointerCalibration.assess(strokes: [
            PointerVector(dx: 100, dy: 0), PointerVector(dx: -100, dy: 0),
            PointerVector(dx: 0, dy: 100), PointerVector(dx: 0, dy: -100),
        ])
        #expect(opposed.confidence == 0)
        #expect(opposed.correctionDegrees == nil)
    }
}

@Suite("Pointer orientation routing")
struct PointerOrientationRoutingTests {
    static let screen = PointerRect(x: 0, y: 0, width: 1000, height: 1000)
    static let mouse = DeviceAttribution(id: "mouse", exact: true)

    static func router(_ angles: [String: Double] = ["mouse": 90]) -> PointerOrientationRouter {
        var router = PointerOrientationRouter()
        router.setAngles(angles)
        router.setDisplays([screen])
        return router
    }

    @Test func clampKeepsThePointerOnTheNearestDisplay() {
        let displays = [Self.screen, PointerRect(x: 1000, y: 0, width: 500, height: 400)]
        #expect(PointerOrientationMath.clamp(PointerPoint(x: 1200, y: 300), to: displays) == PointerPoint(x: 1200, y: 300))
        #expect(PointerOrientationMath.clamp(PointerPoint(x: -5, y: 2000), to: displays) == PointerPoint(x: 0, y: 999))
        #expect(PointerOrientationMath.clamp(PointerPoint(x: 1600, y: 500), to: displays) == PointerPoint(x: 1499, y: 399))
        #expect(PointerOrientationMath.clamp(PointerPoint(x: -5, y: -5), to: []) == PointerPoint(x: -5, y: -5))
    }

    @Test func effectiveAnglesHonourEnabledDevicesAndPreview() {
        let devices = [
            "a": DeviceSettings(rotationDegrees: 90),
            "b": DeviceSettings(enabled: false, rotationDegrees: 45),
            "c": DeviceSettings(rotationDegrees: 360),
        ]
        #expect(PointerOrientationMath.effectiveAngles(devices: devices, enabled: true) == ["a": 90])
        #expect(PointerOrientationMath.effectiveAngles(devices: devices, enabled: false).isEmpty)
        let preview = PointerOrientationPreview(deviceID: "c", previous: 0, proposed: -30, deadline: .distantFuture)
        #expect(PointerOrientationMath.effectiveAngles(devices: devices, enabled: true, preview: preview) == ["a": 90, "c": -30])
        let back = PointerOrientationPreview(deviceID: "a", previous: 90, proposed: 0, deadline: .distantFuture)
        #expect(PointerOrientationMath.effectiveAngles(devices: devices, enabled: true, preview: back).isEmpty)
        let disabled = PointerOrientationPreview(deviceID: "b", previous: 45, proposed: 10, deadline: .distantFuture)
        #expect(PointerOrientationMath.effectiveAngles(devices: devices, enabled: true, preview: disabled) == ["a": 90])
    }

    @Test func rotatesAttributedMovementAndCarriesPosition() {
        var router = Self.router()
        #expect(router.isActive)
        let first = router.process(
            device: Self.mouse, delta: PointerMotion(dx: 10, dy: 0), precise: PointerVector(dx: 10, dy: 0),
            location: PointerPoint(x: 510, y: 500), at: 1
        )
        #expect(first == .rewrite(delta: PointerMotion(dx: 0, dy: 10), location: PointerPoint(x: 500, y: 510)))
        // The system reports where the unrotated movement would have put the pointer; the written position wins.
        let second = router.process(
            device: Self.mouse, delta: PointerMotion(dx: 10, dy: 0), precise: PointerVector(dx: 10, dy: 0),
            location: PointerPoint(x: 510, y: 510), at: 1.05
        )
        #expect(second == .rewrite(delta: PointerMotion(dx: 0, dy: 10), location: PointerPoint(x: 500, y: 520)))
        // After a pause the event's own position is trusted again.
        let later = router.process(
            device: Self.mouse, delta: PointerMotion(dx: 10, dy: 0), precise: PointerVector(dx: 10, dy: 0),
            location: PointerPoint(x: 700, y: 700), at: 2
        )
        #expect(later == .rewrite(delta: PointerMotion(dx: 0, dy: 10), location: PointerPoint(x: 690, y: 710)))
    }

    @Test func rotatedPointerStaysOnScreen() {
        var router = Self.router()
        let decision = router.process(
            device: Self.mouse, delta: PointerMotion(dx: 50, dy: 0), precise: PointerVector(dx: 50, dy: 0),
            location: PointerPoint(x: 550, y: 990), at: 1
        )
        #expect(decision == .rewrite(delta: PointerMotion(dx: 0, dy: 50), location: PointerPoint(x: 500, y: 999)))
    }

    @Test(arguments: [
        nil as DeviceAttribution?,
        DeviceAttribution(id: "mouse", exact: false),
        DeviceAttribution(id: "mouse", exact: true, isExcluded: true),
        DeviceAttribution(id: "other", exact: true),
    ])
    func unattributedOrUnknownMovementPassesThrough(device: DeviceAttribution?) {
        var router = Self.router()
        let decision = router.process(
            device: device, delta: PointerMotion(dx: 3, dy: 1), precise: PointerVector(dx: 3, dy: 1),
            location: PointerPoint(x: 100, y: 100), at: 1
        )
        #expect(decision == .passThrough)
    }

    @Test func failsOpenWithoutDisplaysOrWithInvalidNumbers() {
        var router = PointerOrientationRouter()
        router.setAngles(["mouse": 90])
        #expect(!router.isActive)
        #expect(router.process(
            device: Self.mouse, delta: PointerMotion(dx: 3, dy: 0), precise: PointerVector(dx: 3, dy: 0),
            location: PointerPoint(x: 100, y: 100), at: 1
        ) == .passThrough)
        router.setDisplays([Self.screen])
        #expect(router.process(
            device: Self.mouse, delta: PointerMotion(dx: 3, dy: 0), precise: PointerVector(dx: .nan, dy: 0),
            location: PointerPoint(x: 100, y: 100), at: 1
        ) == .passThrough)
        #expect(router.process(
            device: Self.mouse, delta: PointerMotion(dx: 3, dy: 0), precise: PointerVector(dx: 3, dy: 0),
            location: PointerPoint(x: .infinity, y: 100), at: 1
        ) == .passThrough)
    }

    @Test func zeroAndInvalidAnglesAreLeftOut() {
        var router = Self.router(["a": 0, "b": .nan, "c": 360])
        #expect(!router.isActive)
        router.setAngles(["a": 450])
        #expect(router.angles == ["a": 90])
    }

    @Test func breakingContinuityForgetsTheWrittenPosition() {
        var router = Self.router()
        _ = router.process(
            device: Self.mouse, delta: PointerMotion(dx: 10, dy: 0), precise: PointerVector(dx: 10, dy: 0),
            location: PointerPoint(x: 510, y: 500), at: 1
        )
        router.breakContinuity()
        let next = router.process(
            device: Self.mouse, delta: PointerMotion(dx: 10, dy: 0), precise: PointerVector(dx: 10, dy: 0),
            location: PointerPoint(x: 210, y: 200), at: 1.01
        )
        #expect(next == .rewrite(delta: PointerMotion(dx: 0, dy: 10), location: PointerPoint(x: 200, y: 210)))
    }
}

@Suite("Pointer orientation preview")
struct PointerOrientationTrialTests {
    let now = Date(timeIntervalSinceReferenceDate: 1000)

    @Test func previewConfirmsBeforeTheDeadlineOnly() throws {
        var trial = PointerOrientationTrial()
        let outcome = trial.propose(90, on: "m", confirmed: 0, now: now, timeout: 5)
        let expected = PointerOrientationPreview(deviceID: "m", previous: 0, proposed: 90, deadline: now.addingTimeInterval(5))
        #expect(outcome == .previewing(expected))
        let confirmation = trial.confirm(now: now.addingTimeInterval(4))
        let kept = try #require(confirmation)
        #expect(kept.deviceID == "m" && kept.degrees == 90)
        #expect(trial.preview == nil)

        _ = trial.propose(90, on: "m", confirmed: 0, now: now, timeout: 5)
        #expect(trial.confirm(now: now.addingTimeInterval(5)) == nil)
        #expect(trial.preview == nil)
    }

    @Test func unchangedZeroAndInvalidProposals() {
        var trial = PointerOrientationTrial()
        #expect(trial.propose(450, on: "m", confirmed: 90, now: now, timeout: 5) == .unchanged)
        #expect(trial.propose(0, on: "m", confirmed: 90, now: now, timeout: 5) == .commit(0))
        #expect(trial.propose(.nan, on: "m", confirmed: 0, now: now, timeout: 5) == .rejected)
        #expect(trial.preview == nil)
    }

    @Test func repeatedProposalsKeepTheConfirmedBaseline() {
        var trial = PointerOrientationTrial()
        _ = trial.propose(90, on: "m", confirmed: 10, now: now, timeout: 5)
        _ = trial.propose(180, on: "m", confirmed: 90, now: now, timeout: 5)
        #expect(trial.preview?.previous == 10)
        #expect(trial.propose(10, on: "m", confirmed: 10, now: now, timeout: 5) == .unchanged)
        #expect(trial.preview == nil)
        _ = trial.propose(90, on: "m", confirmed: 0, now: now, timeout: 5)
        _ = trial.propose(45, on: "other", confirmed: 0, now: now, timeout: 5)
        #expect(trial.preview?.deviceID == "other")
        #expect(trial.preview?.previous == 0)
    }

    @Test func expiresCancelsAndReconciles() {
        var trial = PointerOrientationTrial()
        _ = trial.propose(90, on: "m", confirmed: 0, now: now, timeout: 5)
        #expect(trial.expire(now: now.addingTimeInterval(1)) == nil)
        #expect(trial.expire(now: now.addingTimeInterval(5))?.proposed == 90)
        #expect(trial.preview == nil)

        _ = trial.propose(90, on: "m", confirmed: 0, now: now, timeout: 5)
        #expect(trial.reconcile(connected: ["m"], confirmed: [:]) == nil)
        #expect(trial.reconcile(connected: ["m"], confirmed: ["m": 30])?.deviceID == "m")
        _ = trial.propose(90, on: "m", confirmed: 0, now: now, timeout: 5)
        #expect(trial.reconcile(connected: [], confirmed: [:])?.deviceID == "m")
        _ = trial.propose(90, on: "m", confirmed: 0, now: now, timeout: 5)
        #expect(trial.cancel()?.deviceID == "m")
        #expect(trial.cancel() == nil)
    }
}

@Suite("Pointer calibration recording")
struct PointerCalibrationRecorderTests {
    @Test func pausesSplitStrokesAndNoiseIsIgnored() {
        var recorder = PointerCalibrationRecorder()
        recorder.record(PointerVector(dx: 0, dy: -10), at: 0)
        recorder.record(PointerVector(dx: 0, dy: -10), at: 0.1)
        recorder.settle(at: 0.2)
        #expect(recorder.strokes.isEmpty)
        recorder.settle(at: 0.5)
        #expect(recorder.strokes == [PointerVector(dx: 0, dy: -20)])
        recorder.record(PointerVector(dx: 1, dy: 1), at: 1)
        recorder.record(PointerVector(dx: 5, dy: -30), at: 2)
        recorder.record(PointerVector(dx: .nan, dy: 0), at: 2.01)
        #expect(recorder.finish() == [PointerVector(dx: 0, dy: -20), PointerVector(dx: 5, dy: -30)])
    }

    @Test func stopsTakingStrokesWhenFull() {
        var recorder = PointerCalibrationRecorder()
        for index in 0..<(PointerCalibrationRecorder.maximumStrokes + 3) {
            recorder.record(PointerVector(dx: 0, dy: -20), at: Double(index))
        }
        #expect(recorder.finish().count == PointerCalibrationRecorder.maximumStrokes)
        #expect(recorder.isFull)
    }

    @Test func recordedStrokesFeedCalibration() {
        var recorder = PointerCalibrationRecorder()
        for index in 0..<3 { recorder.record(PointerVector(dx: 50, dy: 0), at: Double(index)) }
        let assessment = PointerCalibration.assess(strokes: recorder.finish())
        #expect(assessment.correctionDegrees != nil)
    }
}
