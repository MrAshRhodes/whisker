import CoreGraphics
import Foundation
import os
import WhiskerCore

/// What a sequence needs from the machine, so tests can stand in for the keyboard, the front app and the event system.
protocol SequenceEnvironment: Sendable {
    /// The app in front, or nil when it can't be told.
    func frontmostInstance() -> ApplicationInstance?
    /// The modifier keys physically held (the hardware state, not what Whisker or other apps have posted).
    func heldModifiers() -> ModifierSet
    func isKeyHeld(_ keyCode: UInt16) -> Bool
    /// Creates every event of a step ahead of posting it and returns the closure that posts them, or nil when
    /// the system won't create them, so a step is never half posted.
    func prepare(_ shortcut: KeyShortcut) -> (@Sendable () -> Void)?
}

/// Runs a keyboard shortcut sequence one step at a time, off the event tap thread.
///
/// One lock covers the state and the posting of a step, so a cancellation never lands between a step's key
/// down and key up: the step in progress is posted whole, or not at all, and nothing is ever left held. A
/// step is checked against the app in front and the physical keys immediately before it is posted; the gap
/// between that check and the post can't be closed, and delivery to the app is never confirmed.
final class ShortcutSequenceRunner: @unchecked Sendable {
    private struct State {
        var sequence = ShortcutSequenceState()
        var application: ApplicationInstance?
        var cancelTimer: (@Sendable () -> Void)?
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let clock: any ClickClock
    private let environment: any SequenceEnvironment
    private let stopped: @Sendable (SequenceStop) -> Void
    private let changed: @Sendable () -> Void

    /// `stopped` hears why a sequence ended early (it decides what is worth telling the person). `changed` is
    /// called whenever a sequence starts or ends, for the menu.
    init(
        clock: any ClickClock = SystemClickClock(),
        environment: any SequenceEnvironment,
        stopped: @escaping @Sendable (SequenceStop) -> Void,
        changed: @escaping @Sendable () -> Void = {}
    ) {
        self.clock = clock
        self.environment = environment
        self.stopped = stopped
        self.changed = changed
    }

    var isRunning: Bool { state.withLock { $0.sequence.isRunning } }

    /// An activation of a mapping. Safe on the event tap thread: it only takes the lock and sets a timer,
    /// and the first step is posted from the clock's queue.
    func activate(_ steps: [SequenceStep]) {
        let (stop, didChange) = state.withLock { state -> (SequenceStop?, Bool) in
            switch state.sequence.activation(of: steps) {
            case .ignored:
                return (nil, false)
            case .cancelRunning:
                return (end(&state, .retriggered), true)
            case .start:
                guard let application = environment.frontmostInstance() else { return (.unknownApplication, false) }
                state.application = application
                state.sequence.begin(steps)
                schedule(&state, after: 0)
                return (nil, true)
            }
        }
        if let stop { stopped(stop) }
        if didChange { changed() }
    }

    /// Calls the running sequence off; nothing further is posted. Does nothing when none is running.
    func cancel(_ reason: SequenceStop) {
        let wasRunning = state.withLock { state -> Bool in
            guard state.sequence.isRunning else { return false }
            _ = end(&state, reason)
            return true
        }
        guard wasRunning else { return }
        stopped(reason)
        changed()
    }

    /// Ends the sequence and its timer. Call with the lock held.
    private func end(_ state: inout State, _ reason: SequenceStop) -> SequenceStop {
        state.cancelTimer?()
        state.cancelTimer = nil
        state.application = nil
        state.sequence.stop()
        return reason
    }

    /// Call with the lock held.
    private func schedule(_ state: inout State, after delay: TimeInterval) {
        let generation = state.sequence.generation
        state.cancelTimer = clock.schedule(after: delay) { [weak self] in self?.fire(generation) }
    }

    private func fire(_ generation: UInt64) {
        let (stop, finished) = state.withLock { state -> (SequenceStop?, Bool) in
            // A sequence that was called off or replaced leaves its timer behind; it must not touch the new one.
            guard state.sequence.generation == generation, let step = state.sequence.current,
                  let application = state.application else { return (nil, false) }
            state.cancelTimer = nil

            if environment.frontmostInstance() != application {
                return (end(&state, .applicationChanged), false)
            }
            guard SequencePhysicalCheck.allows(
                step, heldModifiers: environment.heldModifiers(), keyIsHeld: environment.isKeyHeld(step.shortcut.keyCode)
            ) else { return (end(&state, .physicalKeys), false) }
            guard let post = environment.prepare(step.shortcut) else { return (end(&state, .eventFailure), false) }

            post()
            if let delay = state.sequence.completeStep() {
                schedule(&state, after: delay)
                return (nil, false)
            }
            state.application = nil
            return (nil, true)
        }
        if let stop { stopped(stop) }
        if stop != nil || finished { changed() }
    }
}

/// The real keyboard, front app and event system.
struct SystemSequenceEnvironment: SequenceEnvironment {
    let frontmost: @Sendable () -> ApplicationInstance?
    let marker: Int64

    func frontmostInstance() -> ApplicationInstance? { frontmost() }

    func heldModifiers() -> ModifierSet {
        ModifierSet(eventFlags: CGEventSource.flagsState(.hidSystemState).rawValue)
    }

    func isKeyHeld(_ keyCode: UInt16) -> Bool {
        CGEventSource.keyState(.hidSystemState, key: CGKeyCode(keyCode))
    }

    func prepare(_ shortcut: KeyShortcut) -> (@Sendable () -> Void)? {
        guard let down = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: true),
              let up = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: false) else { return nil }
        let flags = CGEventFlags(rawValue: shortcut.eventFlags)
        for event in [down, up] {
            event.flags = flags
            event.setIntegerValueField(.eventSourceUserData, value: marker)
        }
        let events = PreparedEvents(down: down, up: up)
        return {
            events.down.post(tap: .cghidEventTap)
            events.up.post(tap: .cghidEventTap)
        }
    }
}

/// CGEvent isn't Sendable, but these two are only touched by the closure that posts them, once, under the runner's lock.
private struct PreparedEvents: @unchecked Sendable {
    let down: CGEvent
    let up: CGEvent
}
