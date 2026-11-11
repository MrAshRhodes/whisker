import Foundation
import IOKit.hid
import os
import WhiskerCore

/// A pointing device that is plugged in or paired right now.
typealias ConnectedDevice = PointingDevice

/// Watches mice come and go, and — when Input Monitoring is allowed — which one each click came from.
final class DeviceMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var devices: [ConnectedDevice] = []
    @Published private(set) var canIdentifyDevices = false
    var onChange: (([ConnectedDevice]) -> Void)?

    private var manager: IOHIDManager?
    /// Only matched, never opened: keyboards are watched just to tell a keyboard's mouse-keys interface from a mouse.
    private var keyboardManager: IOHIDManager?
    private var interfaces: [IOHIDDevice: HIDInterfaceInfo] = [:]
    /// The listed device each pointing interface belongs to, for attributing input.
    private var deviceIDs: [IOHIDDevice: String] = [:]
    private var opened = false
    private let attributor = OSAllocatedUnfairLock(initialState: DeviceAttributor())

    /// Called from the event tap thread.
    func attribute(_ kind: DeviceAttributor.ReportKind, at time: TimeInterval) -> DeviceAttribution? {
        attributor.withLock { $0.attribute(kind: kind, at: time) }
    }

    func start() {
        guard manager == nil else { return }
        manager = makeManager(usages: [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer])
        keyboardManager = makeManager(usages: [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad])
        for manager in [manager, keyboardManager].compactMap({ $0 }) {
            for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
                interfaces[device] = Self.info(for: device)
            }
        }
        refresh()
        openIfAllowed()
    }

    private func makeManager(usages: [Int]) -> IOHIDManager {
        let manager = IOHIDManagerCreate(kCFAllocatorDefault, IOOptionBits(kIOHIDOptionsTypeNone))
        let matches = usages.map { [kIOHIDDeviceUsagePageKey: kHIDPage_GenericDesktop, kIOHIDDeviceUsageKey: $0] }
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
        return manager
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
        guard interfaces[device] == nil else { return }
        interfaces[device] = Self.info(for: device)
        refresh()
    }

    private func removed(_ device: IOHIDDevice) {
        guard interfaces.removeValue(forKey: device) != nil else { return }
        refresh()
    }

    static func info(for device: IOHIDDevice) -> HIDInterfaceInfo {
        func property<T>(_ key: String) -> T? { IOHIDDeviceGetProperty(device, key as CFString) as? T }
        var interfaceNumber: Int?
        let service = IOHIDDeviceGetService(device)
        if service != IO_OBJECT_NULL {
            interfaceNumber = IORegistryEntrySearchCFProperty(
                service, kIOServicePlane, "bInterfaceNumber" as CFString, kCFAllocatorDefault,
                IOOptionBits(kIORegistryIterateRecursively | kIORegistryIterateParents)
            ) as? Int
        }
        return HIDInterfaceInfo(
            vendorID: property(kIOHIDVendorIDKey) ?? 0,
            productID: property(kIOHIDProductIDKey) ?? 0,
            serial: property(kIOHIDSerialNumberKey),
            product: property(kIOHIDProductKey),
            transport: property(kIOHIDTransportKey),
            locationID: property(kIOHIDLocationIDKey),
            interfaceNumber: interfaceNumber,
            primaryUsagePage: property(kIOHIDPrimaryUsagePageKey) ?? 0,
            primaryUsage: property(kIOHIDPrimaryUsageKey) ?? 0
        )
    }

    private func refresh() {
        let listed = PointingDeviceClassifier.pointingDevices(from: Array(interfaces.values))
        var owner: [String: String] = [:]
        for device in listed {
            for key in device.physicalKeys { owner[key] = device.id }
        }
        deviceIDs = interfaces.compactMapValues { $0.isPointing ? owner[$0.physicalKey] : nil }
        guard listed != devices else { return }
        let before = Set(devices.map(\.id)), after = Set(listed.map(\.id))
        for device in listed where !before.contains(device.id) {
            Log.devices.info("Connected \(device.name, privacy: .public) [\(device.id, privacy: .public)]\(device.isExcluded ? " (left alone)" : "", privacy: .public)")
        }
        for id in before.subtracting(after) {
            Log.devices.info("Disconnected [\(id, privacy: .public)]")
        }
        devices = listed
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
