import Foundation

/// Opt-in for a left/right wheel mapping: also act on a mouse's smooth (continuous) horizontal scrolling, once
/// per burst, instead of only on discrete notches.
public struct ContinuousWheelInput: Equatable, Sendable {
    /// Pixels of movement in one direction, within one burst, before the action fires. Smooth scrolling is
    /// measured in pixels only; line counts are never mixed in.
    public var distance: Double

    public static let distanceRange: ClosedRange<Double> = 10...500
    public static let defaultDistance: Double = 60

    public init(distance: Double = ContinuousWheelInput.defaultDistance) {
        self.distance = distance
    }

    /// The distance after clamping, so odd saved values can't make the mapping fire on every sample or never.
    public var effectiveDistance: Double { Self.distanceRange.clamp(distance) }
}

/// Recognises one action per directional burst in a mouse's continuous horizontal stream.
///
/// Movement in one direction adds up (`points`, never mixed with lines) until it reaches the activation
/// distance, which fires once and latches the direction. The rest of the burst is consumed without firing.
/// Recognition starts afresh on reversal, a change of modifiers, a pause of `EventProcessor.wheelBurstGap`,
/// or `reset()`. State is kept per device and resolved profile, so interleaved devices never share it.
struct HorizontalStream: Sendable {
    enum Outcome: Equatable, Sendable {
        /// Movement taken in without an action yet, or after one (the burst is already handled).
        case consume
        /// The activation distance was just reached.
        case fire
    }

    /// Streams kept at once; older ones are dropped, which only ever restarts a burst.
    static let capacity = 16

    private struct Key: Hashable, Sendable {
        var device: String
        var profile: String
    }

    private struct State: Sendable {
        var direction: WheelDirection
        var modifiers: ModifierSet
        var travelled = 0.0
        var latched = false
        var lastSample: TimeInterval
    }

    private var states: [Key: State] = [:]

    mutating func reset() {
        states.removeAll()
    }

    /// Forgets a device's recognition, e.g. when its input stops being a clear mapped stream.
    mutating func cancel(device: String, profile: String) {
        states[Key(device: device, profile: profile)] = nil
    }

    mutating func feed(
        points: Double,
        direction: WheelDirection,
        modifiers: ModifierSet,
        distance: Double,
        device: String,
        profile: String,
        at time: TimeInterval
    ) -> Outcome {
        let key = Key(device: device, profile: profile)
        var state = State(direction: direction, modifiers: modifiers, lastSample: time)
        if let known = states[key], known.direction == direction, known.modifiers == modifiers,
           time >= known.lastSample, time - known.lastSample < EventProcessor.wheelBurstGap {
            state = known
            state.lastSample = time
        }
        defer {
            if states[key] == nil, states.count >= Self.capacity { states.removeAll() }
            states[key] = state
        }
        if state.latched { return .consume }
        state.travelled += abs(points)
        guard state.travelled >= distance else { return .consume }
        state.latched = true
        state.travelled = distance
        return .fire
    }
}
