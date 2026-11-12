import Foundation

/// A way to move the mouse while a gesture button is held, as pointer movement reports it (positive y is down).
public enum GestureDirection: String, Codable, CaseIterable, Sendable {
    case up, down, left, right

    public var title: String {
        switch self {
        case .up: return "Up"
        case .down: return "Down"
        case .left: return "Left"
        case .right: return "Right"
        }
    }

    public var arrow: String {
        switch self {
        case .up: return "↑"
        case .down: return "↓"
        case .left: return "←"
        case .right: return "→"
        }
    }

    public var symbolName: String {
        switch self {
        case .up: return "arrow.up"
        case .down: return "arrow.down"
        case .left: return "arrow.left"
        case .right: return "arrow.right"
        }
    }
}

/// Directional gestures on one button: hold it, move the mouse, let go. Each of the four directions can carry one
/// action, and letting go without having moved far enough can carry another (the tap).
///
/// Only actions that do their work once, when performed, can be gesture actions (see `Action.allowedInGestures`).
public struct ButtonGestures: Equatable, Sendable {
    /// Net pointer movement, in the integer counts macOS reports, a drag has to reach before it picks a direction.
    /// Provisional: not yet tried on real mice, and the counts depend on the pointer speed.
    public static let thresholdRange = 20...400
    public static let defaultThreshold = 60
    /// The stronger axis has to cover at least this many times the movement of the weaker one to count as a
    /// direction; anything more diagonal is ambiguous. Provisional, like the threshold.
    public static let dominanceRatio = 2

    public var up: Action?
    public var down: Action?
    public var left: Action?
    public var right: Action?
    /// Performed when the button is let go without having moved as far as the threshold.
    public var tap: Action?
    public var threshold: Int

    public init(
        up: Action? = nil, down: Action? = nil, left: Action? = nil, right: Action? = nil, tap: Action? = nil,
        threshold: Int = ButtonGestures.defaultThreshold
    ) {
        self.up = up
        self.down = down
        self.left = left
        self.right = right
        self.tap = tap
        self.threshold = threshold
    }

    public func action(for direction: GestureDirection) -> Action? {
        switch direction {
        case .up: return up
        case .down: return down
        case .left: return left
        case .right: return right
        }
    }

    public mutating func setAction(_ action: Action?, for direction: GestureDirection) {
        switch direction {
        case .up: up = action
        case .down: down = action
        case .left: left = action
        case .right: right = action
        }
    }

    /// Whether no direction and no tap has an action yet.
    public var isEmpty: Bool {
        up == nil && down == nil && left == nil && right == nil && tap == nil
    }

    public var summary: String {
        var parts = GestureDirection.allCases.compactMap { direction in
            action(for: direction).map { "\(direction.arrow) \($0.summary)" }
        }
        if let tap { parts.append("Tap \(tap.summary)") }
        return parts.isEmpty ? "Gestures (no actions yet)" : "Gestures: \(parts.joined(separator: ", "))"
    }
}

extension ButtonGestures: Codable {
    private enum CodingKeys: String, CodingKey { case up, down, left, right, tap, threshold }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        up = try c.decodeIfPresent(Action.self, forKey: .up)
        down = try c.decodeIfPresent(Action.self, forKey: .down)
        left = try c.decodeIfPresent(Action.self, forKey: .left)
        right = try c.decodeIfPresent(Action.self, forKey: .right)
        tap = try c.decodeIfPresent(Action.self, forKey: .tap)
        threshold = try c.decodeIfPresent(Int.self, forKey: .threshold) ?? Self.defaultThreshold
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        if let up { try c.encode(up, forKey: .up) }
        if let down { try c.encode(down, forKey: .down) }
        if let left { try c.encode(left, forKey: .left) }
        if let right { try c.encode(right, forKey: .right) }
        if let tap { try c.encode(tap, forKey: .tap) }
        try c.encode(threshold, forKey: .threshold)
    }
}

extension Action {
    /// Whether a gesture can run the action: it is one step that is done once it is performed, so it can run when
    /// the button comes up. Actions that last as long as the trigger is held (Click, Hold to Scroll, Slow pointer while
    /// held), run on for a while (Shortcut Sequence) or until something stops them (Auto-scroll) are left out. Keys
    /// that repeat while held (volume, brightness) count: a gesture presses them once. Pointer Speed Preset is left
    /// out for now: it points at a saved preset, and deleting a preset or forgetting a mouse only cleans up button
    /// mappings, not gestures.
    public var allowedInGestures: Bool {
        switch self {
        case .passthrough, .none, .click, .shortcutSequence, .holdToScroll, .autoScroll, .slowPointer, .pointerPreset:
            return false
        case .shortcut(_, let repeats):
            return !repeats
        case .doubleClick, .tripleClick, .scroll, .media, .navigate, .missionControl, .space, .appSwitch, .open:
            return true
        }
    }
}

/// How a gesture attempt ended once its button was let go.
enum GestureOutcome: Equatable, Sendable {
    /// Perform this action, once.
    case perform(Action)
    /// Nothing happens: nothing is set for what was done, the movement was ambiguous or the attempt was called off.
    case nothing
}

/// One gesture attempt, from the press of the button to its release. Everything it depends on is fixed at the
/// press: the button, the device that pressed it, the app in front, the profile and the gestures it was given.
///
/// It only ever looks at net movement of the pressed device, so jitter and back-and-forth wiggles that don't get
/// anywhere pick nothing. Movement that can't be tied to that device is never counted.
struct GestureSession: Equatable, Sendable {
    enum State: Equatable, Sendable {
        /// The movement so far is below the threshold.
        case undecided
        /// A direction was picked from the first movement that reached the threshold. Later movement can't change it.
        case selected(GestureDirection)
        /// The movement reached the threshold without a clear dominant axis. Nothing is performed on release.
        case ambiguous
        /// Called off. Nothing is performed on release.
        case cancelled
    }

    /// Movement events in a row that can't be tied to a device before the attempt is called off.
    static let attributionGrace = 3

    let button: Int
    let device: String
    let app: String?
    let profile: String
    let config: ButtonGestures
    private let threshold: Int
    private(set) var state: State = .undecided
    private var sumX = 0
    private var sumY = 0
    private var unattributed = 0

    init(button: Int, device: String, app: String?, profile: String, config: ButtonGestures) {
        self.button = button
        self.device = device
        self.app = app
        self.profile = profile
        self.config = config
        threshold = ButtonGestures.thresholdRange.clamp(config.threshold)
    }

    /// Takes in one movement of the held button. `source` is who moved: only exact attribution to the device that
    /// pressed the button counts. Another mouse's movement is its own business; movement that can't be attributed
    /// is ignored too, and when it keeps coming the attempt is called off rather than guessed at.
    mutating func move(_ motion: PointerMotion, from source: DeviceAttribution?) {
        guard state == .undecided else { return }
        guard let source, source.exact else {
            unattributed += 1
            if unattributed >= Self.attributionGrace { state = .cancelled }
            return
        }
        unattributed = 0
        guard source.id == device, !motion.isZero else { return }
        sumX += motion.dx
        sumY += motion.dy
        let x = abs(sumX), y = abs(sumY)
        guard max(x, y) >= threshold else { return }
        guard max(x, y) >= min(x, y) * ButtonGestures.dominanceRatio else {
            state = .ambiguous
            return
        }
        state = x >= y ? .selected(sumX > 0 ? .right : .left) : .selected(sumY > 0 ? .down : .up)
    }

    /// What letting go of the button comes to. A release that is exactly another mouse's isn't this attempt's to
    /// complete; one that can't be attributed is taken as the pressed device's, since the movement was verified.
    func release(from source: DeviceAttribution?) -> GestureOutcome {
        if let source, source.exact, source.id != device { return .nothing }
        let action: Action?
        switch state {
        case .undecided: action = config.tap
        case .selected(let direction): action = config.action(for: direction)
        case .ambiguous, .cancelled: action = nil
        }
        guard let action, action.allowedInGestures else { return .nothing }
        return .perform(action)
    }
}
