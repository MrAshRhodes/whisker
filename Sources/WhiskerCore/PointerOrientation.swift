import Foundation

/// Relative movement, with positive X to the right and positive Y down. Not a display position.
public struct PointerVector: Equatable, Sendable {
    public var dx: Double
    public var dy: Double

    public init(dx: Double, dy: Double) {
        self.dx = dx
        self.dy = dy
    }
}

public enum PointerOrientationMath {
    /// A finite angle in [-180, 180), with one representation for zero. Positive turns clockwise.
    public static func normalisedDegrees(_ degrees: Double) -> Double? {
        guard degrees.isFinite else { return nil }
        var result = degrees.truncatingRemainder(dividingBy: 360)
        if result >= 180 { result -= 360 }
        if result < -180 { result += 360 }
        return result == 0 ? 0 : result
    }
}

/// Pure geometry only: this does not change the system pointer or establish motion attribution.
/// Create once for an angle, rather than calculating trigonometry for each movement.
public struct PointerRotation: Sendable {
    public let degrees: Double
    private let cosine: Double
    private let sine: Double

    public init?(degrees: Double) {
        guard let angle = PointerOrientationMath.normalisedDegrees(degrees) else { return nil }
        self.degrees = angle
        // Exact quarter turns avoid accumulating the tiny errors of sin(pi) and cos(pi/2).
        switch angle {
        case 0: (cosine, sine) = (1, 0)
        case 90: (cosine, sine) = (0, 1)
        case -90: (cosine, sine) = (0, -1)
        case -180: (cosine, sine) = (-1, 0)
        default:
            let radians = angle * .pi / 180
            (cosine, sine) = (cos(radians), sin(radians))
        }
    }

    /// Nil for non-finite input or overflow; a future event adapter must pass the original event through.
    public func apply(to motion: PointerVector) -> PointerVector? {
        guard motion.dx.isFinite, motion.dy.isFinite else { return nil }
        let x = motion.dx * cosine - motion.dy * sine
        let y = motion.dx * sine + motion.dy * cosine
        guard x.isFinite, y.isFinite else { return nil }
        return PointerVector(dx: x, dy: y)
    }
}

/// Carries fractional counts between movements of one device at one fixed angle.
/// Not connected to the event tap. A future adapter must reset on lost attribution, disable,
/// interruption or preview cancellation, and create new state when the angle or device changes.
public struct PointerRotationAccumulator: Sendable {
    private let rotation: PointerRotation
    private var residual = PointerVector(dx: 0, dy: 0)

    public init?(degrees: Double) {
        guard let rotation = PointerRotation(degrees: degrees) else { return nil }
        self.rotation = rotation
    }

    public mutating func reset() {
        residual = PointerVector(dx: 0, dy: 0)
    }

    /// Rounds to the nearest count, retaining the signed remainder even when movement reverses.
    /// Ties go to even, so a half-count remainder never emits movement on a subsequent zero sample.
    /// Nil means neither axis can be used; leftovers are cleared so invalid input cannot leak later.
    public mutating func apply(_ motion: PointerMotion) -> PointerMotion? {
        if rotation.degrees == 0 { return motion }
        let x = Double(motion.dx), y = Double(motion.dy)
        guard Int(exactly: x) == motion.dx, Int(exactly: y) == motion.dy,
              let rotated = rotation.apply(to: PointerVector(dx: x, dy: y)),
              let wholeX = Int(exactly: (rotated.dx + residual.dx).rounded(.toNearestOrEven)),
              let wholeY = Int(exactly: (rotated.dy + residual.dy).rounded(.toNearestOrEven)) else {
            reset()
            return nil
        }
        residual = PointerVector(
            dx: rotated.dx + residual.dx - Double(wholeX),
            dy: rotated.dy + residual.dy - Double(wholeY)
        )
        return PointerMotion(dx: wholeX, dy: wholeY)
    }
}

/// An offline estimate from explicitly recorded forward strokes, not from normal pointer use.
public enum PointerCalibration {
    public enum Rejection: Equatable, Sendable {
        case invalidMovement
        case tooFewStrokes
        case insufficientMovement
        case inconsistentDirections
    }

    public struct Assessment: Equatable, Sendable {
        /// A proposed correction towards screen up (-Y), never permission to apply it globally.
        public let correctionDegrees: Double?
        /// Length of the mean unit direction, from 0 (opposed) to 1 (aligned); not a probability.
        public let confidence: Double
        public let rejection: Rejection?
    }

    /// Provisional gates, not hardware-validated ergonomic limits: at least three strokes, each at
    /// least 20 motion counts, and directional confidence of 0.9. Only forward legs belong here;
    /// return strokes must be excluded by an explicit recording flow, never inferred automatically.
    public static func assess(strokes: [PointerVector]) -> Assessment {
        guard strokes.allSatisfy({ $0.dx.isFinite && $0.dy.isFinite && hypot($0.dx, $0.dy).isFinite }) else {
            return Assessment(correctionDegrees: nil, confidence: 0, rejection: .invalidMovement)
        }
        guard strokes.count >= 3 else {
            return Assessment(correctionDegrees: nil, confidence: 0, rejection: .tooFewStrokes)
        }
        var meanX = 0.0, meanY = 0.0
        for stroke in strokes {
            let length = hypot(stroke.dx, stroke.dy)
            guard length >= 20 else {
                return Assessment(correctionDegrees: nil, confidence: 0, rejection: .insufficientMovement)
            }
            // Equal weight per stroke prevents one long stroke from hiding disagreement.
            meanX += stroke.dx / length / Double(strokes.count)
            meanY += stroke.dy / length / Double(strokes.count)
        }
        let confidence = min(1, hypot(meanX, meanY))
        guard confidence >= 0.9 else {
            return Assessment(correctionDegrees: nil, confidence: confidence, rejection: .inconsistentDirections)
        }
        let correction = PointerOrientationMath.normalisedDegrees(-90 - atan2(meanY, meanX) * 180 / .pi)
        return Assessment(correctionDegrees: correction, confidence: confidence, rejection: nil)
    }
}
