import Foundation

// Best-effort wireless mouse battery status. Everything here is pure policy: which HID elements count as a
// battery percentage, how a raw value is validated, when a reading is stale and which device a reading may
// belong to. Reading the device lives in the app target. Nothing here is saved: readings, times and handles
// stay in memory.

// MARK: - Elements

/// One element of a mouse interface's HID descriptor, reduced to what battery discovery reads.
public struct BatteryElement: Hashable, Sendable {
    public var kind: HIDElementKind
    public var usagePage: Int
    public var usage: Int
    public var logicalMin: Int
    public var logicalMax: Int

    public init(kind: HIDElementKind, usagePage: Int, usage: Int, logicalMin: Int, logicalMax: Int) {
        self.kind = kind
        self.usagePage = usagePage
        self.usage = usage
        self.logicalMin = logicalMin
        self.logicalMax = logicalMax
    }
}

/// What a mouse interface's descriptor says about a battery. Only an element whose usage and range are known
/// to mean "percent charged" is accepted; anything else that looks like a battery is `unrecognisedFormat`.
public enum BatteryDiscovery: Hashable, Sendable {
    /// macOS described nothing for the interface, so no answer can be given.
    case undescribed
    /// The interface declares no battery element.
    case notSupported
    /// The indexes (into the elements that were passed in) of the percentage and, when explicitly declared, charging elements.
    case readable(percent: Int, charging: Int?)
    /// A battery element is declared, but its usage kind or range isn't one Whisker can validate.
    case unrecognisedFormat
    /// More than one valid percentage element: Whisker can't tell which one is the mouse's own.
    case ambiguous

    /// Generic Device Controls page, BatteryStrength.
    static let genericDeviceControlsPage = 0x06
    static let batteryStrength = 0x20
    /// Battery System page.
    static let batterySystemPage = 0x85
    static let absoluteStateOfCharge = 0x65
    static let charging = 0x44

    /// Whether a value report is about a battery element this discovery would accept, so the app can read again.
    public static func isBatteryUsage(page: Int, usage: Int) -> Bool {
        switch (page, usage) {
        case (genericDeviceControlsPage, batteryStrength), (batterySystemPage, absoluteStateOfCharge), (batterySystemPage, charging): return true
        default: return false
        }
    }

    public static func discover(_ elements: [BatteryElement]?) -> BatteryDiscovery {
        guard let elements, !elements.isEmpty else { return .undescribed }
        var valid: [Int] = []
        var invalid = false
        var chargingElements: [Int] = []
        for (index, element) in elements.enumerated() {
            let usable = element.kind == .input || element.kind == .feature
            switch (element.usagePage, element.usage) {
            case (genericDeviceControlsPage, batteryStrength), (batterySystemPage, absoluteStateOfCharge):
                if usable, element.logicalMin == 0, element.logicalMax == 100 { valid.append(index) } else { invalid = true }
            case (batterySystemPage, charging):
                if usable, element.logicalMin == 0, element.logicalMax == 1 { chargingElements.append(index) }
            default:
                continue
            }
        }
        if valid.count > 1 { return .ambiguous }
        if let percent = valid.first {
            // A charging flag is only used when exactly one is declared.
            return .readable(percent: percent, charging: chargingElements.count == 1 ? chargingElements[0] : nil)
        }
        return invalid ? .unrecognisedFormat : .notSupported
    }

    /// A percentage, only for a raw value inside the validated 0 to 100 range.
    public static func percent(fromRaw raw: Int) -> Int? {
        (0...100).contains(raw) ? raw : nil
    }

    /// Charging or not, only for an explicit 0 or 1; any other value is "not reported".
    public static func charging(fromRaw raw: Int?) -> Bool? {
        switch raw {
        case 0?: return false
        case 1?: return true
        default: return nil
        }
    }
}

// MARK: - State

public enum BatteryUnavailableReason: Hashable, Sendable {
    /// macOS describes and reports a device's elements only once Input Monitoring is allowed.
    case inputMonitoringOff
    /// The device couldn't be matched to exactly one battery source (merged identical mice, a receiver, several battery elements).
    case ambiguousDevice
    /// The device didn't return a value when asked.
    case readFailed
    /// The device returned something outside the validated range, so it isn't shown.
    case invalidValue
    /// The device declares a battery in a form Whisker can't validate.
    case unrecognisedFormat
    /// macOS didn't describe the device, so Whisker can't tell whether it has a battery.
    case notDescribed

    public var text: String {
        switch self {
        case .inputMonitoringOff: return "Input Monitoring is off"
        case .ambiguousDevice: return "can't tell which device it belongs to"
        case .readFailed: return "the device didn't return a reading"
        case .invalidValue: return "the device returned a value Whisker can't use"
        case .unrecognisedFormat: return "the device reports its battery in a format Whisker doesn't recognise"
        case .notDescribed: return "macOS didn't describe the device"
        }
    }
}

/// What the Devices pane says about one mouse's battery. A percentage exists only in `.value` and `.stale`,
/// and only after validation; missing data is never 0%.
public enum BatteryState: Hashable, Sendable {
    case notSupported
    case waiting
    case unavailable(BatteryUnavailableReason)
    /// The last good reading is older than `BatteryTracker.staleAfter`, or a later read failed.
    case stale(percent: Int, charging: Bool?, lastRead: Date)
    case disconnected
    /// `charging` is nil unless the device explicitly reported it.
    case value(percent: Int, charging: Bool?)

    public var title: String {
        switch self {
        case .notSupported: return "Not supported"
        case .waiting: return "Waiting for a reading"
        case .unavailable: return "Unavailable"
        case .stale: return "Stale"
        case .disconnected: return "Disconnected"
        case .value(let percent, let charging): return "\(percent)%" + Self.chargingSuffix(charging)
        }
    }

    /// One line for the row. `time` formats the moment of a stale reading.
    public func text(time: (Date) -> String) -> String {
        switch self {
        case .unavailable(let reason): return "Unavailable — \(reason.text)"
        case .stale(let percent, let charging, let lastRead):
            return "Stale — \(percent)%\(Self.chargingSuffix(charging)), last read \(time(lastRead))"
        default: return title
        }
    }

    /// Shown when a percentage is worth putting beside the mouse's name.
    public func inlineText(time: (Date) -> String) -> String? {
        switch self {
        case .value, .stale: return "Battery: " + text(time: time)
        default: return nil
        }
    }

    public static let caveat = "Battery information is read from the mouse over the public HID interface, when the mouse offers it. Whisker never writes to the device. If it isn't shown, use the Bluetooth menu or Control Centre."

    private static func chargingSuffix(_ charging: Bool?) -> String {
        switch charging {
        case true?: return ", charging"
        case false?: return ", not charging"
        case nil: return ""
        }
    }
}

// MARK: - Association

/// A pointing device's interfaces as seen at runtime, for deciding where its battery would come from.
public struct BatteryCandidate: Hashable, Sendable {
    public var deviceID: String
    /// Runtime handle of each interface that belongs to this device, with what its descriptor says.
    public var interfaces: [Interface]
    /// How many physical devices share this identity (see `PointingDevice.physicalKeys`).
    public var physicalDevices: Int
    public var product: String?

    public struct Interface: Hashable, Sendable {
        public var runtimeID: Int
        public var discovery: BatteryDiscovery

        public init(runtimeID: Int, discovery: BatteryDiscovery) {
            self.runtimeID = runtimeID
            self.discovery = discovery
        }
    }

    public init(deviceID: String, interfaces: [Interface], physicalDevices: Int, product: String?) {
        self.deviceID = deviceID
        self.interfaces = interfaces
        self.physicalDevices = physicalDevices
        self.product = product
    }
}

/// Where one device's battery can be read from, or why it can't.
public enum BatterySource: Hashable, Sendable {
    case readable(runtimeID: Int, percent: Int, charging: Int?)
    case notSupported
    case unavailable(BatteryUnavailableReason)

    /// A reading is only ever attached to a device that is a single physical device with exactly one battery
    /// source. Merged identities (identical mice without serial numbers), receivers and several candidate
    /// elements are refused rather than guessed at.
    public static func resolve(_ candidate: BatteryCandidate) -> BatterySource {
        if candidate.physicalDevices > 1 { return .unavailable(.ambiguousDevice) }
        let discoveries = candidate.interfaces.map(\.discovery)
        let readable = candidate.interfaces.filter { if case .readable = $0.discovery { return true } else { return false } }
        if PointingDeviceClassifier.looksLikeReceiver(candidate.product), !readable.isEmpty || discoveries.contains(.ambiguous) {
            return .unavailable(.ambiguousDevice)
        }
        if readable.count > 1 || discoveries.contains(.ambiguous) { return .unavailable(.ambiguousDevice) }
        if let only = readable.first, case .readable(let percent, let charging) = only.discovery {
            return .readable(runtimeID: only.runtimeID, percent: percent, charging: charging)
        }
        if discoveries.contains(.unrecognisedFormat) { return .unavailable(.unrecognisedFormat) }
        if discoveries.isEmpty || discoveries.allSatisfy({ $0 == .undescribed }) { return .unavailable(.notDescribed) }
        return .notSupported
    }
}

// MARK: - Tracking

/// Ties a read to one connection of one device. A completion that carries an older handle is dropped.
public struct BatteryHandle: Hashable, Sendable {
    public let deviceID: String
    public let runtimeID: Int
    public let generation: Int
}

/// What a read of the device produced.
public enum BatteryReadOutcome: Equatable, Sendable {
    case value(raw: Int, chargingRaw: Int?)
    /// The device returned nothing, or macOS refused the read.
    case failed
}

/// The readings for the devices that are connected right now. Main thread only; holds no settings.
public struct BatteryTracker: Equatable, Sendable {
    /// Provisional: the reporting cadence of real mice is unverified, so this is deliberately generous.
    public static let staleAfter: TimeInterval = 15 * 60

    private struct Entry: Equatable, Sendable {
        var source: BatterySource
        var generation: Int
        var reading: Reading?
        var failure: BatteryUnavailableReason?
    }

    private struct Reading: Equatable, Sendable {
        var percent: Int
        var charging: Bool?
        var at: TimeInterval
        var date: Date
    }

    private var entries: [String: Entry] = [:]
    private var nextGeneration = 0

    public init() {}

    /// Brings the tracker in line with the connected devices. A device whose source is the same keeps its
    /// reading; a new device, or one whose runtime interface changed (it was unplugged and came back), starts
    /// again under a new generation. Returns the handle to read for each device that has a readable source.
    @discardableResult
    public mutating func sync(_ candidates: [BatteryCandidate]) -> [BatteryHandle] {
        var next: [String: Entry] = [:]
        var handles: [BatteryHandle] = []
        for candidate in candidates {
            let source = BatterySource.resolve(candidate)
            var entry: Entry
            if let existing = entries[candidate.deviceID], existing.source == source {
                entry = existing
            } else {
                nextGeneration += 1
                entry = Entry(source: source, generation: nextGeneration, reading: nil, failure: nil)
            }
            next[candidate.deviceID] = entry
            if case .readable(let runtimeID, _, _) = source {
                handles.append(BatteryHandle(deviceID: candidate.deviceID, runtimeID: runtimeID, generation: entry.generation))
            }
        }
        entries = next
        return handles
    }

    /// The current handle for a device, if it has a readable source.
    public func handle(for deviceID: String) -> BatteryHandle? {
        guard let entry = entries[deviceID], case .readable(let runtimeID, _, _) = entry.source else { return nil }
        return BatteryHandle(deviceID: deviceID, runtimeID: runtimeID, generation: entry.generation)
    }

    /// The elements to read for a handle, or nil when the handle is out of date.
    public func elements(for handle: BatteryHandle) -> (percent: Int, charging: Int?)? {
        guard let entry = entries[handle.deviceID], entry.generation == handle.generation,
              case .readable(let runtimeID, let percent, let charging) = entry.source, runtimeID == handle.runtimeID
        else { return nil }
        return (percent, charging)
    }

    /// Records what a read produced. Returns false, changing nothing, when the handle belongs to a device that
    /// has gone or reconnected since the read began.
    @discardableResult
    public mutating func complete(_ handle: BatteryHandle, _ outcome: BatteryReadOutcome, at time: TimeInterval, date: Date) -> Bool {
        guard elements(for: handle) != nil, var entry = entries[handle.deviceID] else { return false }
        switch outcome {
        case .failed:
            entry.failure = .readFailed
        case .value(let raw, let chargingRaw):
            if let percent = BatteryDiscovery.percent(fromRaw: raw) {
                entry.reading = Reading(percent: percent, charging: BatteryDiscovery.charging(fromRaw: chargingRaw), at: time, date: date)
                entry.failure = nil
            } else {
                entry.reading = nil
                entry.failure = .invalidValue
            }
        }
        entries[handle.deviceID] = entry
        return true
    }

    /// A device that isn't in `sync`'s last list is disconnected.
    public func state(for deviceID: String, at time: TimeInterval, inputMonitoringAllowed: Bool) -> BatteryState {
        guard let entry = entries[deviceID] else { return .disconnected }
        guard inputMonitoringAllowed else { return .unavailable(.inputMonitoringOff) }
        switch entry.source {
        case .notSupported: return .notSupported
        case .unavailable(let reason): return .unavailable(reason)
        case .readable:
            if let reading = entry.reading {
                let age = time - reading.at
                if entry.failure != nil || age >= Self.staleAfter || age < 0 {
                    return .stale(percent: reading.percent, charging: reading.charging, lastRead: reading.date)
                }
                return .value(percent: reading.percent, charging: reading.charging)
            }
            return entry.failure.map(BatteryState.unavailable) ?? .waiting
        }
    }

    /// When the next state change is due without any new read: the moment the reading goes stale.
    public func nextStaleness(after time: TimeInterval) -> TimeInterval? {
        entries.values.compactMap { $0.reading.map { $0.at + Self.staleAfter } }.filter { $0 > time }.min()
    }
}

public enum BatteryStates {
    /// The states to show for the listed devices; devices that are not connected are `.disconnected`.
    public static func states(
        for devices: [PointingDevice], tracker: BatteryTracker, at time: TimeInterval, inputMonitoringAllowed: Bool
    ) -> [String: BatteryState] {
        Dictionary(uniqueKeysWithValues: devices.map {
            ($0.id, tracker.state(for: $0.id, at: time, inputMonitoringAllowed: inputMonitoringAllowed))
        })
    }
}
