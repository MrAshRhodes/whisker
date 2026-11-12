import Foundation

/// Whether Whisker may act on a device it classifies as excluded. Decision for issue #29: touch mice
/// (Magic Mouse) and trackpads stay left alone. Nothing here is wired to the event engine, so no setting,
/// toggle or remapping path exists; the policy states today's behaviour and what any future opt-in must meet.
public enum TouchInputPolicy {
    /// How sure the event's source device is. Only `.exact` can ever count towards an opt-in.
    public enum Attribution: Equatable, Sendable {
        /// The device was seen reporting this event and nothing else could have.
        case exact
        /// Guessed, for instance because it is the only connected mouse.
        case inferred
        /// More than one device could have produced it.
        case conflicting
        case unavailable
    }

    /// Hardware evidence that ordinary button events are independent of native gestures on a model.
    /// No model has been verified, so callers have nothing to pass but `.unverified`.
    public enum CapabilityEvidence: Equatable, Sendable {
        case unverified
        case verified
    }

    public enum Decision: Equatable, Sendable {
        /// Ordinary (non-excluded) device: the usual rules apply.
        case notExcluded
        case leftAlone(Reason)
        /// Reserved for a future opt-in; `decide` returns it only for a touch mouse meeting every condition.
        case buttonsEligible
    }

    public enum Reason: Equatable, Sendable {
        case trackpad
        case noOptIn
        case attributionNotExact
        case capabilityUnverified
    }

    /// Scroll events are never reinterpreted: continuous, phase-bearing, momentum and unclassified scroll
    /// from an excluded device pass through unchanged, and touch scrolling is never turned into notches.
    public static func scrollIsPassedThrough(from kind: ExcludedDeviceKind?) -> Bool { kind != nil }

    /// The first failing condition wins; trackpads are never eligible whatever else is true.
    public static func decide(
        kind: ExcludedDeviceKind?, optedIn: Bool = false, attribution: Attribution = .unavailable,
        capability: CapabilityEvidence = .unverified
    ) -> Decision {
        switch kind {
        case nil: return .notExcluded
        case .trackpad: return .leftAlone(.trackpad)
        case .touchMouse:
            if !optedIn { return .leftAlone(.noOptIn) }
            if attribution != .exact { return .leftAlone(.attributionNotExact) }
            if capability != .verified { return .leftAlone(.capabilityUnverified) }
            return .buttonsEligible
        }
    }
}
