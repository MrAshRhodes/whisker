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
