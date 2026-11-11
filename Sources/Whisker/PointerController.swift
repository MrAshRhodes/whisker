import Foundation
import IOKit
import IOKit.hid
import WhiskerCore

/// Reads and writes a device's pointer values. `IOHIDPointerHardware` talks to the HID event system; tests
/// supply their own.
protocol PointerHardware: AnyObject {
    /// Registry IDs of the device's pointer services; they change when the device reconnects.
    func serviceIDs(for deviceID: String) -> Set<UInt64>
    /// The current values, or nil when the device has no pointer service.
    func currentValues(of deviceID: String) -> OriginalPointer?
    /// False when the device has no pointer service or the system refused the values.
    func write(resolution: Int64, acceleration: Int64?, to deviceID: String) -> Bool
}

/// Applies per-device pointer speed and acceleration by writing to the device's HID event service, and puts
/// the original values back when settings are cleared or Whisker quits.
@MainActor
final class PointerController: ObservableObject {
    /// A big speed change waiting to be kept; it reverts on its own unless confirmed.
    struct PendingChange: Equatable {
        var deviceID: String
        var previous: PointerSettings?
        var deadline: Date
    }

    @Published private(set) var pending: PendingChange?
    /// Devices whose service refused a write, so the Pointer pane can say speed can't be changed.
    @Published private(set) var unsupported: Set<String> = []

    /// What was last written to a device, and to which services, so unchanged settings aren't rewritten.
    private struct Applied: Equatable {
        var pointer: PointerSettings?
        var services: Set<UInt64>
    }

    private let hardware: PointerHardware
    private(set) var originals: [String: OriginalPointer]
    private var applied: [String: Applied] = [:]
    private var revertTimer: Timer?
    var onOriginalsChange: (([String: OriginalPointer]) -> Void)?
    /// Asked to put a device's pointer settings back when a pending change times out.
    var revert: ((String, PointerSettings?) -> Void)?

    init(originals: [String: OriginalPointer] = [:], hardware: PointerHardware = IOHIDPointerHardware()) {
        self.originals = originals
        self.hardware = hardware
    }

    /// Writes the settings for every connected device; restores devices whose pointer settings were cleared or
    /// switched off, including while Whisker as a whole is switched off.
    ///
    /// A device is written again after it disconnects or its services change, and after a failed write.
    func apply(_ settings: WhiskerSettings, connected: [ConnectedDevice]) {
        let present = Set(connected.filter { !$0.isExcluded }.map(\.id))
        applied = applied.filter { present.contains($0.key) }
        for device in connected where !device.isExcluded {
            let wanted = settings.activePointer(for: device.id)
            let target = Applied(pointer: wanted, services: hardware.serviceIDs(for: device.id))
            guard applied[device.id] != target else { continue }
            if let wanted {
                guard write(wanted, to: device) else {
                    applied[device.id] = nil
                    continue
                }
            } else if originals[device.id] != nil {
                restore(device.id)
            }
            applied[device.id] = target
        }
    }

    /// Puts back every value Whisker changed.
    func restoreAll() {
        for id in Array(originals.keys) { restore(id) }
        applied.removeAll()
    }

    /// Puts back values recorded by a previous run that didn't quit cleanly.
    func restoreLeftovers(connected: [ConnectedDevice]) {
        let ids = Set(connected.map(\.id))
        for id in originals.keys where ids.contains(id) { restore(id) }
    }

    // MARK: Confirmation

    func beginConfirmation(deviceID: String, previous: PointerSettings?) {
        revertTimer?.invalidate()
        let deadline = Date().addingTimeInterval(PointerMath.confirmationTimeout)
        pending = PendingChange(deviceID: deviceID, previous: previous, deadline: deadline)
        revertTimer = Timer.scheduledTimer(withTimeInterval: PointerMath.confirmationTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.revertPending() }
        }
    }

    func confirmPending() {
        revertTimer?.invalidate()
        revertTimer = nil
        pending = nil
    }

    func revertPending() {
        revertTimer?.invalidate()
        revertTimer = nil
        guard let pending else { return }
        self.pending = nil
        Log.pointer.info("Pointer speed change not confirmed; reverting \(pending.deviceID, privacy: .public)")
        revert?(pending.deviceID, pending.previous)
    }

    // MARK: Writing

    private func write(_ pointer: PointerSettings, to device: ConnectedDevice) -> Bool {
        guard let current = hardware.currentValues(of: device.id) else {
            Log.pointer.notice("No pointer service found for \(device.id, privacy: .public)")
            return false
        }
        if originals[device.id] == nil {
            originals[device.id] = current
            onOriginalsChange?(originals)
        }
        let native = originals[device.id]?.resolution.map { PointerMath.fromIOFixed($0) }
        let resolution = PointerMath.ioFixed(PointerMath.resolution(forSpeed: pointer.speed, nativeResolution: native))
        let acceleration = PointerMath.ioFixed(PointerMath.acceleration(pointer.acceleration, linear: pointer.linear))
        if hardware.write(resolution: Int64(resolution), acceleration: Int64(acceleration), to: device.id) {
            unsupported.remove(device.id)
            Log.pointer.info("Pointer for \(device.id, privacy: .public): speed \(pointer.speed), acceleration \(pointer.linear ? -1 : pointer.acceleration)")
            return true
        }
        unsupported.insert(device.id)
        Log.pointer.error("The system refused pointer settings for \(device.id, privacy: .public)")
        return false
    }

    private func restore(_ deviceID: String) {
        guard let original = originals[deviceID] else { return }
        let resolution = original.resolution ?? Int64(PointerMath.ioFixed(PointerMath.standardResolution))
        _ = hardware.write(resolution: resolution, acceleration: original.acceleration, to: deviceID)
        originals[deviceID] = nil
        applied[deviceID] = nil
        onOriginalsChange?(originals)
        Log.pointer.info("Restored pointer for \(deviceID, privacy: .public)")
    }
}

/// Pointer values through the HID event system client.
final class IOHIDPointerHardware: PointerHardware {
    static let resolutionKey = "HIDPointerResolution"
    static let accelerationKey = "HIDMouseAcceleration"

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)

    func serviceIDs(for deviceID: String) -> Set<UInt64> {
        Set(services(for: deviceID).compactMap { (IOHIDServiceClientGetRegistryID($0) as? NSNumber)?.uint64Value })
    }

    func currentValues(of deviceID: String) -> OriginalPointer? {
        guard let first = services(for: deviceID).first else { return nil }
        return OriginalPointer(
            resolution: Self.registryResolution(of: first),
            acceleration: (IOHIDServiceClientCopyProperty(first, Self.accelerationKey as CFString) as? NSNumber)?.int64Value
        )
    }

    func write(resolution: Int64, acceleration: Int64?, to deviceID: String) -> Bool {
        let services = services(for: deviceID)
        guard !services.isEmpty else { return false }
        var ok = true
        for service in services {
            ok = IOHIDServiceClientSetProperty(service, Self.resolutionKey as CFString, NSNumber(value: resolution)) && ok
            if let acceleration {
                ok = IOHIDServiceClientSetProperty(service, Self.accelerationKey as CFString, NSNumber(value: acceleration)) && ok
            }
        }
        return ok
    }

    private func services(for deviceID: String) -> [IOHIDServiceClient] {
        guard let identity = DeviceIdentity(id: deviceID),
              let all = IOHIDEventSystemClientCopyServices(client) as? [IOHIDServiceClient]
        else { return [] }
        return all.filter { service in
            guard IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Mouse)) != 0
                || IOHIDServiceClientConformsTo(service, UInt32(kHIDPage_GenericDesktop), UInt32(kHIDUsage_GD_Pointer)) != 0
            else { return false }
            let vendor = (IOHIDServiceClientCopyProperty(service, kIOHIDVendorIDKey as CFString) as? NSNumber)?.intValue
            let product = (IOHIDServiceClientCopyProperty(service, kIOHIDProductIDKey as CFString) as? NSNumber)?.intValue
            guard vendor == identity.vendorID, product == identity.productID else { return false }
            guard let serial = identity.serial else { return true }
            return (IOHIDServiceClientCopyProperty(service, kIOHIDSerialNumberKey as CFString) as? String) == serial
        }
    }

    /// The service client doesn't expose the resolution, but the registry entry behind it does.
    private static func registryResolution(of service: IOHIDServiceClient) -> Int64? {
        guard let registryID = (IOHIDServiceClientGetRegistryID(service) as? NSNumber)?.uint64Value,
              let matching = IORegistryEntryIDMatching(registryID)
        else { return nil }
        let entry = IOServiceGetMatchingService(kIOMainPortDefault, matching)
        guard entry != IO_OBJECT_NULL else { return nil }
        defer { IOObjectRelease(entry) }
        let value = IORegistryEntrySearchCFProperty(
            entry, kIOServicePlane, resolutionKey as CFString, kCFAllocatorDefault,
            IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
        )
        return (value as? NSNumber)?.int64Value
    }
}
