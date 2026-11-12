import Foundation

/// A position in global display coordinates, as event taps report it.
public struct PointerPoint: Hashable, Sendable {
    public var x: Double
    public var y: Double

    public init(x: Double, y: Double) {
        self.x = x
        self.y = y
    }

    public func distance(to other: PointerPoint) -> Double {
        ((x - other.x) * (x - other.x) + (y - other.y) * (y - other.y)).squareRoot()
    }
}

/// Relative pointer movement of one event, in the integer counts the system reports (positive is right and down).
public struct PointerMotion: Hashable, Sendable {
    public var dx: Int
    public var dy: Int

    public init(dx: Int, dy: Int) {
        self.dx = dx
        self.dy = dy
    }

    public var isZero: Bool { dx == 0 && dy == 0 }
    public var magnitude: Double { (Double(dx * dx + dy * dy)).squareRoot() }
}

/// Whole pixels of scrolling. Vertical positive is up and horizontal positive is left, like `ScrollSample`.
public struct ScrollPixels: Hashable, Sendable {
    public var vertical: Int
    public var horizontal: Int

    public init(vertical: Int = 0, horizontal: Int = 0) {
        self.vertical = vertical
        self.horizontal = horizontal
    }

    public var isZero: Bool { vertical == 0 && horizontal == 0 }
}

public enum HoldScrollAxes: String, Codable, CaseIterable, Sendable {
    case vertical, horizontal, free
    /// Each hold picks vertical or horizontal from its first movement and keeps it until release.
    case automatic

    public var title: String {
        switch self {
        case .vertical: return "Vertical"
        case .horizontal: return "Horizontal"
        case .free: return "Both Directions"
        case .automatic: return "Automatic Axis Lock"
        }
    }
}

/// Settings of the hold-to-scroll action. By default the page follows the ball, like dragging a sheet of paper.
public struct HoldScroll: Hashable, Sendable {
    /// Pixels scrolled per pixel of pointer movement.
    public static let sensitivityRange: ClosedRange<Double> = 0.1...5

    public var axes: HoldScrollAxes
    public var sensitivity: Double
    public var invertVertical: Bool
    public var invertHorizontal: Bool

    public init(axes: HoldScrollAxes = .vertical, sensitivity: Double = 1, invertVertical: Bool = false, invertHorizontal: Bool = false) {
        self.axes = axes
        self.sensitivity = sensitivity
        self.invertVertical = invertVertical
        self.invertHorizontal = invertHorizontal
    }

    public var isValid: Bool { sensitivity.isFinite && Self.sensitivityRange.contains(sensitivity) }

    public var summary: String { "Hold to Scroll, \(axes.title)" }
}

/// Chooses the scroll axis of one hold from the direction of its first movement, then keeps it until the hold ends.
///
/// Works on raw movement counts, before sensitivity, reversal or rounding, so changing the scroll speed never
/// changes which axis is picked. It knows nothing about pointer orientation. State lives in the value, so a new
/// hold starts undecided with nothing carried over.
public struct AxisLockSelector: Sendable, Equatable {
    public enum State: Sendable, Equatable { case undecided, vertical, horizontal }

    /// Movement counts along the stronger axis needed before an axis is picked. Provisional: this is not an
    /// ergonomic measurement and has not been tried on thumb or finger trackballs.
    public static let selectionThreshold = 8

    public private(set) var state: State = .undecided
    private var sumX = 0
    private var sumY = 0

    public init() {}

    /// Returns the movement to use: nothing while undecided, the whole selected-axis movement so far once the
    /// threshold is crossed (so initial movement counts exactly once), then only the selected axis.
    /// The perpendicular part is dropped and never returned later. A balanced diagonal selects vertical.
    public mutating func filter(_ motion: PointerMotion) -> PointerMotion {
        switch state {
        case .vertical: return PointerMotion(dx: 0, dy: motion.dy)
        case .horizontal: return PointerMotion(dx: motion.dx, dy: 0)
        case .undecided:
            sumX += motion.dx
            sumY += motion.dy
            let x = abs(sumX), y = abs(sumY)
            guard max(x, y) >= Self.selectionThreshold else { return PointerMotion(dx: 0, dy: 0) }
            let initial: PointerMotion
            if y >= x {
                state = .vertical
                initial = PointerMotion(dx: 0, dy: sumY)
            } else {
                state = .horizontal
                initial = PointerMotion(dx: sumX, dy: 0)
            }
            sumX = 0
            sumY = 0
            return initial
        }
    }
}

/// Turns pointer displacement into whole scroll pixels, carrying the fraction that doesn't fit forward so slow
/// movement and low sensitivity still add up instead of rounding away.
public struct DisplacementScroller: Sendable {
    public let config: HoldScroll
    private var verticalResidue = 0.0
    private var horizontalResidue = 0.0
    private var axisLock = AxisLockSelector()

    public init(_ config: HoldScroll) {
        self.config = config
    }

    public mutating func add(_ rawMotion: PointerMotion) -> ScrollPixels {
        let motion = config.axes == .automatic ? axisLock.filter(rawMotion) : rawMotion
        // Only the axes in use accumulate, so movement on a locked-out axis can't build up and leak later.
        var vertical = 0.0, horizontal = 0.0
        let sensitivity = HoldScroll.sensitivityRange.clamp(config.sensitivity)
        if config.axes != .horizontal {
            vertical = Double(motion.dy) * sensitivity * (config.invertVertical ? -1 : 1)
        }
        if config.axes != .vertical {
            horizontal = Double(motion.dx) * sensitivity * (config.invertHorizontal ? -1 : 1)
        }
        return ScrollPixels(
            vertical: Self.take(&verticalResidue, adding: vertical),
            horizontal: Self.take(&horizontalResidue, adding: horizontal)
        )
    }

    public mutating func reset() {
        verticalResidue = 0
        horizontalResidue = 0
        axisLock = AxisLockSelector()
    }

    private static func take(_ residue: inout Double, adding amount: Double) -> Int {
        residue += amount
        let whole = residue.rounded(.towardZero)
        residue -= whole
        return Int(whole)
    }
}

/// Why a hold stopped turning movement into scrolling and let the pointer move normally instead.
public enum HoldFallbackReason: Equatable, Sendable {
    /// Movement could no longer be tied to the device that was pressed.
    case attributionLost
    /// The pointer wandered away from where it was held, so keeping it still isn't working.
    case pointerDrifted

    public var message: String {
        switch self {
        case .attributionLost:
            return "Hold to Scroll stopped because Whisker could not tell which mouse was moving. The pointer moved normally instead."
        case .pointerDrifted:
            return "Hold to Scroll stopped because the pointer could not be kept still. The pointer moved normally instead."
        }
    }
}

public enum HoldScrollStatus: Equatable, Sendable {
    case idle
    case scrolling
    /// The button went down without a device Whisker could identify, so it kept its normal behaviour.
    case unavailable
    case fellBack(HoldFallbackReason)

    public var message: String? {
        switch self {
        case .idle, .scrolling: return nil
        case .unavailable:
            return "Hold to Scroll needs to know which mouse you pressed. Allow Input Monitoring in General, then try again."
        case .fellBack(let reason): return reason.message
        }
    }
}

/// One hold-to-scroll interaction, from the press to the release. Everything it needs is fixed at the press: the
/// button, the device that pressed it, the app in front, where the pointer is held and the settings.
struct HoldScrollSession: Sendable {
    /// Pointer movement further than this (plus the event's own movement) from the anchor counts as drift.
    static let driftTolerance = 4.0
    /// Events in a row that can't be tied to the pressed device before the hold gives up.
    static let attributionGrace = 3

    let button: Int
    let device: String
    let app: String?
    let anchor: PointerPoint
    private var scroller: DisplacementScroller
    private(set) var fallback: HoldFallbackReason?
    private var unattributed = 0

    init(button: Int, device: String, app: String?, anchor: PointerPoint, config: HoldScroll) {
        self.button = button
        self.device = device
        self.app = app
        self.anchor = anchor
        scroller = DisplacementScroller(config)
    }

    /// The plan for one movement event of the held button. Anything that isn't clearly this device's movement
    /// becomes plain pointer movement, never scrolling.
    mutating func motion(_ event: InputEvent) -> EventPlan {
        if fallback != nil { return .dragAsMove }
        guard let motion = event.motion, let location = event.location else { return .dragAsMove }
        guard let source = event.motionDevice, source.exact else {
            unattributed += 1
            if unattributed >= Self.attributionGrace { fallback = .attributionLost }
            return .dragAsMove
        }
        unattributed = 0
        // Another mouse moving while this button is held is its own business.
        guard source.id == device else { return .dragAsMove }
        // The pointer is put back on the anchor after every event, so it can be at most one event's movement away.
        if location.distance(to: anchor) > motion.magnitude * 1.5 + Self.driftTolerance {
            fallback = .pointerDrifted
            return .dragAsMove
        }
        return .holdScroll(scroller.add(motion), anchor: anchor)
    }
}
