import CoreGraphics
import Foundation
import WhiskerCore

/// Runs an auto-scroll off the event tap. The tap only hands over a session and later cancels it; a timer on a
/// private queue reads where the pointer is and posts at most one generated scroll event per tick. Nothing is
/// posted after `cancel()` has returned, and with no session there is no timer at all.
///
/// The pointer is read here, a tick at a time, rather than from `.mouseMoved` events: that leaves the tap's
/// event mask and its callback exactly as they were. Reading the position is not tied to any one device, so
/// it makes no claim about which mouse moved.
///
/// The driver, its clock and the posting share one lock, so an event can never leave after a cancellation.
final class AutoScroller: @unchecked Sendable {
    /// How often a tick runs while there is a session.
    static let tickInterval: TimeInterval = 1.0 / 120

    private let state = NSLock()
    private var driver: AutoScrollDriver?
    private var generation: Int?
    private var timerRequested = false
    private let clock: @Sendable () -> TimeInterval
    private let pointer: @Sendable () -> PointerPoint?
    private let post: @Sendable (ScrollPixels, PointerPoint) -> Void
    /// Starts ticking soon. The default hops to a private queue; tests drive `tick()` themselves.
    private let startTicking: @Sendable (AutoScroller) -> Void
    private let queue = DispatchQueue(label: "io.github.mrashrhodes.whisker.autoscroll", qos: .userInteractive)
    private var timer: DispatchSourceTimer?

    init(
        clock: @escaping @Sendable () -> TimeInterval = { ProcessInfo.processInfo.systemUptime },
        pointer: @escaping @Sendable () -> PointerPoint? = { AutoScroller.pointerLocation() },
        post: @escaping @Sendable (ScrollPixels, PointerPoint) -> Void = { AutoScroller.postEvent($0, at: $1) },
        startTicking: (@Sendable (AutoScroller) -> Void)? = nil
    ) {
        self.clock = clock
        self.pointer = pointer
        self.post = post
        self.startTicking = startTicking ?? { scroller in scroller.queue.async { scroller.startTimer() } }
    }

    /// Called from the tap. Replaces whatever was running; the new session counts time from now.
    func start(_ session: AutoScrollSession) {
        let now = clock()
        state.lock()
        driver = AutoScrollDriver(session: session, now: now)
        generation = session.generation
        let begin = !timerRequested
        if begin { timerRequested = true }
        state.unlock()
        if begin { startTicking(self) }
    }

    /// Called from the tap and from lifecycle changes. Drops the session; whatever it still owed is never posted.
    func cancel() {
        state.lock()
        driver = nil
        generation = nil
        state.unlock()
    }

    /// The generation of the session being run, for tests.
    var runningGeneration: Int? {
        state.lock()
        defer { state.unlock() }
        return generation
    }

    var isIdle: Bool {
        state.lock()
        defer { state.unlock() }
        return driver == nil && !timerRequested
    }

    /// Posts what is due. Returns whether there is still a session to run.
    @discardableResult
    func tick() -> Bool {
        // Read before the lock, so the tap waits only for the bookkeeping and the post.
        let location = pointer()
        state.lock()
        defer { state.unlock() }
        guard var running = driver else {
            timerRequested = false
            return false
        }
        // A pointer that can't be read counts as resting on the anchor, which pauses scrolling.
        let pixels = running.advance(pointer: location ?? running.anchor, now: clock())
        driver = running
        if !pixels.isZero { post(pixels, running.anchor) }
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

    static func pointerLocation() -> PointerPoint? {
        guard let location = CGEvent(source: nil)?.location else { return nil }
        return PointerPoint(x: location.x, y: location.y)
    }

    /// One pixel scroll event addressed to the anchor, marked so the tap lets it through. The pointer itself is
    /// never moved. Runs on the worker queue.
    static func postEvent(_ pixels: ScrollPixels, at anchor: PointerPoint) {
        guard let event = CGEvent(
            scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2,
            wheel1: Int32(clamping: pixels.vertical), wheel2: Int32(clamping: pixels.horizontal), wheel3: 0
        ) else { return }
        let perLine = ScrollMath.pointsPerLine
        let vertical = Double(pixels.vertical) / perLine, horizontal = Double(pixels.horizontal) / perLine
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: vertical)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: horizontal)
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(vertical.rounded()))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(horizontal.rounded()))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(pixels.vertical))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(pixels.horizontal))
        // Held keys would turn scrolling into zooming or sideways scrolling, so the event carries none.
        event.flags = []
        event.location = CGPoint(x: anchor.x, y: anchor.y)
        event.setIntegerValueField(.eventSourceUserData, value: EventSynthesizer.marker)
        event.post(tap: .cghidEventTap)
    }
}
