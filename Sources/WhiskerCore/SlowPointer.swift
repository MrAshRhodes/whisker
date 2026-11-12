import Foundation

/// A begin/end update contains the whole overlay, so a newer release supersedes every queued start.
public struct SlowPointerCommand: Equatable, Sendable {
    public var generation: UInt64
    public var factors: [String: Double]
    /// Stable through overlapping holds; changes after the last hold ends, even if its end is coalesced.
    public var sessions: [String: UInt64]

    public init(generation: UInt64, factors: [String: Double], sessions: [String: UInt64]? = nil) {
        self.generation = generation
        self.factors = factors
        self.sessions = sessions ?? factors.mapValues { _ in generation }
    }
}

public enum SlowPointer {
    public static let factorRange: ClosedRange<Double> = 0.1...0.9

    public static func isValid(_ factor: Double) -> Bool {
        factor.isFinite && factorRange.contains(factor)
    }

    public static func applying(_ factor: Double, to baseline: PointerSettings) -> PointerSettings {
        guard isValid(factor) else { return baseline }
        var result = baseline
        result.speed = PointerMath.speedRange.clamp(baseline.speed * factor)
        return result
    }
}

/// Owns physical presses, including cancelled ones whose releases must still be consumed.
public struct SlowPointerHolds: Sendable {
    private struct Owner: Hashable, Sendable {
        var device: String
        var button: Int
    }

    private var pressed: Set<Owner> = []
    private var active: [Owner: Double] = [:]
    private var sessions: [String: UInt64] = [:]
    public private(set) var command = SlowPointerCommand(generation: 0, factors: [:])

    public init() {}

    public func owns(button: Int, device: DeviceAttribution?) -> Bool {
        guard let device, device.exact else { return false }
        return pressed.contains(Owner(device: device.id, button: button))
    }

    public mutating func begin(button: Int, device: DeviceAttribution?, factor: Double, available: Set<String>) -> Bool {
        guard let device, device.exact, available.contains(device.id), SlowPointer.isValid(factor) else { return false }
        let owner = Owner(device: device.id, button: button)
        guard pressed.insert(owner).inserted else { return true }
        if !active.keys.contains(where: { $0.device == device.id }) {
            sessions[device.id] = command.generation &+ 1
        }
        active[owner] = factor
        publish()
        return true
    }

    public mutating func end(button: Int, device: DeviceAttribution?) -> Bool {
        guard let device, device.exact else {
            // A missed attribution must not leave the pointer slow indefinitely. Do not guess its owner.
            if pressed.contains(where: { $0.button == button }) { cancel() }
            return false
        }
        let owner = Owner(device: device.id, button: button)
        guard pressed.remove(owner) != nil else { return false }
        active[owner] = nil
        publish()
        return true
    }

    public mutating func cancel(unlessAvailable available: Set<String> = []) {
        active = active.filter { available.contains($0.key.device) }
        publish()
    }

    private mutating func publish() {
        var factors: [String: Double] = [:]
        for (owner, factor) in active {
            factors[owner.device] = min(factors[owner.device] ?? 1, factor)
        }
        sessions = sessions.filter { factors[$0.key] != nil }
        command = SlowPointerCommand(generation: command.generation &+ 1, factors: factors, sessions: sessions)
    }
}
