import Foundation
import IOKit
import IOKit.hid
import WhiskerCore

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

    private let client = IOHIDEventSystemClientCreateSimpleClient(kCFAllocatorDefault)
    private(set) var originals: [String: OriginalPointer]
    private var applied: [String: PointerSettings] = [:]
    private var revertTimer: Timer?
    var onOriginalsChange: (([String: OriginalPointer]) -> Void)?
    /// Asked to put a device's pointer settings back when a pending change times out.
    var revert: ((String, PointerSettings?) -> Void)?

    static let resolutionKey = "HIDPointerResolution"
    static let accelerationKey = "HIDMouseAcceleration"

    init(originals: [String: OriginalPointer] = [:]) {
        self.originals = originals
    }

    /// Writes the settings for every connected device; restores devices whose pointer settings were cleared.
    func apply(_ settings: WhiskerSettings, connected: [ConnectedDevice]) {
        for device in connected where !device.isExcluded {
            let config = settings.devices[device.id]
            let wanted = (config?.enabled ?? true) ? config?.pointer : nil
            guard applied[device.id] != wanted else { continue }
            if let wanted {
                write(wanted, to: device)
            } else if originals[device.id] != nil {
                restore(device.id)
            }
            applied[device.id] = wanted
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

    // MARK: HID services

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

    private func write(_ pointer: PointerSettings, to device: ConnectedDevice) {
        let services = services(for: device.id)
        guard !services.isEmpty else {
            Log.pointer.notice("No pointer service found for \(device.id, privacy: .public)")
            return
        }
        if originals[device.id] == nil, let first = services.first {
            originals[device.id] = OriginalPointer(
                resolution: Self.registryResolution(of: first),
                acceleration: (IOHIDServiceClientCopyProperty(first, Self.accelerationKey as CFString) as? NSNumber)?.int64Value
            )
            onOriginalsChange?(originals)
        }
        let native = originals[device.id]?.resolution.map { PointerMath.fromIOFixed($0) }
        let resolution = PointerMath.ioFixed(PointerMath.resolution(forSpeed: pointer.speed, nativeResolution: native))
        let acceleration = PointerMath.ioFixed(PointerMath.acceleration(pointer.acceleration, linear: pointer.linear))
        var ok = true
        for service in services {
            ok = IOHIDServiceClientSetProperty(service, Self.resolutionKey as CFString, NSNumber(value: resolution)) && ok
            ok = IOHIDServiceClientSetProperty(service, Self.accelerationKey as CFString, NSNumber(value: acceleration)) && ok
        }
        if ok {
            unsupported.remove(device.id)
            Log.pointer.info("Pointer for \(device.id, privacy: .public): speed \(pointer.speed), acceleration \(pointer.linear ? -1 : pointer.acceleration)")
        } else {
            unsupported.insert(device.id)
            Log.pointer.error("The system refused pointer settings for \(device.id, privacy: .public)")
        }
    }

    private func restore(_ deviceID: String) {
        guard let original = originals[deviceID] else { return }
        for service in services(for: deviceID) {
            let resolution = original.resolution ?? Int64(PointerMath.ioFixed(PointerMath.standardResolution))
            _ = IOHIDServiceClientSetProperty(service, Self.resolutionKey as CFString, NSNumber(value: resolution))
            if let acceleration = original.acceleration {
                _ = IOHIDServiceClientSetProperty(service, Self.accelerationKey as CFString, NSNumber(value: acceleration))
            }
        }
        originals[deviceID] = nil
        applied[deviceID] = nil
        onOriginalsChange?(originals)
        Log.pointer.info("Restored pointer for \(deviceID, privacy: .public)")
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
