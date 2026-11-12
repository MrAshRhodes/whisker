import Foundation

public enum AutoScrollAxes: String, Codable, CaseIterable, Sendable {
    /// Only the distance above or below the anchor counts.
    case vertical
    /// Distance on both axes counts, so the page can drift sideways as well.
    case twoAxis

    public var title: String {
        switch self {
        case .vertical: return "Vertical Only"
        case .twoAxis: return "Both Directions"
        }
    }
}

/// Scroll speed in pixels per second. Vertical positive is up and horizontal positive is left, like `ScrollPixels`.
public struct AutoScrollVelocity: Hashable, Sendable {
    public var vertical: Double
    public var horizontal: Double

    public init(vertical: Double = 0, horizontal: Double = 0) {
        self.vertical = vertical
        self.horizontal = horizontal
    }
}

/// Settings of the auto-scroll action. Pressing the button anchors the pointer; from then on how far the pointer is
/// from the anchor sets the scrolling speed, and a pointer inside the dead zone scrolls nothing.
///
/// The defaults and limits are provisional: none of them has been tried on hardware.
public struct AutoScroll: Hashable, Sendable {
    /// Points from the anchor, on each axis, inside which nothing scrolls.
    public static let deadZoneRange: ClosedRange<Double> = 4...120
    /// Pixels per second once the pointer is `rampDistance` points beyond the dead zone.
    public static let maxSpeedRange: ClosedRange<Double> = 100...6000
    /// Points beyond the dead zone over which the speed rises evenly from nothing to the maximum.
    public static let rampDistance = 240.0
    public static let defaultDeadZone = 12.0
    public static let defaultMaxSpeed = 1200.0

    public var axes: AutoScrollAxes
    public var deadZone: Double
    public var maxSpeed: Double

    public init(axes: AutoScrollAxes = .vertical, deadZone: Double = defaultDeadZone, maxSpeed: Double = defaultMaxSpeed) {
        self.axes = axes
        self.deadZone = deadZone
        self.maxSpeed = maxSpeed
    }

    public var isValid: Bool {
        deadZone.isFinite && maxSpeed.isFinite && Self.deadZoneRange.contains(deadZone) && Self.maxSpeedRange.contains(maxSpeed)
    }

    public var summary: String { "Auto-scroll, \(axes.title)" }

    /// The speed for a pointer at `pointer` with the anchor at `anchor`. A pointer below the anchor scrolls down
    /// and one to its right scrolls right, which is the page moving the way you push it.
    public func velocity(from anchor: PointerPoint, to pointer: PointerPoint) -> AutoScrollVelocity {
        let below = Self.speed(forOffset: pointer.y - anchor.y, deadZone: deadZone, maxSpeed: maxSpeed)
        let right = axes == .twoAxis ? Self.speed(forOffset: pointer.x - anchor.x, deadZone: deadZone, maxSpeed: maxSpeed) : 0
        return AutoScrollVelocity(vertical: 0 - below, horizontal: 0 - right)
    }

    private static func speed(forOffset offset: Double, deadZone: Double, maxSpeed: Double) -> Double {
        guard offset.isFinite else { return 0 }
        let beyond = abs(offset) - deadZoneRange.clamp(deadZone)
        guard beyond > 0 else { return 0 }
        let speed = maxSpeedRange.clamp(maxSpeed) * min(1, beyond / rampDistance)
        return offset < 0 ? -speed : speed
    }
}

/// One auto-scroll, from the press that anchors it until something ends it. Everything it needs is fixed at the
/// press, so nothing about it changes while it runs.
public struct AutoScrollSession: Equatable, Sendable {
    /// Counts up with every session the processor starts, so output that belongs to an earlier one can be told apart.
    public let generation: Int
    /// The mapping that started it. Pressing the same trigger again stops it.
    public let key: MappingKey
    public let anchor: PointerPoint
    public let config: AutoScroll

    public init(generation: Int, key: MappingKey, anchor: PointerPoint, config: AutoScroll) {
        self.generation = generation
        self.key = key
        self.anchor = anchor
        self.config = config
    }
}

/// Turns the pointer's distance from the anchor into whole scroll pixels over time.
///
/// Pure: the clock and the pointer are passed in. Output comes from elapsed time and the fraction that doesn't
/// fit in a whole pixel carries forward, so how often it is asked never changes how fast the page scrolls.
public struct AutoScrollDriver: Sendable {
    /// The longest span of time one step counts for. After a stall (a starved timer, a busy Mac) scrolling carries
    /// on at its own pace instead of catching up in one burst.
    public static let maxStep: TimeInterval = 0.1

    public let anchor: PointerPoint
    public let config: AutoScroll
    private var lastTime: TimeInterval
    private var verticalResidue = 0.0
    private var horizontalResidue = 0.0

    public init(session: AutoScrollSession, now: TimeInterval) {
        anchor = session.anchor
        config = session.config
        lastTime = now
    }

    /// The whole pixels to scroll for the time since the last call, with the pointer at `pointer`.
    public mutating func advance(pointer: PointerPoint, now: TimeInterval) -> ScrollPixels {
        let elapsed = now - lastTime
        let step = elapsed.isFinite ? min(max(elapsed, 0), Self.maxStep) : 0
        lastTime = now
        let velocity = config.velocity(from: anchor, to: pointer)
        return ScrollPixels(
            vertical: Self.take(&verticalResidue, speed: velocity.vertical, over: step),
            horizontal: Self.take(&horizontalResidue, speed: velocity.horizontal, over: step)
        )
    }

    private static func take(_ residue: inout Double, speed: Double, over step: TimeInterval) -> Int {
        // Pausing, or turning round, drops what was owed so it can't leak out as a stray pixel afterwards.
        if speed == 0 || (residue != 0 && (residue < 0) != (speed < 0)) { residue = 0 }
        residue += speed * step
        let whole = residue.rounded(.towardZero)
        residue -= whole
        return Int(whole)
    }
}
