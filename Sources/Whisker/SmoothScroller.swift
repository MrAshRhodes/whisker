import CoreGraphics
import Foundation
import WhiskerCore

/// Runs the smooth-scroll planner off the event tap: the tap only enqueues bounded work, a timer on a private
/// queue posts at most one generated event per tick, and cancelling guarantees nothing is posted afterwards.
///
/// Planner access and posting share one lock, so an event can never leave after `cancel()` has returned.
final class SmoothScroller: @unchecked Sendable {
    /// How often a tick runs while there is work. Idle means no timer at all.
    static let tickInterval: TimeInterval = 1.0 / 120

    private let state = NSLock()
    private var planner = SmoothScrollPlanner()
    private var timerRequested = false
    private let clock: @Sendable () -> TimeInterval
    private let post: @Sendable (SmoothScrollOutput) -> Void
    /// Starts ticking soon. The default hops to a private queue; tests drive `tick()` themselves.
    private let startTicking: @Sendable (SmoothScroller) -> Void
    private let queue = DispatchQueue(label: "io.github.mrashrhodes.whisker.smooth", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    init(
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        post: @escaping @Sendable (SmoothScrollOutput) -> Void = { SmoothScroller.postEvent($0) },
        startTicking: (@Sendable (SmoothScroller) -> Void)? = nil
    ) {
        self.clock = clock
        self.post = post
        self.startTicking = startTicking ?? { scroller in scroller.queue.async { scroller.startTimer() } }
    }

    /// Called from the tap. Returns false when the work was refused, and the caller passes the event on.
    func enqueue(vertical: Double, horizontal: Double, context: SmoothingContext, durationMilliseconds: Int) -> Bool {
        let now = clock()
        state.lock()
        let admission = planner.enqueue(
            vertical: vertical, horizontal: horizontal, context: context, duration: Double(durationMilliseconds) / 1000, now: now
        )
        let start = admission == .accepted && !timerRequested
        if start { timerRequested = true }
        state.unlock()
        if start { startTicking(self) }
        return admission == .accepted
    }

    /// Drops all pending distance. It is counted in `discarded`, never delivered later.
    @discardableResult
    func cancel() -> SmoothScrollDiscard {
        state.lock()
        defer { state.unlock() }
        return planner.cancel()
    }

    @discardableResult
    func cancel(unlessConnected connected: Set<String>) -> SmoothScrollDiscard {
        state.lock()
        defer { state.unlock() }
        return planner.cancel(unlessConnected: connected)
    }

    var discarded: SmoothScrollDiscard {
        state.lock()
        defer { state.unlock() }
        return planner.discarded
    }

    var isIdle: Bool {
        state.lock()
        defer { state.unlock() }
        return planner.isIdle
    }

    /// Posts what is due. Returns whether more work remains.
    @discardableResult
    func tick() -> Bool {
        state.lock()
        defer { state.unlock() }
        if let output = planner.tick(now: clock()) { post(output) }
        if planner.isIdle {
            timerRequested = false
            return false
        }
        return true
    }

    private func startTimer() {
        guard timer == nil else { return }
        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now(), repeating: Self.tickInterval, leeway: .milliseconds(1))
        timer.setEventHandler { [weak self] in
            guard let self else { return }
            if !self.tick() {
                self.timer?.cancel()
                self.timer = nil
            }
        }
        self.timer = timer
        timer.resume()
    }

    /// One pixel scroll event, marked so the tap lets it through. Runs on the worker queue.
    static func postEvent(_ output: SmoothScrollOutput) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32(clamping: output.vertical), wheel2: Int32(clamping: output.horizontal), wheel3: 0
        ) else { return }
        let perLine = ScrollMath.pointsPerLine
        let vertical = Double(output.vertical) / perLine, horizontal = Double(output.horizontal) / perLine
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: vertical)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: horizontal)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(vertical.rounded()))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(horizontal.rounded()))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(output.vertical))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(output.horizontal))
        event.flags = CGEventFlags(rawValue: output.context.flags)
        if let location = CGEvent(source: nil)?.location { event.location = location }
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.marker)
        event.post(tap: .cghidEventTap)
    }
}
