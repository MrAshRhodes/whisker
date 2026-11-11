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
    /// Pixels the system scrolls per line.
    public static let pointsPerLine: Double = 10
    /// Notches per second above which acceleration starts.
    public static let accelerationThreshold: Double = 4
    /// Window over which the notch rate is measured.
    public static let rateWindow: TimeInterval = 0.2

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
