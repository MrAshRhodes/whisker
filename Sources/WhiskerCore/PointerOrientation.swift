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

/// Pure geometry only: `PointerOrientationRouter` decides when it applies. Create once for an angle, rather than calculating trigonometry for each movement.
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

    /// Nil for non-finite input or overflow; the event tap then passes the original event through.
    public func apply(to motion: PointerVector) -> PointerVector? {
        guard motion.dx.isFinite, motion.dy.isFinite else { return nil }
        let x = motion.dx * cosine - motion.dy * sine
        let y = motion.dx * sine + motion.dy * cosine
        guard x.isFinite, y.isFinite else { return nil }
        return PointerVector(dx: x, dy: y)
    }
}

/// Carries fractional counts between movements of one device at one fixed angle.
/// `PointerOrientationRouter` resets it on lost attribution, disable, interruption or preview cancellation, and
/// creates new state when the angle changes.
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

        public init(correctionDegrees: Double?, confidence: Double, rejection: Rejection?) {
            self.correctionDegrees = correctionDegrees
            self.confidence = confidence
            self.rejection = rejection
        }
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

// MARK: - Runtime

/// One display's bounds in global coordinates with the origin at the top left, as `CGDisplayBounds` reports them.
public struct PointerRect: Equatable, Sendable {
    public var x: Double
    public var y: Double
    public var width: Double
    public var height: Double

    public init(x: Double, y: Double, width: Double, height: Double) {
        self.x = x
        self.y = y
        self.width = width
        self.height = height
    }
}

extension PointerOrientationMath {
    /// The nearest point on one of `displays`, so a rotated pointer can never leave the screens. A pixel position
    /// can't be the far edge itself, so it stops one point short of it. Unchanged when there are no displays.
    public static func clamp(_ point: PointerPoint, to displays: [PointerRect]) -> PointerPoint {
        var best = point
        var bestDistance = Double.infinity
        for display in displays where display.width > 0 && display.height > 0 {
            let x = min(max(point.x, display.x), display.x + max(0, display.width - 1))
            let y = min(max(point.y, display.y), display.y + max(0, display.height - 1))
            let distance = (x - point.x) * (x - point.x) + (y - point.y) * (y - point.y)
            if distance == 0 { return point }
            if distance < bestDistance {
                best = PointerPoint(x: x, y: y)
                bestDistance = distance
            }
        }
        return best
    }

    /// The angle each device's movement is turned by right now: confirmed angles of enabled devices, with an
    /// unconfirmed preview on top. Empty while Whisker is off or standing aside, so everything passes through.
    public static func effectiveAngles(
        devices: [String: DeviceSettings], enabled: Bool, preview: PointerOrientationPreview? = nil
    ) -> [String: Double] {
        guard enabled else { return [:] }
        var angles: [String: Double] = [:]
        for (id, device) in devices where device.enabled {
            if let angle = normalisedDegrees(device.rotationDegrees), angle != 0 { angles[id] = angle }
        }
        if let preview, devices[preview.deviceID]?.enabled ?? true {
            if let angle = normalisedDegrees(preview.proposed), angle != 0 {
                angles[preview.deviceID] = angle
            } else {
                angles[preview.deviceID] = nil
            }
        }
        return angles
    }
}

/// Decides, event by event, whether movement is rotated, and where the rotated pointer goes. Pure and bounded: one
/// dictionary lookup and a few multiplications per event, without allocating, so it can run on the tap thread.
///
/// Fails open. Movement passes through unchanged unless it is exactly attributed to one device with a non-zero
/// angle and the displays are known. Anything else (no or ambiguous attribution, an excluded device, invalid
/// numbers) passes through and drops the carried remainder and position, so nothing leaks into later movement.
public struct PointerOrientationRouter: Sendable {
    public enum Decision: Equatable, Sendable {
        case passThrough
        /// New whole-count deltas, and where the event now says the pointer is.
        case rewrite(delta: PointerMotion, location: PointerPoint)
    }

    /// How long the position Whisker last wrote is trusted as where the pointer is. After a pause the event's own
    /// position is used again, in case something else moved the pointer in between.
    public static let continuity: TimeInterval = 0.1

    private struct Entry: Sendable {
        var rotation: PointerRotation
        var counts: PointerRotationAccumulator
    }

    private var entries: [String: Entry] = [:]
    private var displays: [PointerRect] = []
    private var lastDevice: String?
    private var lastLocation: PointerPoint?
    private var lastTime: TimeInterval = 0

    public init() {}

    /// Whether any movement could be rotated, so whether the tap needs to see it at all.
    public var isActive: Bool { !entries.isEmpty && !displays.isEmpty }

    public var angles: [String: Double] { entries.mapValues(\.rotation.degrees) }

    /// Installs angles, keeping the carried remainder of a device whose angle is unchanged. Zero and invalid
    /// angles are left out, so their devices pass through.
    public mutating func setAngles(_ angles: [String: Double]) {
        var next: [String: Entry] = [:]
        for (id, degrees) in angles {
            guard let angle = PointerOrientationMath.normalisedDegrees(degrees), angle != 0 else { continue }
            if let kept = entries[id], kept.rotation.degrees == angle {
                next[id] = kept
            } else if let rotation = PointerRotation(degrees: angle), let counts = PointerRotationAccumulator(degrees: angle) {
                next[id] = Entry(rotation: rotation, counts: counts)
            }
        }
        entries = next
        if let lastDevice, entries[lastDevice] == nil { breakContinuity() }
    }

    public mutating func setDisplays(_ displays: [PointerRect]) {
        self.displays = displays
        breakContinuity()
    }

    /// Forgets the carried remainder and position: the tap was interrupted, or something else moved the pointer.
    public mutating func breakContinuity() {
        if let lastDevice { entries[lastDevice]?.counts.reset() }
        lastDevice = nil
        lastLocation = nil
    }

    /// `delta` is the event's whole-count delta, `precise` its fractional one, `location` where it says the
    /// pointer is now (after the unrotated movement).
    public mutating func process(
        device: DeviceAttribution?, delta: PointerMotion, precise: PointerVector, location: PointerPoint, at time: TimeInterval
    ) -> Decision {
        guard let device, device.exact, !device.isExcluded, !displays.isEmpty, let rotation = entries[device.id]?.rotation,
              location.x.isFinite, location.y.isFinite else {
            breakContinuity()
            return .passThrough
        }
        if lastDevice != device.id { breakContinuity() }
        guard let turned = rotation.apply(to: precise), let counts = entries[device.id]?.counts.apply(delta) else {
            breakContinuity()
            return .passThrough
        }
        let previous: PointerPoint
        if let lastLocation, time >= lastTime, time - lastTime <= Self.continuity {
            previous = lastLocation
        } else {
            previous = PointerPoint(x: location.x - precise.dx, y: location.y - precise.dy)
        }
        let target = PointerOrientationMath.clamp(PointerPoint(x: previous.x + turned.dx, y: previous.y + turned.dy), to: displays)
        guard target.x.isFinite, target.y.isFinite else {
            breakContinuity()
            return .passThrough
        }
        lastDevice = device.id
        lastLocation = target
        lastTime = time
        return .rewrite(delta: counts, location: target)
    }
}

// MARK: - Preview

/// A non-zero angle being tried live, which goes back to `previous` unless it is kept before `deadline`.
/// Only ever held in memory: settings only receive a kept angle, so quitting or crashing mid-preview leaves the
/// confirmed one in place.
public struct PointerOrientationPreview: Equatable, Sendable {
    public var deviceID: String
    /// The confirmed angle that Revert, the timeout and any interruption go back to.
    public var previous: Double
    public var proposed: Double
    public var deadline: Date

    public init(deviceID: String, previous: Double, proposed: Double, deadline: Date) {
        self.deviceID = deviceID
        self.previous = previous
        self.proposed = proposed
        self.deadline = deadline
    }
}

/// Preview, confirm and roll back for orientation, without timers or settings: the caller owns both.
public struct PointerOrientationTrial: Equatable, Sendable {
    public enum Outcome: Equatable, Sendable {
        /// Nothing changes: the angle is the one already in use.
        case unchanged
        /// Save this angle now. Only ever zero: going back to ordinary movement needs no confirmation.
        case commit(Double)
        /// Try it live and wait for confirmation.
        case previewing(PointerOrientationPreview)
        /// Not a finite angle.
        case rejected
    }

    public private(set) var preview: PointerOrientationPreview?

    public init() {}

    /// Asks for `degrees` on a device whose confirmed angle is `confirmed`. A preview for another device is
    /// dropped (and so rolled back) first; one for the same device keeps its confirmed baseline.
    public mutating func propose(
        _ degrees: Double, on deviceID: String, confirmed: Double, now: Date, timeout: TimeInterval
    ) -> Outcome {
        guard let angle = PointerOrientationMath.normalisedDegrees(degrees),
              let confirmed = PointerOrientationMath.normalisedDegrees(confirmed) else { return .rejected }
        let baseline = preview?.deviceID == deviceID ? preview?.previous ?? confirmed : confirmed
        preview = nil
        if angle == baseline { return .unchanged }
        if angle == 0 { return .commit(0) }
        let next = PointerOrientationPreview(
            deviceID: deviceID, previous: baseline, proposed: angle, deadline: now.addingTimeInterval(timeout)
        )
        preview = next
        return .previewing(next)
    }

    /// The angle to save, or nil when there is no preview or it already ran out (and so has rolled back).
    public mutating func confirm(now: Date) -> (deviceID: String, degrees: Double)? {
        guard let preview else { return nil }
        self.preview = nil
        guard now < preview.deadline else { return nil }
        return (preview.deviceID, preview.proposed)
    }

    /// Rolls back. Returns what was being previewed, if anything.
    @discardableResult
    public mutating func cancel() -> PointerOrientationPreview? {
        defer { preview = nil }
        return preview
    }

    /// Rolls back once the deadline has passed.
    @discardableResult
    public mutating func expire(now: Date) -> PointerOrientationPreview? {
        guard let preview, now >= preview.deadline else { return nil }
        return cancel()
    }

    /// Rolls back when the device being previewed has gone, or its confirmed angle changed underneath.
    @discardableResult
    public mutating func reconcile(connected: Set<String>, confirmed: [String: Double]) -> PointerOrientationPreview? {
        guard let preview else { return nil }
        let saved = PointerOrientationMath.normalisedDegrees(confirmed[preview.deviceID] ?? 0) ?? 0
        guard !connected.contains(preview.deviceID) || saved != preview.previous else { return nil }
        return cancel()
    }
}

// MARK: - Calibration recording

/// Collects the forward strokes of a guided calibration from one device's unrotated movement. A pause ends a
/// stroke; tiny strokes are treated as noise. Its storage is reserved up front, so recording on the tap thread
/// doesn't allocate, and it stops taking strokes once it has enough.
public struct PointerCalibrationRecorder: Equatable, Sendable {
    public static let pause: TimeInterval = 0.25
    public static let maximumStrokes = 8
    /// Strokes shorter than this, in motion counts, are ignored as jitter rather than counted.
    public static let noise = 4.0

    public private(set) var strokes: [PointerVector] = []
    private var current = PointerVector(dx: 0, dy: 0)
    private var lastTime: TimeInterval?

    public init() {
        strokes.reserveCapacity(Self.maximumStrokes)
    }

    public var isFull: Bool { strokes.count >= Self.maximumStrokes }

    public mutating func record(_ motion: PointerVector, at time: TimeInterval) {
        guard motion.dx.isFinite, motion.dy.isFinite else { return }
        if let lastTime, time - lastTime > Self.pause { closeStroke() }
        guard !isFull else { return }
        current.dx += motion.dx
        current.dy += motion.dy
        lastTime = time
    }

    /// Ends a stroke that has paused long enough by `time`, so the count shown keeps up without more movement.
    public mutating func settle(at time: TimeInterval) {
        if let lastTime, time - lastTime > Self.pause { closeStroke() }
    }

    /// Ends whatever stroke is under way and returns them all, for `PointerCalibration.assess`.
    public mutating func finish() -> [PointerVector] {
        closeStroke()
        return strokes
    }

    private mutating func closeStroke() {
        defer {
            current = PointerVector(dx: 0, dy: 0)
            lastTime = nil
        }
        guard !isFull, hypot(current.dx, current.dy) >= Self.noise else { return }
        strokes.append(current)
    }
}
