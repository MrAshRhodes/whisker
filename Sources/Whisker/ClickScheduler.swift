import CoreGraphics
import Foundation
import os
import WhiskerCore

/// Where a click gesture gets its timers from. The app uses the system clock; tests move a clock by hand.
protocol ClickClock: Sendable {
    /// Seconds on a monotonic clock.
    var now: TimeInterval { get }

    /// Runs `body` once, `delay` seconds from now, on a queue of the clock's own: never on the event tap thread and
    /// never before this call has returned. The closure it returns calls the timer off, but a body that has already
    /// started can't be stopped, so bodies must cope with running after they were called off.
    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () -> Void) -> @Sendable () -> Void
}

/// The real clock. Timers run on a serial queue of their own, so the event tap thread never waits on a click.
final class SystemClickClock: ClickClock, @unchecked Sendable {
    private let queue = DispatchQueue(label: "io.github.mrashrhodes.whisker.clicks", qos: .userInteractive)

    var now: TimeInterval { ProcessInfo.processInfo.systemUptime }

    func schedule(after delay: TimeInterval, _ body: @escaping @Sendable () -> Void) -> @Sendable () -> Void {
        let item = DispatchWorkItem(block: body)
        queue.asyncAfter(deadline: .now() + max(0, delay), execute: item)
        return { item.cancel() }
    }
}

/// Carries a click gesture out over time without ever waiting on the event tap thread.
///
/// The first steps are posted on the caller's thread; anything later is posted from a timer. One lock covers the
/// gesture's state and the posting, so a timer that was called off but is already running can't slip an event in
/// between a newer gesture's, and a call-off never returns before the events it was racing have been posted.
final class ClickScheduler: @unchecked Sendable {
    typealias Post = @Sendable (ClickStep, CGPoint, CGEventFlags) -> Void

    private struct State {
        var sequencer = ClickSequencer()
        /// Taken once when the gesture starts, so every event of it lands where the trigger was pressed.
        var location = CGPoint.zero
        var flags = CGEventFlags()
        var cancelTimer: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let clock: any ClickClock
    private let post: Post

    init(clock: any ClickClock = SystemClickClock(), post: @escaping Post) {
        self.clock = clock
        self.post = post
    }

    /// Whether a gesture still has steps to post or a press to release.
    var isActive: Bool { state.withLock { $0.sequencer.isActive } }

    /// Starts a gesture and posts whatever is due straight away. A gesture still under way is finished first.
    func start(_ plan: ClickPlan, timing: ClickTiming, at location: CGPoint, flags: CGEventFlags) {
        state.withLock { state in
            finish(&state)
            state.location = location
            state.flags = flags
            let due = state.sequencer.begin(plan, timing: timing, now: clock.now)
            emit(due, state)
            arm(&state)
        }
    }

    /// Calls the gesture off. What hasn't been posted is dropped; a press that has been gets its release.
    func cancel() {
        state.withLock { finish(&$0) }
    }

    /// Call with the lock held.
    private func finish(_ state: inout State) {
        state.cancelTimer?()
        state.cancelTimer = nil
        emit(state.sequencer.cancel(), state)
    }

    /// Call with the lock held.
    private func emit(_ steps: [ClickStep], _ state: State) {
        for step in steps { post(step, state.location, state.flags) }
    }

    /// Sets a timer for the next step, if there is one. Call with the lock held.
    private func arm(_ state: inout State) {
        state.cancelTimer = nil
        guard let due = state.sequencer.nextDue else { return }
        let generation = state.sequencer.generation
        state.cancelTimer = clock.schedule(after: max(0, due - clock.now)) { [weak self] in self?.fire(generation) }
    }

    private func fire(_ generation: UInt64) {
        state.withLock { state in
            // A gesture that was called off or replaced leaves its timer behind; it must not touch the new one.
            guard state.sequencer.generation == generation else { return }
            state.cancelTimer = nil
            emit(state.sequencer.advance(to: clock.now), state)
            arm(&state)
        }
    }
}
