import Foundation

/// Pointer speed and acceleration, as written to a device's HID event service.
public enum PointerMath {
    public static let speedRange: ClosedRange<Double> = 0.1...5
    public static let accelerationRange: ClosedRange<Double> = 0...3
    /// Resolution macOS assumes for a mouse that doesn't report one, in counts per inch.
    public static let standardResolution: Double = 400
    public static let resolutionRange: ClosedRange<Double> = 10...2000
    /// A speed change beyond this factor is applied provisionally and reverted unless confirmed.
    public static let confirmationFactor: Double = 2
    public static let confirmationTimeout: TimeInterval = 5

    /// `HIDPointerResolution` for a speed multiplier. The system divides movement by the resolution, so a
    /// lower value is faster. `nativeResolution` is the device's own value, when it reports one.
    public static func resolution(forSpeed speed: Double, nativeResolution: Double? = nil) -> Double {
        let base = nativeResolution.flatMap { $0 > 0 ? $0 : nil } ?? standardResolution
        let clampedSpeed = speedRange.clamp(speed)
        return resolutionRange.clamp((base / clampedSpeed).rounded())
    }

    /// The speed multiplier a resolution corresponds to, the inverse of `resolution(forSpeed:)`.
    public static func speed(forResolution resolution: Double, nativeResolution: Double? = nil) -> Double {
        let base = nativeResolution.flatMap { $0 > 0 ? $0 : nil } ?? standardResolution
        guard resolution > 0 else { return 1 }
        return speedRange.clamp(base / resolution)
    }

    /// `HIDMouseAcceleration`: -1 turns acceleration off entirely.
    public static func acceleration(_ value: Double, linear: Bool) -> Double {
        linear ? -1 : min(accelerationRange.clamp(value), 99)
    }

    /// IOKit's 16.16 fixed-point format.
    public static func ioFixed(_ value: Double) -> Int32 {
        let scaled = (value * 65536).rounded()
        return Int32(max(Double(Int32.min), min(Double(Int32.max), scaled)))
    }

    public static func fromIOFixed(_ value: Int64) -> Double {
        Double(value) / 65536
    }

    /// Whether moving from the last confirmed speed to `new` is big enough to need confirming.
    public static func needsConfirmation(confirmed: Double, new: Double) -> Bool {
        new > confirmed * confirmationFactor
    }
}

/// Wheel distance in event mode (rewriting events in the tap).
public enum ScrollMath {
    public static let linesRange = 1...20
    public static let accelerationRange: ClosedRange<Double> = 0...1
    /// What a held modifier can multiply the wheel distance by. Starts narrow: widening the range later keeps
    /// every saved setting valid, so settle the limits by trying it out on real hardware.
    public static let multiplierRange: ClosedRange<Double> = 0.25...8
    /// Pixels the system scrolls per line.
    public static let pointsPerLine: Double = 10
    /// Notches per second above which acceleration starts.
    public static let accelerationThreshold: Double = 4
    /// Window over which the notch rate is measured.
    public static let rateWindow: TimeInterval = 0.2
    /// Most lines a scaled event carries on one axis, so odd input can't overflow the event fields.
    public static let maxScaledLines = 1000
    /// How long the part of a scaled notch that doesn't fit a whole line waits for the next notch before it is dropped.
    public static let remainderMemory: TimeInterval = 1

    /// Lines for one notch: `L × (1 + k × max(0, rate − 4))`, rounded, at least `L`.
    public static func effectiveLines(base: Int, acceleration: Double, rate: Double) -> Int {
        let lines = Double(base) * (1 + accelerationRange.clamp(acceleration) * max(0, rate - accelerationThreshold))
        return max(base, Int(lines.rounded()))
    }

    /// Notches per second over the last `rateWindow`, given notch times in seconds (including the current one).
    /// A lone notch has no rate.
    public static func notchRate(times: [TimeInterval], now: TimeInterval) -> Double {
        let recent = times.filter { now - $0 <= rateWindow && $0 <= now }
        return Double(max(0, recent.count - 1)) / rateWindow
    }
}

/// Scales wheel notches by a `ModifierScaling` while its modifiers are held.
///
/// A notch can't carry less than a whole line or pixel, so what doesn't fit (a quarter of a line at 0.25×) is
/// kept and added to the next notch in the same direction rather than rounded up or lost. Each device keeps
/// its own leftovers, separately for each axis, and drops them when the wheel reverses, the modifier is let
/// go, the profile or its scaling changes, the wheel rests for `ScrollMath.remainderMemory`, or on `reset()`.
struct ScrollScaler: Sendable {
    /// What was left over after the last notch, in lines and in pixels.
    private struct Leftover: Sendable {
        var lines = 0.0
        var points = 0.0
    }

    private struct Memory: Sendable {
        var profile: String
        var scaling: ModifierScaling
        var lastNotch: TimeInterval
        var vertical = Leftover()
        var horizontal = Leftover()
    }

    /// Keyed by device id; nil is an event that couldn't be attributed to a device.
    private var memory: [String?: Memory] = [:]

    mutating func reset() {
        memory.removeAll()
    }

    /// The scaled sample, or nil when nothing was scaled: no scaling, its modifiers not held, a speed of 1 or
    /// no movement on a covered axis. Not scaling also drops the device's leftovers, so letting go of the
    /// modifier leaves no delayed movement.
    mutating func scale(
        _ sample: ScrollSample,
        by scaling: ModifierScaling?,
        held: ModifierSet,
        device: String?,
        profile: String,
        at time: TimeInterval
    ) -> ScrollSample? {
        guard let scaling else {
            memory[device] = nil
            return nil
        }
        let required = scaling.modifiers.withoutFunction
        let factor = ScrollMath.multiplierRange.clamp(scaling.multiplier)
        guard !required.isEmpty, held.isSuperset(of: required), factor != 1 else {
            memory[device] = nil
            return nil
        }

        var state = Memory(profile: profile, scaling: scaling, lastNotch: time)
        if let known = memory[device], known.profile == profile, known.scaling == scaling,
           time >= known.lastNotch, time - known.lastNotch <= ScrollMath.remainderMemory {
            state = known
        }

        var scaled = sample
        var changed = false
        if scaling.axes.includesVertical, !sample.vertical.isZero {
            scaled.vertical = Self.scaled(sample.vertical, by: factor, leftover: &state.vertical)
            changed = true
        }
        if scaling.axes.includesHorizontal, !sample.horizontal.isZero {
            scaled.horizontal = Self.scaled(sample.horizontal, by: factor, leftover: &state.horizontal)
            changed = true
        }
        guard changed else { return nil }
        state.lastNotch = time
        memory[device] = state
        return scaled
    }

    private static func scaled(_ axis: ScrollAxis, by factor: Double, leftover: inout Leftover) -> ScrollAxis {
        let maxLines = Double(ScrollMath.maxScaledLines)
        let maxPoints = maxLines * ScrollMath.pointsPerLine
        let lines = wholeUnits(of: Double(axis.lines) * factor, leftover: &leftover.lines, limit: maxLines)
        let points = wholeUnits(of: axis.points * factor, leftover: &leftover.points, limit: maxPoints)
        let fixed = axis.fixed * factor
        return ScrollAxis(
            lines: Int(lines),
            fixed: fixed.isFinite ? min(max(fixed, -maxLines), maxLines) : 0,
            points: points
        )
    }

    /// Adds `amount` to the leftover and returns the whole units, keeping the fraction for next time.
    private static func wholeUnits(of amount: Double, leftover: inout Double, limit: Double) -> Double {
        guard amount.isFinite else { return 0 }
        let amount = min(max(amount, -limit), limit)
        if amount != 0, leftover != 0, (amount < 0) != (leftover < 0) { leftover = 0 }
        // Rounding to a millionth keeps sums such as ten tenths from landing just short of one.
        let total = ((leftover + amount) * 1_000_000).rounded() / 1_000_000
        let whole = total.rounded(.towardZero)
        leftover = total - whole
        return whole
    }
}
