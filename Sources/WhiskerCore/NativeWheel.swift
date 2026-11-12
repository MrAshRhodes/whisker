import Foundation

/// A wheel control Whisker can ask a mouse's own HID service to change.
public enum NativeWheelControl: String, CaseIterable, Sendable, Codable {
    case speed
    case acceleration
}

/// Native wheel settings for one mouse: the values Whisker asks the mouse's HID service to use. A `nil`
/// control is left to the system. Saved values stay when `enabled` is off.
public struct NativeWheelSettings: Equatable, Sendable {
    /// Off means the software scrolling settings apply, as if this section did not exist.
    public var enabled: Bool
    /// Multiplier of the mouse's own wheel speed, `NativeWheelMath.speedRange`.
    public var speed: Double?
    /// Scroll acceleration, `NativeWheelMath.accelerationRange`.
    public var acceleration: Double?

    public init(enabled: Bool = false, speed: Double? = nil, acceleration: Double? = nil) {
        self.enabled = enabled
        self.speed = speed
        self.acceleration = acceleration
    }

    /// The controls that have a value, in a fixed order.
    public var requestedControls: [NativeWheelControl] {
        var controls: [NativeWheelControl] = []
        if speed != nil { controls.append(.speed) }
        if acceleration != nil { controls.append(.acceleration) }
        return controls
    }

    /// Whether Whisker should try to apply anything: switched on with at least one value.
    public var isRequested: Bool { enabled && !requestedControls.isEmpty }
}

/// Maths for the wheel properties of a HID service. The values are 16.16 fixed point integers. How a mouse
/// responds to them has not been verified on hardware, so the formulas here are provisional and deliberately
/// separate from `PointerMath`.
public enum NativeWheelMath {
    public static let speedRange: ClosedRange<Double> = 0.25...4
    public static let accelerationRange: ClosedRange<Double> = 0...3

    /// Raw values a service may report for a control and still count as understood. Anything outside leaves
    /// the control unavailable rather than being guessed at.
    public static func plausibleOriginals(for control: NativeWheelControl) -> ClosedRange<Int64> {
        switch control {
        case .speed: return 1...Int64(ioFixed(10_000))
        // Includes -1.0, the value some drivers use for "off".
        case .acceleration: return Int64(ioFixed(-1))...Int64(ioFixed(100))
        }
    }

    /// The raw value to write for a requested setting, from the service's own typed original. Nil when the
    /// original can't be scaled sensibly.
    ///
    /// Speed divides the original resolution, as a higher resolution means more counts for the same notch.
    /// The direction is an assumption until a hardware spike confirms it.
    public static func value(for control: NativeWheelControl, setting: Double, original: Int64) -> Int64? {
        guard setting.isFinite else { return nil }
        switch control {
        case .speed:
            guard original > 0 else { return nil }
            let scaled = (Double(original) / speedRange.clamp(setting)).rounded()
            guard scaled >= 1, scaled <= Double(plausibleOriginals(for: .speed).upperBound) else { return nil }
            return Int64(scaled)
        case .acceleration:
            return Int64(ioFixed(accelerationRange.clamp(setting)))
        }
    }

    public static func ioFixed(_ value: Double) -> Int32 {
        let scaled = (value * 65536).rounded()
        return Int32(max(Double(Int32.min), min(Double(Int32.max), scaled)))
    }
}

/// How the wheel is being changed for a mouse. Native and software modes never apply together.
public enum ScrollMode: Equatable, Sendable {
    /// Nothing changes the wheel distance: macOS decides.
    case system
    /// Whisker rewrites wheel events (lines per notch and acceleration).
    case software
    /// The mouse's own HID service was changed and Whisker's software distance and acceleration are suspended.
    case native
}

public enum ScrollModeResolver {
    /// Native applies only once the hardware layer has confirmed it for the device, so a refused or ignored
    /// activation leaves the previous mode in place. The software values are kept either way.
    public static func mode(scroll: ScrollSettings, nativeActive: Bool) -> ScrollMode {
        if nativeActive { return .native }
        return scroll.linesPerNotch != nil ? .software : .system
    }
}

extension WhiskerSettings {
    /// The native wheel settings Whisker should have applied to a device right now: none while Whisker or the
    /// device is switched off, so the system's own values come back.
    public func activeNativeWheel(for deviceID: String) -> NativeWheelSettings? {
        guard general.enabled, let device = devices[deviceID], device.enabled,
              let native = device.wheel.native, native.isRequested
        else { return nil }
        return native
    }
}
