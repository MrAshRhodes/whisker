import Foundation

/// One shortcut of a sequence and how long to wait before the next one.
public struct SequenceStep: Hashable, Sendable {
    public var shortcut: KeyShortcut
    /// Milliseconds to wait after this step before the next. The last step's delay is never waited.
    public var delayAfterMs: Int

    public init(shortcut: KeyShortcut, delayAfterMs: Int = 0) {
        self.shortcut = shortcut
        self.delayAfterMs = delayAfterMs
    }

    public var delayAfter: TimeInterval { Double(delayAfterMs) / 1000 }
}

extension SequenceStep: Codable {
    private enum CodingKeys: String, CodingKey {
        case keyCode, modifiers, delayAfterMs
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        self.init(
            shortcut: KeyShortcut(
                keyCode: try c.decode(UInt16.self, forKey: .keyCode),
                modifiers: try c.decodeIfPresent(ModifierSet.self, forKey: .modifiers) ?? []
            ),
            delayAfterMs: try c.decodeIfPresent(Int.self, forKey: .delayAfterMs) ?? 0
        )
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(shortcut.keyCode, forKey: .keyCode)
        try c.encode(shortcut.modifiers, forKey: .modifiers)
        try c.encode(delayAfterMs, forKey: .delayAfterMs)
    }
}

/// The bounds a sequence has to stay within, for the editor and for settings files alike.
public enum ShortcutSequenceLimits {
    public static let stepCount = 2...16
    public static let delayMs = 0...2000
    /// The delays between steps added together. The last step's delay isn't waited, so it isn't counted.
    public static let totalDelayMs = 10_000

    /// The time the waits between steps add up to.
    public static func totalDelayMs(of steps: [SequenceStep]) -> Int {
        steps.dropLast().reduce(0) { $0 + max(0, $1.delayAfterMs) }
    }

    /// Why a sequence can't be used, or nil when it is within the limits.
    public static func problem(with steps: [SequenceStep]) -> String? {
        guard stepCount.contains(steps.count) else {
            return "A shortcut sequence needs \(stepCount.lowerBound) to \(stepCount.upperBound) shortcuts."
        }
        if let bad = steps.first(where: { $0.shortcut.keyCode >= 0x80 }) {
            return "Key code \(bad.shortcut.keyCode) is not a key."
        }
        guard steps.allSatisfy({ delayMs.contains($0.delayAfterMs) }) else {
            return "Each delay must be \(delayMs.lowerBound) to \(delayMs.upperBound) ms."
        }
        guard totalDelayMs(of: steps) <= totalDelayMs else {
            return "The delays add up to more than \(totalDelayMs / 1000) seconds."
        }
        return nil
    }
}

/// An application instance as the sequence saw it when it started: the process, and how many times an app
/// has come to the front since Whisker began watching. Leaving an app and coming back is a new activation.
public struct ApplicationInstance: Hashable, Sendable {
    public var processID: Int32
    public var activation: UInt64

    public init(processID: Int32, activation: UInt64) {
        self.processID = processID
        self.activation = activation
    }
}

/// Why a running sequence stopped before its last step.
public enum SequenceStop: Equatable, Sendable {
    /// The same mapping was used again while it ran.
    case retriggered
    case applicationChanged
    /// The app in front couldn't be identified when the sequence started.
    case unknownApplication
    /// A key or modifier is physically held in a way that would change what a step does.
    case physicalKeys
    /// The system wouldn't create a step's events.
    case eventFailure
    /// Settings changed, Whisker was turned off or bypassed, the tap was reset, the Mac slept or Whisker quit.
    case lifecycle
    case userCancelled

    /// Whether the person should be told (a sound and a log line) rather than it being their own doing.
    public var needsFeedback: Bool {
        switch self {
        case .unknownApplication, .physicalKeys, .eventFailure: return true
        case .retriggered, .applicationChanged, .lifecycle, .userCancelled: return false
        }
    }
}

public enum SequenceActivation: Equatable, Sendable {
    case start
    /// The same mapping is already running, so this activation ends it.
    case cancelRunning
    /// Another sequence is running; one never queues behind another.
    case ignored
}

/// Where a running sequence is. Pure: it decides what happens next and the app shell does it.
public struct ShortcutSequenceState: Sendable {
    public private(set) var steps: [SequenceStep] = []
    public private(set) var next = 0
    /// Changes whenever a sequence starts or stops, so a timer left over from an earlier one can tell.
    public private(set) var generation: UInt64 = 0

    public init() {}

    public var isRunning: Bool { next < steps.count }

    /// What an activation of the mapping that carries `steps` does now.
    public func activation(of steps: [SequenceStep]) -> SequenceActivation {
        guard isRunning else { return .start }
        return steps == self.steps ? .cancelRunning : .ignored
    }

    public mutating func begin(_ steps: [SequenceStep]) {
        generation &+= 1
        self.steps = steps
        next = 0
    }

    /// The step to post now, or nil when nothing is left.
    public var current: SequenceStep? { isRunning ? steps[next] : nil }

    /// Marks the current step posted. Returns how long to wait before the next, or nil after the last step.
    public mutating func completeStep() -> TimeInterval? {
        guard let step = current else { return nil }
        next += 1
        return isRunning ? step.delayAfter : nil
    }

    public mutating func stop() {
        guard isRunning else { return }
        generation &+= 1
        steps = []
        next = 0
    }
}

/// Whether the keys held on the keyboard right now allow a step to be posted as it is.
public enum SequencePhysicalCheck {
    /// A step's events carry exactly its own modifiers, so a held modifier the step doesn't include would
    /// make an app see a different shortcut from the one that was set, and a step's key that is already
    /// held would arrive as a key that was never let go. Either refuses the step.
    public static func allows(_ step: SequenceStep, heldModifiers: ModifierSet, keyIsHeld: Bool) -> Bool {
        guard !keyIsHeld else { return false }
        return step.shortcut.modifiers.withoutFunction.isSuperset(of: heldModifiers.withoutFunction)
    }
}
