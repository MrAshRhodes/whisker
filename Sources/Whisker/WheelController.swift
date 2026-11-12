import Foundation
import IOKit
import IOKit.hid
import OSLog
import WhiskerCore

private let wheelLog = Logger(subsystem: WhiskerInfo.bundleIdentifier, category: "wheel")

// MARK: - Hardware

/// What a service reports for a wheel property.
enum WheelReading: Equatable {
    case missing
    /// A boolean, floating point value or an integer of an unexpected width: not understood, never written.
    case unsupportedType
    case integer(Int64, byteSize: Int)
}

enum WheelServiceLookup: Equatable {
    case none
    /// Several physical devices share this identity (or one device has several locations), so a write could
    /// reach the wrong mouse.
    case ambiguous
    case services(Set<UInt64>)
}

/// Reads and writes a mouse's wheel properties. `IOHIDWheelHardware` talks to the HID event system; tests
/// supply their own. Nothing here runs in the event tap.
protocol WheelHardware: AnyObject {
    /// Registry IDs of the device's services; they change when the device reconnects.
    func lookup(deviceID: String) -> WheelServiceLookup
    /// Whether this exact service still exists and still belongs to this device.
    func isPresent(service: UInt64, deviceID: String) -> Bool
    func read(_ control: NativeWheelControl, service: UInt64) -> WheelReading
    /// False when the system refused the value. True alone does not prove the mouse changed.
    func write(_ control: NativeWheelControl, value: Int64, byteSize: Int, service: UInt64) -> Bool
}

// MARK: - Recovery records

/// What Whisker changed on one control of one service, kept on disk until it has been put back.
struct WheelControlRecord: Codable, Equatable {
    var original: Int64
    var byteSize: Int
    /// The value Whisker asked for, so a restore can tell its own change from one made by someone else.
    var written: Int64
}

/// Everything Whisker changed on a device: service registry ID, then control name.
struct WheelRecord: Codable, Equatable {
    var services: [String: [String: WheelControlRecord]] = [:]
}

enum WheelIssue: Equatable {
    case noService
    case ambiguousDevice
    case noOriginal
    case unexpectedType
    case outOfRange
    case notScalable
    case refused
    case readBackMismatch
    case restoreFailed

    var message: String {
        switch self {
        case .noService: return "This mouse has no wheel service Whisker can use."
        case .ambiguousDevice: return "Whisker can’t tell this mouse apart from another one with the same identity."
        case .noOriginal: return "The mouse doesn’t report its current value, so Whisker couldn’t put it back."
        case .unexpectedType: return "The mouse reports this value in a form Whisker doesn’t understand."
        case .outOfRange: return "The mouse reports a value outside the range Whisker understands."
        case .notScalable: return "This value can’t be applied to this mouse."
        case .refused: return "macOS refused the change."
        case .readBackMismatch: return "The mouse didn’t keep the value, so the change was undone."
        case .restoreFailed: return "The original value couldn’t be put back."
        }
    }
}

enum WheelControlStatus: Equatable {
    /// Readable and plausible. A write has not been tried, and whether the mouse then scrolls differently
    /// can't be checked from here.
    case available
    case active
    case unavailable(WheelIssue)
    case failed(WheelIssue)
}

// MARK: - Controller

/// Applies native wheel speed and acceleration by writing to a mouse's own HID service, and puts the values
/// it found back when native settings are switched off, cleared, bypassed, or Whisker quits.
///
/// Every control stays unavailable unless the mouse reports a typed original Whisker can restore, the system
/// accepts the write and the read-back matches. Any failure rolls the whole mouse back, so a mouse is either
/// fully in native mode or not at all.
@MainActor
final class WheelController: ObservableObject {
    @Published private(set) var statuses: [String: [NativeWheelControl: WheelControlStatus]] = [:]
    /// Devices whose wheel Whisker has changed. The event tap uses this to stand its software distance and
    /// acceleration aside.
    @Published private(set) var activeDevices: Set<String> = []
    /// Devices whose original values couldn't be put back. The record stays and the restore is tried again.
    @Published private(set) var restoreFailures: Set<String> = []

    private struct Applied: Equatable {
        var wanted: NativeWheelSettings?
        var lookup: WheelServiceLookup
    }

    private let hardware: WheelHardware
    private(set) var records: [String: WheelRecord]
    private var applied: [String: Applied] = [:]
    /// Called with the latest records before any write happens and whenever they change, so they survive a crash.
    var onRecordsChange: (([String: WheelRecord]) -> Void)?

    init(records: [String: WheelRecord] = [:], hardware: WheelHardware = IOHIDWheelHardware()) {
        self.records = records
        self.hardware = hardware
    }

    func status(of control: NativeWheelControl, device: String) -> WheelControlStatus? {
        statuses[device]?[control]
    }

    /// Brings every connected mouse in line with its settings. While `bypassed` nothing is wanted, so the
    /// system's own values come back. Writes are synchronous on the main actor, so the last call wins.
    func apply(_ settings: WhiskerSettings, connected: [ConnectedDevice], bypassed: Bool = false) {
        let present = Set(connected.filter { !$0.isExcluded }.map(\.id))
        applied = applied.filter { present.contains($0.key) }
        statuses = statuses.filter { present.contains($0.key) }
        for device in connected where !device.isExcluded {
            let wanted = bypassed ? nil : settings.activeNativeWheel(for: device.id)
            let target = Applied(wanted: wanted, lookup: lookup(for: device))
            guard applied[device.id] != target else { continue }
            if records[device.id] != nil {
                // The originals on record are the system's; start from them rather than from our own values.
                guard restore(device.id, force: false) else { applied[device.id] = nil; continue }
            }
            if let wanted {
                activate(wanted, device: device, lookup: target.lookup)
            } else {
                probe(device.id, lookup: target.lookup)
            }
            applied[device.id] = target
        }
    }

    /// Puts back every value Whisker changed.
    func restoreAll() {
        for id in Array(records.keys) { restore(id, force: false) }
        applied.removeAll()
    }

    /// Puts back values recorded by a previous run that didn't quit cleanly, on mice that are connected.
    func restoreLeftovers(connected: [ConnectedDevice]) {
        let ids = Set(connected.map(\.id))
        for id in Array(records.keys) where ids.contains(id) { restore(id, force: false) }
    }

    // MARK: Lookup and probing

    private func lookup(for device: ConnectedDevice) -> WheelServiceLookup {
        let found = hardware.lookup(deviceID: device.id)
        guard case .services(let services) = found else { return found }
        if services.isEmpty { return WheelServiceLookup.none }
        // Identical mice without serial numbers are listed as one device.
        if device.serial == nil, device.physicalKeys.count > 1 { return .ambiguous }
        return found
    }

    private func services(in lookup: WheelServiceLookup) -> (Set<UInt64>, WheelIssue?) {
        switch lookup {
        case .none: return ([], .noService)
        case .ambiguous: return ([], .ambiguousDevice)
        case .services(let services): return (services, nil)
        }
    }

    private struct Snapshot {
        var records: [UInt64: (original: Int64, byteSize: Int)] = [:]
        var issue: WheelIssue?
    }

    /// Reads one control on every service. Any service that doesn't give a usable typed original makes the
    /// control unusable for the mouse.
    private func snapshot(_ control: NativeWheelControl, services: Set<UInt64>) -> Snapshot {
        var result = Snapshot()
        for service in services {
            switch hardware.read(control, service: service) {
            case .missing: result.issue = .noOriginal
            case .unsupportedType: result.issue = .unexpectedType
            case .integer(let value, let byteSize):
                if NativeWheelMath.plausibleOriginals(for: control).contains(value) {
                    result.records[service] = (value, byteSize)
                } else {
                    result.issue = .outOfRange
                }
            }
            if result.issue != nil { return result }
        }
        return result
    }

    /// Read-only: records which controls could be used, without writing anything.
    private func probe(_ id: String, lookup: WheelServiceLookup) {
        activeDevices.remove(id)
        let (services, issue) = services(in: lookup)
        var result: [NativeWheelControl: WheelControlStatus] = [:]
        for control in NativeWheelControl.allCases {
            if let issue {
                result[control] = .unavailable(issue)
            } else if let problem = snapshot(control, services: services).issue {
                result[control] = .unavailable(problem)
            } else {
                result[control] = .available
            }
        }
        statuses[id] = result
    }

    // MARK: Writing

    private func activate(_ wanted: NativeWheelSettings, device: ConnectedDevice, lookup: WheelServiceLookup) {
        let id = device.id
        activeDevices.remove(id)
        probe(id, lookup: lookup)
        let (services, issue) = services(in: lookup)
        guard issue == nil else { return }

        var plan: [(control: NativeWheelControl, service: UInt64, record: WheelControlRecord)] = []
        var blocked = false
        for control in wanted.requestedControls {
            let setting = control == .speed ? wanted.speed : wanted.acceleration
            let taken = snapshot(control, services: services)
            if let problem = taken.issue {
                statuses[id]?[control] = .unavailable(problem)
                blocked = true
                continue
            }
            for (service, original) in taken.records.sorted(by: { $0.key < $1.key }) {
                guard let setting,
                      let value = NativeWheelMath.value(for: control, setting: setting, original: original.original),
                      Self.fits(value, byteSize: original.byteSize)
                else {
                    statuses[id]?[control] = .unavailable(.notScalable)
                    blocked = true
                    break
                }
                plan.append((control, service, WheelControlRecord(original: original.original, byteSize: original.byteSize, written: value)))
            }
        }
        guard !blocked, !plan.isEmpty else { return }

        // Recovery state goes to disk before the first write.
        var record = WheelRecord()
        for item in plan { record.services[String(item.service), default: [:]][item.control.rawValue] = item.record }
        setRecord(record, for: id)

        var failure: (NativeWheelControl, WheelIssue)?
        for item in plan {
            guard hardware.write(item.control, value: item.record.written, byteSize: item.record.byteSize, service: item.service) else {
                failure = (item.control, .refused)
                break
            }
            guard hardware.read(item.control, service: item.service) == .integer(item.record.written, byteSize: item.record.byteSize) else {
                failure = (item.control, .readBackMismatch)
                break
            }
        }

        if let (control, issue) = failure {
            wheelLog.error("Native wheel \(control.rawValue, privacy: .public) failed for \(id, privacy: .public); rolling back")
            let restored = restore(id, force: true)
            statuses[id]?[control] = .failed(issue)
            if !restored { statuses[id]?[control] = .failed(.restoreFailed) }
            return
        }
        for control in wanted.requestedControls { statuses[id]?[control] = .active }
        activeDevices.insert(id)
        restoreFailures.remove(id)
        wheelLog.info("Native wheel applied for \(id, privacy: .public)")
    }

    private static func fits(_ value: Int64, byteSize: Int) -> Bool {
        byteSize == 8 || (value >= Int64(Int32.min) && value <= Int64(Int32.max))
    }

    /// Puts a device's recorded values back. A service that is gone has nothing left to restore. Unless
    /// `force`, a value someone else changed since Whisker wrote it is left alone. When the system refuses,
    /// what couldn't be restored stays on record, so a later attempt or the next launch can finish the job.
    @discardableResult
    private func restore(_ id: String, force: Bool) -> Bool {
        guard var record = records[id] else { return true }
        for (serviceKey, controls) in record.services {
            guard let service = UInt64(serviceKey), hardware.isPresent(service: service, deviceID: id) else {
                record.services[serviceKey] = nil
                continue
            }
            var remaining = controls
            for (name, item) in controls {
                guard let control = NativeWheelControl(rawValue: name) else { continue }
                let current = hardware.read(control, service: service)
                if current == .integer(item.original, byteSize: item.byteSize) {
                    remaining[name] = nil
                } else if !force, case .integer(let value, _) = current, value != item.written {
                    wheelLog.notice("Leaving \(name, privacy: .public) for \(id, privacy: .public): changed outside Whisker")
                    remaining[name] = nil
                } else if hardware.write(control, value: item.original, byteSize: item.byteSize, service: service),
                          hardware.read(control, service: service) == .integer(item.original, byteSize: item.byteSize) {
                    remaining[name] = nil
                }
            }
            record.services[serviceKey] = remaining.isEmpty ? nil : remaining
        }
        applied[id] = nil
        if record.services.isEmpty {
            setRecord(nil, for: id)
            restoreFailures.remove(id)
            activeDevices.remove(id)
            wheelLog.info("Restored wheel for \(id, privacy: .public)")
            return true
        }
        setRecord(record, for: id)
        restoreFailures.insert(id)
        wheelLog.error("Couldn’t put the wheel back for \(id, privacy: .public); keeping its original values on record")
        return false
    }

    private func setRecord(_ record: WheelRecord?, for id: String) {
        if records[id] == record { return }
        records[id] = record
        onRecordsChange?(records)
    }
}

// MARK: - IOKit

/// Wheel properties through the HID event system client.
final class IOHIDWheelHardware: WheelHardware {
    static let speedKey = "HIDScrollResolution"
    static let accelerationKey = "HIDMouseScrollAcceleration"

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    private static func key(_ control: NativeWheelControl) -> CFString {
        (control == .speed ? speedKey : accelerationKey) as CFString
    }

    func lookup(deviceID: String) -> WheelServiceLookup {
        let matching = services().filter { Self.matches($0, deviceID: deviceID) }
        guard !matching.isEmpty else { return WheelServiceLookup.none }
        // Interfaces of one physical device share a location. Services without one count as separate
        // devices, so Whisker never writes to something it can't tell is the same mouse.
        var locations = Set<String>()
        for (index, service) in matching.enumerated() {
            if let location = (IOHIDServiceClientCopyProperty(service, kIOHIDLocationIDKey as CFString) as? NSNumber)?.uint64Value {
                locations.insert("l\(location)")
            } else {
                locations.insert("s\(index)")
            }
        }
        if locations.count > 1 { return .ambiguous }
        return .services(Set(matching.compactMap(Self.registryID)))
    }

    func isPresent(service: UInt64, deviceID: String) -> Bool {
        services().contains { Self.registryID($0) == service && Self.matches($0, deviceID: deviceID) }
    }

    func read(_ control: NativeWheelControl, service: UInt64) -> WheelReading {
        guard let found = self.service(service),
              let value = IOHIDServiceClientCopyProperty(found, Self.key(control))
        else { return .missing }
        guard CFGetTypeID(value) == CFNumberGetTypeID() else { return .unsupportedType }
        let number = value as! CFNumber
        let size = CFNumberGetByteSize(number)
        var result: Int64 = 0
        guard !CFNumberIsFloatType(number), size == 4 || size == 8,
              CFNumberGetValue(number, .sInt64Type, &result)
        else { return .unsupportedType }
        return .integer(result, byteSize: size)
    }

    func write(_ control: NativeWheelControl, value: Int64, byteSize: Int, service: UInt64) -> Bool {
        guard let found = self.service(service) else { return false }
        let number: NSNumber = byteSize == 4 ? NSNumber(value: Int32(truncatingIfNeeded: value)) : NSNumber(value: value)
        return IOHIDServiceClientSetProperty(found, Self.key(control), number)
    }

    private func services() -> [IOHIDServiceClient] {
        (IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]) ?? []
    }

    private func service(_ registryID: UInt64) -> IOHIDServiceClient? {
        services().first { Self.registryID($0) == registryID }
    }

    private static func registryID(_ service: IOHIDServiceClient) -> UInt64? {
        (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value
    }

    private static func matches(_ service: IOHIDServiceClient, deviceID: String) -> Bool {
        guard let identity = DeviceIdentity(id: deviceID),
              IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                || IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) != 0
        else { return false }
        let vendor = (IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
        let product = (IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
        guard vendor == identity.vendorID, product == identity.productID else { return false }
        guard let serial = identity.serial else { return true }
        return (IOHIDServiceClientCopyProperty(service, kIOHIDSerialNumberKey as CFString) as? String) == serial
    }
}
