import Foundation
import IOKit.hid
import os
import WhiskerCore

/// A pointing device that is plugged in or paired right now.
struct ConnectedDevice: Identifiable, Hashable {
    var id: String
    var name: String
    var vendorID: Int
    var productID: Int
    var serial: String?
    var transport: String?
    /// Trackpads and touch mice: listed, but Whisker leaves them alone.
    var isExcluded: Bool
}

/// Watches mice come and go, and — when Input Monitoring is allowed — which one each click came from.
final class DeviceMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var canIdentifyDevices = false
    var onChange: (([ConnectedDevice]) -> Void)?

    private var manager: IOHIDManager?
    private var deviceIDs: [IOHIDDevice: String] = [:]
    private var opened = false
    private let attributor = OSAllocatedUnfairLock(initialState: DeviceAttributor())

    /// Called from the event tap thread.
    func attribute(_ kind: DeviceAttributor.ReportKind, at time: TimeInterval) -> DeviceAttribution? {
        attributor.withLock { $0.attribute(kind: kind, at: time) }
    }

    func start() {
        guard manager == nil else { return }
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches: [[String: Int]] = [
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Mouse],
            [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: kHIDUsage_GD_Pointer],
        ]
        IOHIDManagerSetDeviceMatchingMultiple(manager, matches as CFArray)
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterDeviceMatchingCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue().added(device)
        }, context)
        IOHIDManagerRegisterDeviceRemovalCallback(manager, { context, _, _, device in
            guard let context else { return }
            Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue().removed(device)
        }, context)
        IOHIDManagerScheduleWithRunLoop(manager, CFRunLoopGetMain(), CFRunLoopMode.defaultMode.rawValue)
        self.manager = manager
        if let existing = IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice> {
            for device in existing { added(device) }
        }
        openIfAllowed()
    }

    /// Reading which device sent each click needs Input Monitoring. Whisker only asks when the user wants it.
    func requestIdentification() {
        if IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) != kIOHIDAccessTypeGranted {
            _ = IOHIDRequestAccess(kIOHIDRequestTypeListenEvent)
        }
        openIfAllowed()
    }

    private func openIfAllowed() {
        guard let manager, !opened, IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted else {
            canIdentifyDevices = opened
            return
        }
        let context = Unmanaged.passUnretained(self).toOpaque()
        IOHIDManagerRegisterInputValueCallback(manager, { context, _, sender, value in
            guard let context, let sender else { return }
            let device = Unmanaged<IOHIDDevice>.fromOpaque(sender).takeUnretainedValue()
            Unmanaged<DeviceMonitor>.fromOpaque(context).takeUnretainedValue().input(value, from: device)
        }, context)
        let result = IOHIDManagerOpen(manager, IOOptionBits(kIOHIDOptionsTypeNone))
        opened = result == kIOReturnSuccess
        canIdentifyDevices = opened
        Log.devices.info("Device identification \(self.opened ? "on" : "unavailable", privacy: .public)")
    }

    private func added(_ device: IOHIDDevice) {
        func property<T>(_ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }
        let vendor: Int = property(kIOHIDVendorIDKey) ?? 0
        let product: Int = property(kIOHIDProductIDKey) ?? 0
        let serial: String? = property(kIOHIDSerialNumberKey)
        let name: String? = property(kIOHIDProductKey)
        let transport: String? = property(kIOHIDTransportKey)
        let identity = DeviceIdentity(vendorID: vendor, productID: product, serial: serial)
        deviceIDs[device] = identity.id
        let entry = ConnectedDevice(
            id: identity.id,
            name: DeviceIdentity.displayName(product: name, vendorID: vendor, productID: product),
            vendorID: vendor, productID: product, serial: identity.serial, transport: transport,
            isExcluded: DeviceIdentity.isExcluded(transport: transport, product: name, vendorID: vendor)
        )
        guard !devices.contains(where: { $0.id == entry.id }) else { return }
        Log.devices.info("Connected \(entry.name, privacy: .public) [\(entry.id, privacy: .public)]\(entry.isExcluded ? " (left alone)" : "", privacy: .public)")
        devices.append(entry)
        devices.sort { $0.name.localizedStandardCompare($1.name) == .orderedAscending }
        changed()
    }

    private func removed(_ device: IOHIDDevice) {
        guard let id = deviceIDs.removeValue(forKey: device) else { return }
        // A receiver can expose the same mouse as several HID devices; keep it while any remain.
        guard !deviceIDs.values.contains(id) else { return }
        devices.removeAll { $0.id == id }
        Log.devices.info("Disconnected [\(id, privacy: .public)]")
        changed()
    }

    private func changed() {
        let usable = devices.filter { !$0.isExcluded }.map(\.id)
        attributor.withLock { $0.connected = usable }
        onChange?(devices)
    }

    private func input(_ value: IOHIDValue, from device: IOHIDDevice) {
        guard let id = deviceIDs[device], IOHIDValueGetIntegerValue(value) != 0 else { return }
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let kind: DeviceAttributor.ReportKind
        switch (page, usage) {
        case (kHIDPage_Button, 1...32): kind = .button(usage - 1)
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Wheel), (kHIDPage_Consumer, kHIDUsage_Csmr_ACPan): kind = .wheel
        default: return
        }
        let now = ProcessInfo.processInfo.systemUptime
        attributor.withLock { $0.record(deviceID: id, kind: kind, at: now) }
    }
}
