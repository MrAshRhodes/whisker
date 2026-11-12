import CoreGraphics
import Foundation
import WhiskerCore

/// What the engine allows for a press that might begin a chord: the chords of the profile it would use, and
/// whether nothing else owns a press or hold.
struct ChordGate: Sendable {
    var chords: [ButtonChord] = []
    var allowPrimary = false
    var outputsIdle = false

    static let closed = ChordGate()
}

/// The engine side of chord routing. The router calls these with its own lock held, and they may take the
/// engine's state lock; the engine never calls the router with its state lock held.
protocol ChordRouterHost: AnyObject {
    func chordGate(device: String, app: String?) -> ChordGate
    /// Ordinary handling of one event, as if chords did not exist.
    func resolve(_ event: CGEvent, _ input: InputEvent, originalClickState: Int64) -> Unmanaged<CGEvent>?
    func performChord(_ action: Action, _ phase: ActionPhase, at location: CGPoint, flags: CGEventFlags)
}

/// Runs `ChordRecognizer` on the event tap. A press that might begin a chord is swallowed and a copy kept; when
/// no chord forms, the copy goes through ordinary handling and is posted again, marked, so the tap lets it by.
///
/// Order is kept by posting: while anything the router posted hasn't come back through the tap yet, later events
/// are posted too instead of being returned, so none can overtake it. Nothing here waits or sleeps.
final class ChordRouter: @unchecked Sendable {
    /// Events posted by the router: replayed presses, events queued behind them and chord clicks.
    static let marker: Int64 = 0x5748_4B43
    /// How long posted events may take to come back before later events stop queueing behind them.
    static let fenceTimeout: TimeInterval = 0.25

    private struct Retained {
        var event: CGEvent
        var input: InputEvent
        var button: Int
        var clickState: Int64
        var rawClickState: Int64
    }

    private struct Live {
        var id: UInt64
        var event: CGEvent
        var input: InputEvent
        var clickState: Int64
    }

    weak var host: (any ChordRouterHost)?
    private let lock = NSLock()
    private let clock: any ClickClock
    private let attribute: @Sendable (Int, Bool, TimeInterval) -> ChordSource?
    private let post: @Sendable (CGEvent) -> Void

    private var engaged = false
    private var recognizer = ChordRecognizer<UInt64>()
    private var nextID: UInt64 = 0
    private var retained: [UInt64: Retained] = [:]
    /// The gate the pending press was buffered under; its partner is judged by the same one.
    private var gate = ChordGate.closed
    /// The mouse of the pending press or recognised chord, so its disconnection lets go of them.
    private var sessionDevice: String?
    /// Who pressed each Quartz button still down, oldest first; nil where the connection is unknown.
    private var owners: [Int: [ChordConnection?]] = [:]
    /// The system counted presses the router consumed, so later click counts of that button are put right.
    private var clickOffsets: [Int: Int64] = [:]
    private var inFlight = 0
    private var fenceEnds: TimeInterval = 0
    private var cancelExpiry: (@Sendable () -> Void)?
    private var armedDeadline: TimeInterval?
    private var generation: UInt64 = 0

    init(clock: any ClickClock, attribute: @escaping @Sendable (Int, Bool, TimeInterval) -> ChordSource?,
         post: @escaping @Sendable (CGEvent) -> Void) {
        self.clock = clock
        self.attribute = attribute
        self.post = post
    }

    // MARK: Lifecycle (never with the engine's state lock held)

    /// Settings changed: anything pending or held was decided under the old ones.
    func update(engaged: Bool, at location: CGPoint) {
        withLock {
            discard(at: location)
            self.engaged = engaged
        }
    }

    /// The app in front changed, recording began or the profile no longer applies: never replay a held-back press
    /// into a new context. A recognised hold is released once and the constituents' releases are swallowed.
    func cancel(at location: CGPoint) {
        withLock { discard(at: location) }
    }

    /// Sleep, quit or a tap interruption: releases may have been missed, so nothing held is trusted any more. Fails
    /// open: a later release may go through unpaired, but no later press can be swallowed as a constituent.
    func reset(at location: CGPoint) {
        withLock {
            discard(at: location)
            _ = recognizer.settle()
            owners.removeAll()
            clickOffsets.removeAll()
            inFlight = 0
        }
    }

    func devicesChanged(connected: Set<String>, at location: CGPoint) {
        withLock {
            guard let sessionDevice, !connected.contains(sessionDevice) else { return }
            discard(at: location)
        }
    }

    /// A marked event came back through the tap.
    func returned() {
        withLock { inFlight = max(0, inFlight - 1) }
    }

    // MARK: Tap thread

    func route(_ event: CGEvent, _ input: InputEvent, originalClickState: Int64) -> Unmanaged<CGEvent>? {
        lock.lock()
        defer { lock.unlock() }
        guard let host else { return Unmanaged.passUnretained(event) }
        let now = clock.now
        guard engaged || isFenced(at: now) || !recognizer.isIdle else {
            // Presses are no longer followed, so what was known about them would only go stale.
            if !owners.isEmpty || !clickOffsets.isEmpty {
                owners.removeAll()
                clickOffsets.removeAll()
            }
            return host.resolve(event, input, originalClickState: originalClickState)
        }
        let button: Int, phase: ChordPhase
        switch input.kind {
        case .buttonDown(let number): (button, phase) = (number, .down)
        case .buttonUp(let number): (button, phase) = (number, .up)
        case .buttonDragged(let number): (button, phase) = (number, .drag)
        case .scroll:
            guard !recognizer.isIdle else {
                return deliver(host.resolve(event, input, originalClickState: originalClickState), at: now)
            }
            // Any other input abandons a pending attempt; it is never a constituent.
            (button, phase) = (-1, .drag)
        }

        var input = input
        var clickState = originalClickState
        if button >= 0, let offset = clickOffsets[button] {
            if clickState > offset {
                clickState -= offset
                event.setIntegerValueField(.mouseEventClickState, value: clickState)
                input.clickCount = clickState
            } else if phase == .down {
                clickOffsets[button] = nil
            }
        }

        var connection: ChordConnection?
        var source: ChordSource?
        switch phase {
        case .down:
            source = attribute(button, true, input.timestamp)
            connection = source?.connection
        case .up:
            connection = button >= 0 ? releaseOwner(of: button, at: input.timestamp) : nil
        case .drag:
            let held = owners[button] ?? []
            connection = held.count == 1 ? held[0] : nil
        }

        var current = ChordGate.closed
        var copy: CGEvent?
        if recognizer.pendingPayload != nil {
            current = gate
        } else if phase == .down, let source, recognizer.isIdle, owners.values.allSatisfy(\.isEmpty) {
            current = host.chordGate(device: source.deviceID, app: input.app)
            if !current.chords.isEmpty {
                copy = event.copy()
                if copy == nil { current = .closed }
            }
        }
        if phase == .down { owners[button, default: []].append(connection) }

        let id = nextID
        nextID &+= 1
        let effects = recognizer.process(
            ChordInput(button: button, phase: phase, connection: connection, modifiers: input.modifiers, time: now, payload: id),
            chords: current.chords, allowPrimary: current.allowPrimary, outputsIdle: current.outputsIdle
        )
        if recognizer.pendingPayload == id, let copy {
            retained[id] = Retained(event: copy, input: input, button: button, clickState: clickState,
                                    rawClickState: originalClickState)
            gate = current
            sessionDevice = source?.deviceID
        }
        let live = Live(id: id, event: event, input: input, clickState: clickState)
        let result = carryOut(effects, live: live, at: now)
        if phase == .down, recognizer.pendingPayload != id, !effects.contains(.forward(id)) {
            clickOffsets[button] = originalClickState
        }
        if phase == .up, owners.values.allSatisfy(\.isEmpty) {
            // Every button is up: a release that could not be attributed must not block the next chord.
            _ = carryOut(recognizer.settle(), live: nil, at: now)
        }
        finish()
        return result
    }

    // MARK: Internals (lock held)

    private func withLock<T>(_ body: () -> T) -> T {
        lock.lock()
        defer { lock.unlock() }
        return body()
    }

    private func isFenced(at now: TimeInterval) -> Bool {
        if inFlight > 0, now >= fenceEnds { inFlight = 0 }
        return inFlight > 0
    }

    /// The connection a release belongs to: the only one holding that button, unless the reports disagree.
    private func releaseOwner(of button: Int, at time: TimeInterval) -> ChordConnection? {
        var held = owners[button] ?? []
        guard !held.isEmpty else { return attribute(button, false, time)?.connection }
        let reported = attribute(button, false, time)?.connection
        let owner: ChordConnection?
        let index: Int
        if held.count == 1 {
            owner = reported == nil || reported == held[0] ? held[0] : nil
            index = 0
        } else if let reported, let match = held.firstIndex(of: reported) {
            owner = reported
            index = match
        } else {
            owner = nil
            index = 0
        }
        held.remove(at: index)
        owners[button] = held.isEmpty ? nil : held
        return owner
    }

    /// Carries out the recogniser's effects in order. Returns what the tap should hand on for the live event.
    private func carryOut(_ effects: [ChordEffect<UInt64>], live: Live?, at now: TimeInterval) -> Unmanaged<CGEvent>? {
        guard let host else { return nil }
        var result: Unmanaged<CGEvent>?
        for effect in effects {
            switch effect {
            case .forward(let id):
                if let live, id == live.id {
                    result = deliver(host.resolve(live.event, live.input, originalClickState: live.clickState), at: now)
                } else if let held = retained.removeValue(forKey: id),
                          let resolved = host.resolve(held.event, held.input, originalClickState: held.clickState) {
                    send(resolved.takeUnretainedValue())
                }
            case let .perform(action, phase):
                let location = live?.event.location ?? Self.cursorLocation()
                let flags = live.map { CGEventFlags(rawValue: $0.event.flags.rawValue & Self.standardFlags) } ?? []
                perform(action, phase, at: location, flags: flags, host: host)
            case let .drag(id, button, modifiers):
                guard let live, id == live.id else { continue }
                let event = live.event
                event.type = button == 0 ? .leftMouseDragged : button == 1 ? .rightMouseDragged : .otherMouseDragged
                event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
                event.flags = CGEventFlags(rawValue: event.flags.rawValue | modifiers.eventFlags)
                result = deliver(Unmanaged.passUnretained(event), at: now)
            case .move(let id):
                guard let live, id == live.id else { continue }
                live.event.type = .mouseMoved
                result = deliver(Unmanaged.passUnretained(live.event), at: now)
            }
        }
        return result
    }

    /// Hands the live event back to the tap, unless something posted earlier is still on its way: then it is
    /// posted behind it.
    private func deliver(_ resolved: Unmanaged<CGEvent>?, at now: TimeInterval) -> Unmanaged<CGEvent>? {
        guard let resolved, isFenced(at: now) else { return resolved }
        if let copy = resolved.takeUnretainedValue().copy() { send(copy) }
        return nil
    }

    private func send(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
        inFlight += 1
        fenceEnds = clock.now + Self.fenceTimeout
        post(event)
    }

    private func perform(_ action: Action, _ phase: ActionPhase, at location: CGPoint, flags: CGEventFlags,
                         host: any ChordRouterHost) {
        guard case let .click(button, modifiers) = action else {
            host.performChord(action, phase, at: location, flags: flags)
            return
        }
        let held = CGEventFlags(rawValue: flags.rawValue | modifiers.eventFlags)
        let downs: [Bool] = switch phase {
        case .down: [true]
        case .up: [false]
        case .once: [true, false]
        }
        for down in downs {
            let type: CGEventType, mouseButton: CGMouseButton
            switch button {
            case 0: (type, mouseButton) = (down ? .leftMouseDown : .leftMouseUp, .left)
            case 1: (type, mouseButton) = (down ? .rightMouseDown : .rightMouseUp, .right)
            default: (type, mouseButton) = (down ? .otherMouseDown : .otherMouseUp, CGMouseButton(rawValue: UInt32(button)) ?? .center)
            }
            guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location,
                                      mouseButton: mouseButton) else { continue }
            event.flags = held
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            event.setIntegerValueField(.mouseEventClickState, value: 1)
            send(event)
        }
    }

    /// Drops the pending press without replaying it, and lets go of a recognised hold once.
    private func discard(at location: CGPoint) {
        let effects = recognizer.cancel()
        for held in retained.values { clickOffsets[held.button] = held.rawClickState }
        retained.removeAll()
        if let host {
            for case let .perform(action, phase) in effects { perform(action, phase, at: location, flags: [], host: host) }
        }
        finish()
    }

    /// Forgets presses no longer pending (they were recognised or replayed) and keeps the expiry timer in step.
    private func finish() {
        let pending = recognizer.pendingPayload
        for (id, held) in retained where id != pending {
            clickOffsets[held.button] = held.rawClickState
            retained[id] = nil
        }
        if recognizer.isIdle { sessionDevice = nil }
        guard let deadline = recognizer.deadline else {
            cancelExpiry?()
            cancelExpiry = nil
            armedDeadline = nil
            return
        }
        guard deadline != armedDeadline else { return }
        cancelExpiry?()
        generation &+= 1
        let expected = generation
        armedDeadline = deadline
        // Strictly after the deadline: the deadline itself still recognises.
        cancelExpiry = clock.schedule(after: max(0, deadline - clock.now) + 0.001) { [weak self] in
            self?.expire(expected)
        }
    }

    private func expire(_ expected: UInt64) {
        withLock {
            guard expected == generation else { return }
            cancelExpiry = nil
            armedDeadline = nil
            let now = clock.now
            _ = carryOut(recognizer.expire(at: now), live: nil, at: now)
            finish()
        }
    }

    private static let standardFlags = ModifierSet([.shift, .control, .option, .command]).eventFlags

    private static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }
}
