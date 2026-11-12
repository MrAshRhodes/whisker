import Foundation

// What the Devices pane can say about each mouse: who it is, what it reports, and how sure Whisker is about
// which clicks come from it. Everything here is derived data held in memory; nothing is saved to settings.

// MARK: - Reported controls

/// The kind of HID element a device reported. Only inputs are controls someone can use.
public enum HIDElementKind: Hashable, Sendable {
    case input, output, feature, collection, other

    /// Maps the raw value of IOKit's `IOHIDElementType`: 1 to 4 are the input kinds, 129 output, 257 feature, 513 collection.
    public init(ioKitType: Int) {
        switch ioKitType {
        case 1...4: self = .input
        case 129: self = .output
        case 257: self = .feature
        case 513: self = .collection
        default: self = .other
        }
    }
}

/// One element of a device's HID descriptor, reduced to what the controls summary reads.
public struct HIDElementInfo: Hashable, Sendable {
    public var kind: HIDElementKind
    public var usagePage: Int
    public var usage: Int

    public init(kind: HIDElementKind, usagePage: Int, usage: Int) {
        self.kind = kind
        self.usagePage = usagePage
        self.usage = usage
    }
}

/// The buttons and wheels a device says it can report.
///
/// This is what the device tells macOS, not a count of physical buttons: usages can be aliases, a physical
/// button can go unreported and a reported one may not be a button anyone can press. It is built from input
/// elements only, so collections aren't counted, and a usage appears once however often it is reported.
public struct ReportedControls: Hashable, Sendable {
    /// Whisker button numbers (the HID button usage minus one), ascending and without duplicates.
    public let buttons: [Int]
    public let verticalWheel: Bool
    public let horizontalWheel: Bool
    /// Part of the device couldn't be read, so the lists may be missing controls.
    public let isIncomplete: Bool

    public init(buttons: [Int] = [], verticalWheel: Bool = false, horizontalWheel: Bool = false, isIncomplete: Bool = false) {
        self.buttons = Set(buttons.filter(Trigger.buttonRange.contains)).sorted()
        self.verticalWheel = verticalWheel
        self.horizontalWheel = horizontalWheel
        self.isIncomplete = isIncomplete
    }

    /// Summarises the input elements of one interface. Button usages beyond what Whisker can map (1 to 32) are ignored.
    public init(elements: [HIDElementInfo]) {
        var buttons: [Int] = []
        var vertical = false, horizontal = false
        for element in elements where element.kind == .input {
            switch (element.usagePage, element.usage) {
            case (HIDUsage.buttonPage, 1...32): buttons.append(element.usage - 1)
            case (HIDUsage.genericDesktopPage, HIDUsage.wheel): vertical = true
            case (HIDUsage.consumerPage, HIDUsage.acPan): horizontal = true
            default: break
            }
        }
        self.init(buttons: buttons, verticalWheel: vertical, horizontalWheel: horizontal)
    }

    public var isEmpty: Bool { buttons.isEmpty && !verticalWheel && !horizontalWheel }

    func merged(with other: ReportedControls) -> ReportedControls {
        ReportedControls(
            buttons: buttons + other.buttons,
            verticalWheel: verticalWheel || other.verticalWheel,
            horizontalWheel: horizontalWheel || other.horizontalWheel,
            isIncomplete: isIncomplete || other.isIncomplete
        )
    }

    /// Named like the Buttons pane names them, with runs collapsed: "Primary Button, Secondary Button, Middle Button, Buttons 4–8".
    public var buttonSummary: String? {
        guard !buttons.isEmpty else { return nil }
        var parts = buttons.filter { $0 < 3 }.map(Trigger.buttonTitle)
        var run: ClosedRange<Int>?
        func flush() {
            guard let range = run else { return }
            parts.append(range.count == 1 ? "Button \(range.lowerBound + 1)" : "Buttons \(range.lowerBound + 1)–\(range.upperBound + 1)")
        }
        for number in buttons where number >= 3 {
            if let current = run, number == current.upperBound + 1 {
                run = current.lowerBound...number
            } else {
                flush()
                run = number...number
            }
        }
        flush()
        return parts.joined(separator: ", ")
    }

    public var wheelSummary: String? {
        switch (verticalWheel, horizontalWheel) {
        case (true, true): return "Vertical and horizontal wheel"
        case (true, false): return "Vertical wheel"
        case (false, true): return "Horizontal wheel"
        case (false, false): return nil
        }
    }
}

/// Why a device's controls couldn't be listed.
public enum ControlsUnavailableReason: Hashable, Sendable {
    /// Whisker didn't ask macOS: it reads a device's controls once Input Monitoring is allowed, and never asks
    /// for that just to show details.
    case inputMonitoringOff
    /// macOS gave Whisker no elements for the device.
    case notProvided
    /// The device is away, so there is nothing to read.
    case notConnected
}

/// What Whisker knows about a device's controls: the list, or that it couldn't get one. An empty list is
/// still a list; it never stands in for "unavailable", and neither is read as "zero buttons".
public enum ControlsReport: Hashable, Sendable {
    case reported(ReportedControls)
    case unavailable(ControlsUnavailableReason)

    /// The elements macOS returned for one interface. Nothing at all (nil or an empty array) means they weren't provided.
    public static func read(_ elements: [HIDElementInfo]?) -> ControlsReport {
        guard let elements, !elements.isEmpty else { return .unavailable(.notProvided) }
        return .reported(ReportedControls(elements: elements))
    }

    /// One device's controls from the reports of its interfaces. When some couldn't be read, the rest still
    /// count but the result is marked incomplete.
    public static func combine(_ reports: [ControlsReport]) -> ControlsReport {
        var controls: ReportedControls?
        var reasons: [ControlsUnavailableReason] = []
        for report in reports {
            switch report {
            case .reported(let next): controls = controls?.merged(with: next) ?? next
            case .unavailable(let reason): reasons.append(reason)
            }
        }
        guard let controls else {
            return .unavailable(reasons.contains(.inputMonitoringOff) ? .inputMonitoringOff : .notProvided)
        }
        return .reported(reasons.isEmpty ? controls : controls.merged(with: ReportedControls(isIncomplete: true)))
    }
}

// MARK: - Identification and attribution

/// Whether Whisker can listen to mouse reports to see which mouse sent a click. That is about permission and
/// availability, not about any one click: see `AttributionBasis` for what Whisker knows about a mouse.
public enum IdentificationStatus: Hashable, Sendable {
    /// Input Monitoring is allowed and Whisker is listening.
    case listening
    /// Input Monitoring isn't allowed (denied, or not asked for yet).
    case notAllowed
    /// Input Monitoring is allowed but Whisker couldn't start listening.
    case couldNotListen

    public init(accessGranted: Bool, listening: Bool) {
        self = listening ? .listening : (accessGranted ? .couldNotListen : .notAllowed)
    }

    public var title: String {
        switch self {
        case .listening: return "Allowed"
        case .notAllowed: return "Not allowed"
        case .couldNotListen: return "Allowed, but Whisker couldn't start listening"
        }
    }

    public var explanation: String {
        switch self {
        case .listening:
            return "Whisker is listening for button and wheel reports, so it can match recent clicks to the mouse that sent them. That is evidence rather than a guarantee: open a mouse's details to see how sure Whisker is."
        case .notAllowed:
            return "With one mouse, Whisker knows every click is from it. To use different settings for several mice at once, allow Input Monitoring so Whisker can see which one sent each click."
        case .couldNotListen:
            return "Input Monitoring is allowed, but Whisker couldn't start listening to your mice. With one mouse it still assumes every click is from it; with several it can't tell them apart."
        }
    }
}

/// How Whisker can tell that clicks come from a device. Separate from `IdentificationStatus`: permission can be
/// on while a mouse hasn't been used, and off while a lone mouse is still assumed to be the source.
public enum AttributionBasis: Hashable, Sendable {
    /// The device sent a button or wheel report within `AttributionEvidence.window`.
    case recentInput
    /// It is the only mouse Whisker handles, so clicks are assumed to be its.
    case inferredFromOnlyMouse
    /// Nothing ties clicks to it; the status says whether Whisker could be listening.
    case unknown(IdentificationStatus)
    /// Several connected devices report this identity, so none of them can be singled out.
    case ambiguousIdentity(devices: Int)
    /// Trackpads and touch mice aren't matched to clicks.
    case leftAlone(ExcludedDeviceKind)
    case notConnected

    public var title: String {
        switch self {
        case .recentInput: return "Recent matching input"
        case .inferredFromOnlyMouse: return "Inferred from one eligible mouse"
        case .unknown: return "Unknown"
        case .ambiguousIdentity: return "Ambiguous identity"
        case .leftAlone: return "Not matched, left alone"
        case .notConnected: return "Not connected"
        }
    }

    public var explanation: String {
        switch self {
        case .recentInput:
            return "This mouse sent a button or wheel report in the last minute. Whisker keeps only when each mouse last did, in memory, and never saves it."
        case .inferredFromOnlyMouse:
            return "It is the only mouse Whisker handles right now, so Whisker assumes clicks come from it. Nothing from the mouse itself has confirmed that."
        case .unknown(.listening):
            return "Whisker hasn't seen a button or wheel report from this mouse in the last minute, and more than one mouse is connected. Use it and this updates."
        case .unknown(.notAllowed):
            return "More than one mouse is connected and Input Monitoring isn't allowed, so Whisker can't see which one sends a click."
        case .unknown(.couldNotListen):
            return "More than one mouse is connected and Whisker couldn't start listening for button and wheel reports, so it can't see which one sends a click."
        case .ambiguousIdentity(let devices):
            return "\(devices) connected devices report this identity, so Whisker can't tell which of them sent a click."
        case .leftAlone:
            return "Whisker leaves this device alone, so it doesn't match clicks to it."
        case .notConnected:
            return "This mouse isn't connected, so there is no input to match."
        }
    }
}

/// When each device last sent a button or wheel report, so the Devices pane can say "recent matching input".
///
/// One time per device, never a history of events. It lives in memory, is never saved and is forgotten when
/// a device disconnects.
public struct AttributionEvidence: Equatable, Sendable {
    /// How long a report counts as recent. Long enough to look at the pane after using a mouse, short enough
    /// not to read as a standing guarantee.
    public static let window: TimeInterval = 60

    private var lastReport: [String: TimeInterval] = [:]

    public init() {}

    public var isEmpty: Bool { lastReport.isEmpty }

    /// Notes a report from a device. True when the device wasn't recent before, which is when the pane has something new to say.
    @discardableResult
    public mutating func record(deviceID: String, at time: TimeInterval) -> Bool {
        let becameRecent = !isRecent(deviceID, at: time)
        lastReport[deviceID] = time
        return becameRecent
    }

    public func isRecent(_ deviceID: String, at time: TimeInterval) -> Bool {
        guard let last = lastReport[deviceID] else { return false }
        return time - last < Self.window
    }

    public func recent(at time: TimeInterval) -> Set<String> {
        Set(lastReport.keys.filter { isRecent($0, at: time) })
    }

    /// When the oldest report that is still recent goes stale; nil when none is.
    public func nextExpiry(at time: TimeInterval) -> TimeInterval? {
        lastReport.values.filter { time - $0 < Self.window }.min().map { $0 + Self.window }
    }

    /// Drops devices that are gone and reports that have gone stale.
    public mutating func prune(keeping connected: Set<String>, at time: TimeInterval) {
        lastReport = lastReport.filter { connected.contains($0.key) && time - $0.value < Self.window }
    }
}

// MARK: - Details

/// A device's serial number as far as Whisker knows. The value is there for an explicit "Show", not for display.
public enum SerialNumber: Hashable, Sendable {
    case reported(String)
    case notReported
    /// A remembered identity that Whisker can't read a serial from.
    case unknown
}

/// A reason worth telling someone about, shown with a device's details.
public enum DeviceNote: Hashable, Sendable {
    case excluded(ExcludedDeviceKind)
    case sharedIdentity(devices: Int, hasSerial: Bool)
    case noProductName
    case noSerial
    case controlsUnavailable(ControlsUnavailableReason)
    case controlsIncomplete
    case unrecognisedIdentity

    public var text: String {
        switch self {
        case .excluded(.trackpad):
            return "Trackpads keep their own gestures and settings, so Whisker leaves them alone. It recognised this one from the name or connection type it reports."
        case .excluded(.touchMouse):
            return "Touch mice such as the Magic Mouse keep their own gestures and settings, so Whisker leaves them alone. There is no setting to change that: it has not been verified that a Magic Mouse's buttons can be remapped without disturbing its gestures. It recognised this one from its name."
        case .sharedIdentity(let devices, let hasSerial):
            return "\(devices) connected devices report the same vendor and product ids\(hasSerial ? " and serial number" : ""), so Whisker treats them as one mouse. They share one set of settings."
        case .noProductName:
            return "This device doesn't report a product name, so Whisker shows its vendor and product ids instead."
        case .noSerial:
            return "This device doesn't report a serial number, so its settings apply to every mouse with the same vendor and product ids."
        case .controlsUnavailable(.inputMonitoringOff):
            return "Whisker reads a device's controls once Input Monitoring is allowed, and doesn't ask for it just to show details. That says nothing about how many buttons it has."
        case .controlsUnavailable(.notProvided):
            return "macOS didn't provide this device's controls to Whisker. That says nothing about how many buttons it has."
        case .controlsUnavailable(.notConnected):
            return "Controls can only be read while the mouse is connected."
        case .controlsIncomplete:
            return "Part of this device couldn't be read, so the list may be missing controls."
        case .unrecognisedIdentity:
            return "Whisker doesn't recognise this saved identity, so it can't show vendor, product or serial details."
        }
    }
}

/// Everything the Devices pane explains about one mouse, built by `DeviceDetailsBuilder`. An immutable snapshot:
/// reading or showing it never touches the event tap, settings or the device.
public struct DeviceDetails: Hashable, Sendable, Identifiable {
    public enum Presence: Hashable, Sendable {
        /// `physicalDevices` is how many connected devices share this identity (more than one is a collision).
        case connected(physicalDevices: Int)
        case notConnected
    }

    /// The settings identity: `vendor:product`, plus the serial number when the device reports one.
    public let id: String
    /// What the lists show; never the serial number.
    public let name: String
    /// The product name the device reported; nil when it reported none.
    public let productName: String?
    public let vendorID: Int?
    public let productID: Int?
    public let serial: SerialNumber
    /// The reported transport, such as "USB" or "Bluetooth"; nil when none was reported.
    public let transport: String?
    public let presence: Presence
    public let excludedKind: ExcludedDeviceKind?
    public let controls: ControlsReport
    public let identification: IdentificationStatus
    public let attribution: AttributionBasis
    public let notes: [DeviceNote]

    public var isConnected: Bool {
        if case .connected = presence { return true }
        return false
    }

    /// `046D:C52B`, without the serial number.
    public var identifiersText: String {
        guard let vendorID, let productID else { return "Unknown" }
        return String(format: "%04X:%04X", vendorID & 0xFFFF, productID & 0xFFFF)
    }

    /// What a list shows under the name: the ids, and that a serial number exists when one does. Never its value.
    public var summaryText: String {
        if case .reported = serial { return "\(identifiersText) · serial number hidden" }
        return identifiersText
    }

    /// Whisker records 0 for an id a device didn't report, and no vendor has id 0, so 0 is shown as not reported.
    public var vendorIDText: String {
        guard let vendorID else { return "Unknown" }
        return vendorID == 0 ? "Not reported" : String(format: "%04X", vendorID & 0xFFFF)
    }

    public var productIDText: String {
        guard let productID else { return "Unknown" }
        return vendorID == 0 && productID == 0 ? "Not reported" : String(format: "%04X", productID & 0xFFFF)
    }

    public var productNameText: String {
        if let productName { return productName }
        return isConnected ? "Not reported" : "Unknown while not connected"
    }

    public var transportText: String {
        if let transport { return transport }
        return isConnected ? "Not reported" : "Unknown while not connected"
    }

    /// Whether a serial exists, without the value.
    public var serialText: String {
        switch serial {
        case .reported: return "Reported, hidden"
        case .notReported: return "Not reported"
        case .unknown: return "Unknown"
        }
    }

    public var serialValue: String? {
        if case .reported(let value) = serial { return value }
        return nil
    }

    public var controlsButtonsText: String {
        guard case .reported(let reported) = controls else { return "Unavailable" }
        return reported.buttonSummary ?? "None reported"
    }

    public var controlsWheelsText: String {
        guard case .reported(let reported) = controls else { return "Unavailable" }
        return reported.wheelSummary ?? "None reported"
    }

    /// Shown under the controls so a reported list isn't taken for a count of physical buttons.
    public static let controlsCaveat = "These are the buttons and wheels the device reports to macOS. It isn't a count of physical buttons, and “none reported” doesn't mean there are none."
}

public enum DeviceDetailsBuilder {
    /// Details for the connected devices, in the same order.
    ///
    /// - Parameters:
    ///   - controls: what each device reported, by device id; a device without an entry counts as unavailable.
    ///   - recentInput: ids of devices that sent a button or wheel report recently (see `AttributionEvidence`).
    public static func details(
        for devices: [PointingDevice],
        controls: [String: ControlsReport] = [:],
        identification: IdentificationStatus,
        recentInput: Set<String> = []
    ) -> [DeviceDetails] {
        let eligible = devices.filter { !$0.isExcluded }.count
        return devices.map { device in
            let physicalDevices = max(device.physicalKeys.count, 1)
            let report = controls[device.id] ?? .unavailable(.notProvided)
            let attribution: AttributionBasis
            if let kind = device.excludedKind {
                attribution = .leftAlone(kind)
            } else if physicalDevices > 1 {
                attribution = .ambiguousIdentity(devices: physicalDevices)
            } else if recentInput.contains(device.id) {
                attribution = .recentInput
            } else if eligible == 1 {
                attribution = .inferredFromOnlyMouse
            } else {
                attribution = .unknown(identification)
            }

            var notes: [DeviceNote] = []
            if let kind = device.excludedKind { notes.append(.excluded(kind)) }
            if physicalDevices > 1 { notes.append(.sharedIdentity(devices: physicalDevices, hasSerial: device.serial != nil)) }
            if device.productName == nil { notes.append(.noProductName) }
            if device.serial == nil && !device.isExcluded { notes.append(.noSerial) }
            switch report {
            case .unavailable(let reason): notes.append(.controlsUnavailable(reason))
            case .reported(let reported): if reported.isIncomplete { notes.append(.controlsIncomplete) }
            }

            return DeviceDetails(
                id: device.id, name: device.name, productName: device.productName,
                vendorID: device.vendorID, productID: device.productID,
                serial: device.serial.map(SerialNumber.reported) ?? .notReported,
                transport: device.transport.flatMap(DeviceIdentity.productName),
                presence: .connected(physicalDevices: physicalDevices), excludedKind: device.excludedKind,
                controls: report, identification: identification, attribution: attribution, notes: notes
            )
        }
    }

    /// Limited details for a mouse that has saved settings but isn't connected: only what its identity key
    /// and saved name say. Everything the device itself would report is unavailable.
    public static func remembered(id: String, name: String, identification: IdentificationStatus) -> DeviceDetails {
        let identity = DeviceIdentity(id: id)
        let savedName = DeviceIdentity.productName(name)
        let displayName = identity.map { DeviceIdentity.displayName(product: savedName, vendorID: $0.vendorID, productID: $0.productID) }
            ?? savedName ?? id
        var notes: [DeviceNote] = [.controlsUnavailable(.notConnected)]
        let serial: SerialNumber
        if let identity {
            serial = identity.serial.map(SerialNumber.reported) ?? .notReported
            if identity.serial == nil { notes.insert(.noSerial, at: 0) }
        } else {
            serial = .unknown
            notes.insert(.unrecognisedIdentity, at: 0)
        }
        return DeviceDetails(
            id: id, name: displayName, productName: nil,
            vendorID: identity?.vendorID, productID: identity?.productID, serial: serial, transport: nil,
            presence: .notConnected, excludedKind: nil,
            controls: .unavailable(.notConnected), identification: identification, attribution: .notConnected, notes: notes
        )
    }
}
