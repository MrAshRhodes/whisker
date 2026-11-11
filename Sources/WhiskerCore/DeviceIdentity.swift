import Foundation

/// A stable name for a mouse: `vendor:product` in hex, plus the serial number when the device reports one.
public struct DeviceIdentity: Hashable, Sendable, Identifiable, CustomStringConvertible {
    public var vendorID: Int
    public var productID: Int
    public var serial: String?

    public init(vendorID: Int, productID: Int, serial: String? = nil) {
        self.vendorID = vendorID
        self.productID = productID
        let trimmed = serial?.trimmingCharacters(in: .whitespacesAndNewlines)
        self.serial = (trimmed?.isEmpty ?? true) ? nil : trimmed
    }

    /// Parses `vvvv:pppp` or `vvvv:pppp:serial`.
    public init?(id: String) {
        let parts = id.split(separator: ":", maxSplits: 2, omittingEmptySubsequences: false)
        guard parts.count >= 2,
              parts[0].count == 4, parts[1].count == 4,
              let vendor = Int(parts[0], radix: 16), let product = Int(parts[1], radix: 16)
        else { return nil }
        if parts.count == 3 {
            guard !parts[2].isEmpty else { return nil }
            self.init(vendorID: vendor, productID: product, serial: String(parts[2]))
        } else {
            self.init(vendorID: vendor, productID: product)
        }
    }

    public var id: String {
        let base = String(format: "%04x:%04x", vendorID & 0xFFFF, productID & 0xFFFF)
        return serial.map { "\(base):\($0)" } ?? base
    }

    public var description: String { id }

    /// The name to show for a device, falling back to its ids when it doesn't have a product name.
    public static func displayName(product: String?, vendorID: Int, productID: Int) -> String {
        if let product = product?.trimmingCharacters(in: .whitespacesAndNewlines), !product.isEmpty {
            return product
        }
        return String(format: "Mouse %04X:%04X", vendorID & 0xFFFF, productID & 0xFFFF)
    }

    public static let appleVendorID = 0x05AC

    /// Trackpads and touch mice keep their own gestures and settings, so Whisker leaves them alone.
    public static func isExcluded(transport: String?, product: String?, vendorID: Int) -> Bool {
        excludedKind(transport: transport, product: product, vendorID: vendorID) != nil
    }

    public static func excludedKind(transport: String?, product: String?, vendorID: Int) -> ExcludedDeviceKind? {
        let product = product?.lowercased() ?? ""
        if vendorID == appleVendorID, product.contains("magic mouse") { return .touchMouse }
        let transport = transport?.uppercased() ?? ""
        if transport == "FIFO" || transport == "SPI" || product.contains("trackpad") { return .trackpad }
        return nil
    }
}

/// Why a pointing device is left alone.
public enum ExcludedDeviceKind: String, Hashable, Sendable {
    case trackpad, touchMouse

    /// What the Devices list says about it.
    public var listLabel: String {
        switch self {
        case .trackpad: return "Trackpad — left alone"
        case .touchMouse: return "Touch mouse — left alone"
        }
    }
}

/// Which device a mouse event came from. Exact when the device was seen reporting the event,
/// inferred when there is only one mouse to blame.
public struct DeviceAttribution: Equatable, Sendable {
    public var id: String
    public var exact: Bool

    public init(id: String, exact: Bool) {
        self.id = id
        self.exact = exact
    }
}

/// Matches tapped events to the device whose HID report arrived just before them.
///
/// The HID callback records each report; the event tap asks which device reported within the window.
public struct DeviceAttributor: Sendable {
    public static let window: TimeInterval = 0.03
    public static let capacity = 32

    public enum ReportKind: Sendable, Equatable {
        case button(Int)
        case wheel
    }

    private struct Report: Sendable {
        var deviceID: String
        var kind: ReportKind
        var time: TimeInterval
    }

    private var reports: [Report] = []
    /// Devices currently connected and not excluded.
    public var connected: [String] = []

    public init(connected: [String] = []) {
        self.connected = connected
    }

    public mutating func record(deviceID: String, kind: ReportKind, at time: TimeInterval) {
        reports.append(Report(deviceID: deviceID, kind: kind, time: time))
        if reports.count > Self.capacity { reports.removeFirst(reports.count - Self.capacity) }
    }

    /// The most recent device reporting `kind` within the window before `time`; otherwise the only
    /// connected mouse, if there is just one.
    public func attribute(kind: ReportKind, at time: TimeInterval) -> DeviceAttribution? {
        if let report = reports.last(where: { $0.kind == kind && time - $0.time <= Self.window && $0.time <= time + Self.window }) {
            return DeviceAttribution(id: report.deviceID, exact: true)
        }
        if connected.count == 1, let only = connected.first {
            return DeviceAttribution(id: only, exact: false)
        }
        return nil
    }
}

/// Apps in the order they were last active, most recent first, for the switch-app actions.
public struct AppSwitchHistory: Equatable, Sendable {
    public static let capacity = 16
    public private(set) var bundleIDs: [String] = []

    public init(_ bundleIDs: [String] = []) {
        for id in bundleIDs.reversed() { activated(id) }
    }

    public mutating func activated(_ bundleID: String) {
        bundleIDs.removeAll { $0 == bundleID }
        bundleIDs.insert(bundleID, at: 0)
        if bundleIDs.count > Self.capacity { bundleIDs.removeLast(bundleIDs.count - Self.capacity) }
    }

    public mutating func terminated(_ bundleID: String) {
        bundleIDs.removeAll { $0 == bundleID }
    }

    /// The app to switch to: `.next` is the previously used app, `.previous` the least recently used one.
    /// `running` filters out apps that have quit since.
    public func target(_ direction: AppSwitchDirection, running: Set<String>? = nil) -> String? {
        let candidates = bundleIDs.dropFirst().filter { running?.contains($0) ?? true }
        switch direction {
        case .next: return candidates.first
        case .previous: return candidates.last
        }
    }
}
