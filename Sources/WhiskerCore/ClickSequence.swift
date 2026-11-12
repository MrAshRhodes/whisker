import Foundation

/// One synthetic mouse event in a click gesture.
public struct ClickStep: Equatable, Sendable {
    public var button: Int
    public var isDown: Bool
    /// The click count the event carries (`mouseEventClickState`).
    public var clickState: Int64

    public init(button: Int, isDown: Bool, clickState: Int64) {
        self.button = button
        self.isDown = isDown
        self.clickState = clickState
    }
}

/// A gesture of repeated clicks as plain data: a press and a release for each click, counted 1, 2, 3…
/// whatever click count the trigger itself carried.
public struct ClickPlan: Equatable, Sendable {
    public var button: Int
    public var clicks: Int

    public init(button: Int, clicks: Int) {
        self.button = button
        self.clicks = clicks
    }

    /// Three primary-button clicks.
    public static let tripleClick = ClickPlan(button: 0, clicks: 3)

    /// The events in the order they are posted: press, release, press, release…
    public var steps: [ClickStep] {
        guard clicks > 0 else { return [] }
        return (1...clicks).flatMap { count in
            [
                ClickStep(button: button, isDown: true, clickState: Int64(count)),
                ClickStep(button: button, isDown: false, clickState: Int64(count)),
            ]
        }
    }
}

/// How the steps of a gesture are spread out in time.
public struct ClickTiming: Equatable, Sendable {
    /// From the press of one click to the press of the next. Zero posts every click back to back.
    public let spacing: TimeInterval
    /// From a press to its release.
    public let hold: TimeInterval

    public init(spacing: TimeInterval = 0, hold: TimeInterval = 0) {
        self.spacing = spacing.isFinite && spacing > 0 ? spacing : 0
        self.hold = hold.isFinite && hold > 0 ? hold : 0
    }

    /// Everything at once, in order.
    public static let immediate = ClickTiming()

    /// Presses a quarter of the system's double-click interval apart, so the clicks of a triple click all fall
    /// well inside the window apps use to count them. Falls back to `immediate` if the interval is unusable.
    public static func spaced(withinInterval interval: TimeInterval) -> ClickTiming {
        guard interval.isFinite, interval > 0 else { return .immediate }
        return ClickTiming(spacing: interval / 4)
    }
}

/// Follows one click gesture while its steps come due.
///
/// It is pure state: the caller supplies the time, posts the steps it is handed in order, and sets a timer for
/// `nextDue`. Nothing here waits, so the same code runs under a real timer and under a test clock.
public struct ClickSequencer: Sendable {
    private struct Entry: Sendable {
        var step: ClickStep
        var due: TimeInterval
    }

    private var waiting: [Entry] = []
    /// The press that has been handed out but not yet its release.
    private var pressed: ClickStep?

    /// Changes whenever a gesture starts or is called off, so a timer set for an earlier gesture can tell it is stale.
    public private(set) var generation: UInt64 = 0

    public init() {}

    /// Whether any step is still to come or a press is still waiting for its release.
    public var isActive: Bool { !waiting.isEmpty || pressed != nil }

    /// When the next step is due, or nil when nothing is waiting.
    public var nextDue: TimeInterval? { waiting.first?.due }

    /// Starts a gesture and returns the steps due straight away. Call `cancel()` first if `isActive`: a press the
    /// earlier gesture still owes a release for would otherwise be forgotten.
    public mutating func begin(_ plan: ClickPlan, timing: ClickTiming, now: TimeInterval) -> [ClickStep] {
        generation &+= 1
        pressed = nil
        var last = now
        waiting = plan.steps.enumerated().map { index, step in
            // Steps come in pairs: a click's press, then its release.
            let due = now + Double(index / 2) * timing.spacing + (step.isDown ? 0 : timing.hold)
            last = max(last, due)
            return Entry(step: step, due: last)
        }
        return takeDue(by: now)
    }

    /// The steps that have come due by `now`, in order. Each step is handed out once.
    public mutating func advance(to now: TimeInterval) -> [ClickStep] {
        takeDue(by: now)
    }

    /// Calls the gesture off: whatever hasn't been handed out is dropped, and a press that was handed out gets
    /// its release so a button is never left down. Returns that release, if there is one.
    public mutating func cancel() -> [ClickStep] {
        guard isActive else { return [] }
        generation &+= 1
        waiting = []
        guard let press = pressed else { return [] }
        pressed = nil
        return [ClickStep(button: press.button, isDown: false, clickState: press.clickState)]
    }

    private mutating func takeDue(by now: TimeInterval) -> [ClickStep] {
        var due: [ClickStep] = []
        while let next = waiting.first, next.due <= now {
            waiting.removeFirst()
            pressed = next.step.isDown ? next.step : nil
            due.append(next.step)
        }
        return due
    }
}

/// What calls off a click gesture that is still waiting to finish.
public enum ClickInterruption {
    /// Whether an event the tap has just handled calls a pending gesture off. Input that reaches an app or sets
    /// off another action does. A swallowed event doesn't (a trigger's release, the rest of a wheel burst), and
    /// neither does a drag, which only carries on a press that already did.
    public static func isCalledOffBy(_ kind: InputKind, plan: EventPlan) -> Bool {
        if case .buttonDragged = kind { return false }
        switch plan {
        case .passThrough, .perform, .performWithScroll, .scroll, .smooth: return true
        case .swallow, .dragAs, .dragAsMove, .holdScroll: return false
        }
    }

    /// Whether a change to the connected mice calls off a gesture started by `source`: the mouse is gone, or
    /// it was never known, so there's no telling whether it is.
    public static func isCalledOffByDeviceChange(startedBy source: String?, connected: Set<String>) -> Bool {
        guard let source else { return true }
        return !connected.contains(source)
    }
}
