import Foundation

/// Two buttons of one mouse pressed together. The event tap holds back an eligible first press for at most
/// `pressWindow`, and only for a Bluetooth mouse it can tell apart from every other connected mouse.
public struct ButtonChord: Equatable, Sendable, Codable {
    public static let windowRange = 20...200
    public static let defaultWindow = 75

    public var first: Int
    public var second: Int
    public var modifiers: ModifierSet
    public var action: Action
    /// Milliseconds; provisional, not a hardware-verified usability recommendation.
    public var pressWindow: Int

    public init(first: Int, second: Int, modifiers: ModifierSet = [], action: Action,
                pressWindow: Int = Self.defaultWindow) {
        self.first = first
        self.second = second
        self.modifiers = modifiers
        self.action = action
        self.pressWindow = pressWindow
    }

    public static func middleClick(modifiers: ModifierSet = []) -> Self {
        Self(first: 0, second: 1, modifiers: modifiers, action: .click(button: 2, modifiers: []))
    }

    public func contains(_ button: Int) -> Bool { first == button || second == button }

    public var summary: String {
        "\(Trigger.buttonTitle(first)) + \(Trigger.buttonTitle(second)) → \(action.summary)"
    }

    public func problem(allowPrimary: Bool) -> String? {
        guard Trigger.buttonRange.contains(first), Trigger.buttonRange.contains(second), first != second else {
            return "A chord needs two distinct buttons numbered 0 to 31."
        }
        guard !contains(0) || !modifiers.withoutFunction.isEmpty || allowPrimary else {
            return "A primary-button chord needs keyboard modifiers or Allow remapping the primary button in General."
        }
        guard Self.windowRange.contains(pressWindow) else { return "The chord press window must be 20 to 200 ms." }
        guard action.allowedInChords else { return "\(action.kind.title) can't be a chord action." }
        return WhiskerSettings.problem(with: action)
    }

    /// Reject shared buttons even with different modifiers: changing modifiers while held must not arbitrate a
    /// three-button sequence. Lists replace inherited lists, rather than merging competing pairs.
    public static func problem(in chords: [Self], allowPrimary: Bool) -> String? {
        var used = Set<Int>()
        for chord in chords {
            if let problem = chord.problem(allowPrimary: allowPrimary) { return problem }
            guard !used.contains(chord.first), !used.contains(chord.second) else {
                return "Chord pairs must not overlap."
            }
            used.insert(chord.first)
            used.insert(chord.second)
        }
        return nil
    }

    private enum CodingKeys: String, CodingKey { case first, second, modifiers, action, pressWindow }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        first = try c.decode(Int.self, forKey: .first)
        second = try c.decode(Int.self, forKey: .second)
        modifiers = try c.decodeIfPresent(ModifierSet.self, forKey: .modifiers) ?? []
        action = try c.decode(Action.self, forKey: .action)
        pressWindow = try c.decodeIfPresent(Int.self, forKey: .pressWindow) ?? Self.defaultWindow
    }
}

extension Action {
    public var allowedInChords: Bool {
        if case .click = self { return true }
        return allowedInGestures
    }
}

public enum ButtonChordAvailability {
    public static let explanation = "Chords need Input Monitoring and a Bluetooth mouse Whisker can tell apart from every other connected mouse. USB mice, receivers and two mice of the same model pass presses through unchanged."
    public static func latency(_ chord: ButtonChord) -> String {
        "A single click of \(Trigger.buttonTitle(chord.first)) or \(Trigger.buttonTitle(chord.second)) waits up to \(chord.pressWindow) ms for its partner."
    }
}

/// Never a model/settings identifier. The adapter mints a fresh token for each physical connection, and
/// supplies nil when a receiver, missing report or ambiguous report cannot identify that connection.
public struct ChordConnection: Hashable, Sendable {
    public let token: UInt64
    public init(token: UInt64) { self.token = token }
}

public enum ChordPhase: Equatable, Sendable { case down, up, drag }

/// Payload is deliberately opaque: fallback must retain the *whole* original event, not reconstruct its flags,
/// position or click count. The adapter resolves `forward` through ordinary mappings without re-entering
/// this recogniser. No Quartz event is retained or posted by the core.
public struct ChordInput<Payload: Equatable & Sendable>: Equatable, Sendable {
    public var button: Int
    public var phase: ChordPhase
    public var connection: ChordConnection?
    public var modifiers: ModifierSet
    public var time: TimeInterval
    public var payload: Payload

    public init(button: Int, phase: ChordPhase, connection: ChordConnection?, modifiers: ModifierSet = [],
                time: TimeInterval, payload: Payload) {
        self.button = button
        self.phase = phase
        self.connection = connection
        self.modifiers = modifiers
        self.time = time
        self.payload = payload
    }
}

public enum ChordEffect<Payload: Equatable & Sendable>: Equatable, Sendable {
    case forward(Payload)
    case perform(Action, ActionPhase)
    case drag(Payload, button: Int, modifiers: ModifierSet)
    case move(Payload)
}

/// Deterministic recognition model; the event tap's chord router feeds it and carries out its effects.
/// One pending event and one recognised pair globally is intentional: concurrent pairs fail open rather than
/// creating output ownership that the existing synthesiser cannot safely arbitrate.
public struct ChordRecognizer<Payload: Equatable & Sendable>: Sendable {
    public typealias Input = ChordInput<Payload>
    public typealias Effect = ChordEffect<Payload>
    private struct Press: Hashable, Sendable {
        var connection: ChordConnection
        var button: Int
    }
    private struct Pending: Sendable {
        var input: Input
        var chord: ButtonChord
        var deadline: TimeInterval
    }
    private struct Active: Sendable {
        var connection: ChordConnection
        var chord: ButtonChord
        var remaining: Set<Int>
        var holding: Bool
    }

    private var pending: Pending?
    private var active: Active?
    private var held: Set<Press> = []
    private var suppressed: Set<Press> = []
    private var lastTime: TimeInterval?
    public var deadline: TimeInterval? { pending?.deadline }
    /// The press being held back, if any.
    public var pendingPayload: Payload? { pending?.input.payload }
    /// Nothing is held back, recognised or waiting for a consumed release.
    public var isIdle: Bool { pending == nil && active == nil && suppressed.isEmpty }

    public init() {}

    /// The caller must pass false when *any* other source owns a physical or synthetic hold, or when Click Lock's primary
    /// escape must run first. This is an exclusive output lease, not merely a test of the desired target button.
    public mutating func process(_ input: Input, chords: [ButtonChord], allowPrimary: Bool = false,
                                 outputsIdle: Bool = true) -> [Effect] {
        guard input.time.isFinite, lastTime.map({ input.time >= $0 }) ?? true else {
            let effects = cancel()
            if let connection = input.connection {
                let press = Press(connection: connection, button: input.button)
                if input.phase == .down { held.insert(press) }
                if input.phase == .up { held.remove(press) }
                if suppressed.contains(press) {
                    if input.phase == .up {
                        suppressed.remove(press)
                    }
                    return effects + (input.phase == .drag ? [.move(input.payload)] : [])
                }
            }
            return effects + [.forward(input.payload)]
        }
        lastTime = input.time
        let priorHeld = held
        if let connection = input.connection {
            let press = Press(connection: connection, button: input.button)
            if input.phase == .down { held.insert(press) }
            if input.phase == .up { held.remove(press) }
            if suppressed.contains(press) {
                if input.phase == .up { suppressed.remove(press) }
                return input.phase == .drag ? [.move(input.payload)] : []
            }
        }
        var effects: [Effect] = []
        // A scheduled expiry is strict too: the exact deadline is still eligible for recognition.
        if let pending, input.time > pending.deadline {
            effects.append(.forward(pending.input.payload))
            self.pending = nil
        }
        if var active {
            if input.connection == active.connection, active.remaining.contains(input.button) {
                switch input.phase {
                case .up:
                    if active.holding { effects.append(.perform(active.chord.action, .up)) }
                    active.holding = false
                    active.remaining.remove(input.button)
                    self.active = active.remaining.isEmpty ? nil : active
                case .drag:
                    if active.holding, case .click(let button, let modifiers) = active.chord.action {
                        effects.append(.drag(input.payload, button: button, modifiers: modifiers))
                    } else {
                        effects.append(.move(input.payload))
                    }
                case .down: break
                }
                return effects
            }
            // End our hold *before* admitting another source, then consume the constituent tails.
            if active.holding {
                effects.append(.perform(active.chord.action, .up))
                active.holding = false
                self.active = active
            }
            return effects + [.forward(input.payload)]
        }
        if let pending {
            self.pending = nil
            if input.phase == .down, let connection = input.connection, connection == pending.input.connection,
               input.button != pending.input.button, pending.chord.contains(input.button),
               input.modifiers.withoutFunction == pending.chord.modifiers.withoutFunction,
               outputsIdle, ButtonChord.problem(in: chords, allowPrimary: allowPrimary) == nil,
               chords.contains(pending.chord) {
                let holding: Bool
                if case .click = pending.chord.action { holding = true } else { holding = false }
                active = Active(connection: connection, chord: pending.chord,
                                remaining: [pending.chord.first, pending.chord.second], holding: holding)
                return effects + [.perform(pending.chord.action, holding ? .down : .once)]
            }
            // Early release, drag, unknown connection, changed modifiers, or an unrelated event abandons the
            // attempt. Flushing before forwarding that event preserves global order without buffering it.
            return effects + [.forward(pending.input.payload), .forward(input.payload)]
        }
        guard input.phase == .down, let connection = input.connection, outputsIdle, priorHeld.isEmpty, suppressed.isEmpty,
              ButtonChord.problem(in: chords, allowPrimary: allowPrimary) == nil,
              let chord = chords.first(where: {
                  $0.contains(input.button) && $0.modifiers.withoutFunction == input.modifiers.withoutFunction
              }) else { return effects + [.forward(input.payload)] }
        // If a previous pending event just timed out, its held press makes priorHeld non-empty: a late second
        // button cannot become the first half of a fresh attempt.
        let deadline = input.time + Double(chord.pressWindow) / 1000
        guard deadline.isFinite, held.contains(Press(connection: connection, button: input.button)) else {
            return effects + [.forward(input.payload)]
        }
        pending = Pending(input: input, chord: chord, deadline: deadline)
        return effects
    }

    /// Schedule strictly after `deadline`, so the last eligible instant is not lost to timer ordering.
    public mutating func expire(at time: TimeInterval) -> [Effect] {
        guard time.isFinite, lastTime.map({ time >= $0 }) ?? true else { return cancel() }
        lastTime = time
        guard let pending, time > pending.deadline else { return [] }
        self.pending = nil
        return [.forward(pending.input.payload)]
    }

    /// Context/profile/app/bypass change, recording, disconnect, sleep, disable, quit and tap interruption all
    /// discard pending input; never send stale clicks to a new app. Releases only the hold owned by this model,
    /// once. Known consumed tails are suppressed until release; the adapter calls `settle()` once every button is up,
    /// so a release it could not attribute never leaves a press suppressed or held forever.
    public mutating func cancel() -> [Effect] {
        let release = active.flatMap { $0.holding ? Effect.perform($0.chord.action, .up) : nil }
        if let pending, let connection = pending.input.connection {
            suppressed.insert(Press(connection: connection, button: pending.input.button))
        }
        if let active {
            for button in active.remaining { suppressed.insert(Press(connection: active.connection, button: button)) }
        }
        pending = nil
        active = nil
        lastTime = nil
        return release.map { [$0] } ?? []
    }

    /// Every button is physically up, so whatever the recogniser still thinks is held, recognised or consumed
    /// had a release it could not attribute: forget it, letting go of a hold still owned, so nothing blocks the
    /// next attempt or swallows a later press. A pending press means a button is down, so it is left alone.
    public mutating func settle() -> [Effect] {
        guard pending == nil else { return [] }
        let release = active.flatMap { $0.holding ? Effect.perform($0.chord.action, .up) : nil }
        active = nil
        held.removeAll()
        suppressed.removeAll()
        return release.map { [$0] } ?? []
    }

    /// Only call after a physical connection has gone away. Its token must never be reused.
    public mutating func disconnect(_ connection: ChordConnection) -> [Effect] {
        let ownsSession = pending?.input.connection == connection || active?.connection == connection
        let effects = ownsSession ? cancel() : []
        held = held.filter { $0.connection != connection }
        suppressed = suppressed.filter { $0.connection != connection }
        return effects
    }
}
