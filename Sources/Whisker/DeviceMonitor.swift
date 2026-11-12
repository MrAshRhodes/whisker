import Foundation
import IOKit.hid
import os
import WhiskerCore

/// A pointing device that is plugged in or paired right now.
typealias ConnectedDevice = PointingDevice

/// Watches mice come and go, and — when Input Monitoring is allowed — which one each click came from.
///
/// What the Devices pane explains (what a mouse reports, whether it sent input lately, whether Whisker is
/// listening) is read and published here on the main thread, apart from the event path: it never reaches
/// `onChange` or the attributor, and when it can't be read the pane just says so.
final class DeviceMonitor: ObservableObject, @unchecked Sendable {
    @Published private(set) var devices: [ConnectedDevice] = []
    /// Whether Whisker is listening for button and wheel reports. That is permission, not a promise about any one click.
    @Published private(set) var identification: IdentificationStatus = .notAllowed
    /// What each listed device reports it has, by device id.
    @Published private(set) var controls: [String: ControlsReport] = [:]
    /// Devices that sent a button or wheel report within `AttributionEvidence.window`.
    @Published private(set) var recentInput: Set<String> = []
    /// Best-effort battery state by device id. In memory only, and never reaches `onChange` or the event path.
    @Published private(set) var batteries: [String: BatteryState] = [:]
    var onChange: (([ConnectedDevice]) -> Void)?

    var canIdentifyDevices: Bool { identification == .listening }

    private var manager: IOHIDManager?
    /// Only matched, never opened: keyboards are watched just to tell a keyboard's mouse-keys interface from a mouse.
    private var keyboardManager: IOHIDManager?
    private var interfaces: [IOHIDDevice: HIDInterfaceInfo] = [:]
    /// What each pointing interface reported, before it is combined per listed device.
    private var interfaceControls: [IOHIDDevice: ControlsReport] = [:]
    /// The listed device each pointing interface belongs to, for attributing input.
    private var deviceIDs: [IOHIDDevice: String] = [:]
    private var opened = false
    private let attributor = OSAllocatedUnfairLock(initialState: DeviceAttributor())
    /// Movement reports arrive at the mouse's polling rate, so they are only kept while a mapping needs them.
    private let trackingMotion = OSAllocatedUnfairLock(initialState: false)
    /// Main thread only. One time per device, never saved or logged.
    private var evidence = AttributionEvidence()
    private var expiryTimer: Timer?
    private let hidAccess: HIDDeviceAccess
    private let batteryProvider: BatteryProvider
    /// The runtime id `hidAccess` gave each interface; never reused, so a late read can't reach a reconnected device.
    private var runtimeIDs: [IOHIDDevice: Int] = [:]
    private let inputMonitoringCheck: () -> Bool

    init(
        hidAccess: HIDDeviceAccess = IOKitHIDAccess(),
        inputMonitoringAllowed: @escaping () -> Bool = { DeviceMonitor.inputMonitoringAllowed }
    ) {
        self.hidAccess = hidAccess
        self.inputMonitoringCheck = inputMonitoringAllowed
        batteryProvider = BatteryProvider(
            access: hidAccess, clock: { DeviceMonitor.clock() },
            schedule: { delay, action in
                let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
                RunLoop.main.add(timer, forMode: .common)
                return { timer.invalidate() }
            }
        )
        batteryProvider.onChange = { [weak self] in self?.publishBatteries() }
    }

    /// Called from the event tap thread.
    func attribute(_ kind: DeviceAttributor.ReportKind, at time: TimeInterval) -> DeviceAttribution? {
        attributor.withLock { $0.attribute(kind: kind, at: time) }
    }

    /// Called from the event tap thread.
    func attributeMotion(at time: TimeInterval) -> DeviceAttribution? {
        attributor.withLock { $0.attributeMotion(at: time) }
    }

    func setTrackingMotion(_ tracking: Bool) {
        trackingMotion.withLock { $0 = tracking }
    }

    /// Details for the connected devices, for the Devices pane.
    var connectedDetails: [DeviceDetails] {
        DeviceDetailsBuilder.details(for: devices, controls: controls, identification: identification, recentInput: recentInput, batteries: batteries)
    }

    /// Limited details for a mouse with saved settings that isn't connected.
    func rememberedDetails(id: String, name: String) -> DeviceDetails {
        DeviceDetailsBuilder.remembered(id: id, name: name, identification: identification)
    }

    /// Battery state as the Devices pane shows it, for each connected device.
    private func publishBatteries() {
        let states = BatteryStates.states(
            for: devices, tracker: batteryProvider.tracker, at: Self.clock(), inputMonitoringAllowed: inputMonitoringCheck()
        )
        if states != batteries { batteries = states }
    }

    /// Hands the battery provider the listed devices and the interfaces that belong to each. Reads nothing
    /// until Input Monitoring is allowed.
    private func syncBatteries(_ listed: [ConnectedDevice]) {
        var byDevice: [String: [Int]] = [:]
        for (device, id) in deviceIDs {
            if let runtimeID = runtimeIDs[device] { byDevice[id, default: []].append(runtimeID) }
        }
        batteryProvider.update(devices: listed, interfaces: byDevice, allowed: inputMonitoringCheck())
    }

    func start() {
        guard manager == nil else { return }
        manager = makeManager(usages: [kHIDUsage_GD_Mouse, kHIDUsage_GD_Pointer])
        keyboardManager = makeManager(usages: [kHIDUsage_GD_Keyboard, kHIDUsage_GD_Keypad])
        for manager in [manager, keyboardManager].compactMap({ $0 }) {
            for device in (IOHIDManagerCopyDevices(manager) as? Set<IOHIDDevice>) ?? [] {
                interfaces[device] = Self.info(for: device)
                runtimeIDs[device] = hidAccess.register(device)
            }
        }
        readControls()
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
        guard let manager else { return }
        let granted = IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
        guard !opened, granted else {
            identification = IdentificationStatus(accessGranted: granted, listening: opened)
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
        identification = IdentificationStatus(accessGranted: true, listening: opened)
        Log.devices.info("Device identification \(self.opened ? "on" : "unavailable", privacy: .public)")
        // macOS may only describe a device's controls once the manager has opened it.
        if opened { refreshControls() }
        publishBatteries()
    }

    private func added(_ device: IOHIDDevice) {
        guard interfaces[device] == nil else { return }
        let info = Self.info(for: device)
        interfaces[device] = info
        runtimeIDs[device] = hidAccess.register(device)
        if info.isPointing { interfaceControls[device] = Self.report(for: device, allowed: Self.inputMonitoringAllowed) }
        refresh()
    }

    private func removed(_ device: IOHIDDevice) {
        guard interfaces.removeValue(forKey: device) != nil else { return }
        interfaceControls[device] = nil
        refresh()
        if let runtimeID = runtimeIDs.removeValue(forKey: device) { hidAccess.forget(runtimeID: runtimeID) }
    }

    /// Reads what every pointing interface reports again, for when the answer may have changed: Input
    /// Monitoring was allowed, or someone opened a device's details. Opens nothing and asks for no permission.
    func refreshControls() {
        readControls()
        publishControls()
        syncBatteries(devices)
        for id in devices.map(\.id) { batteryProvider.refresh(deviceID: id) }
    }

    private func readControls() {
        let allowed = Self.inputMonitoringAllowed
        for (device, info) in interfaces where info.isPointing {
            interfaceControls[device] = Self.report(for: device, allowed: allowed)
        }
    }

    private func publishControls() {
        var reports: [String: [ControlsReport]] = [:]
        for (device, id) in deviceIDs {
            reports[id, default: []].append(interfaceControls[device] ?? .unavailable(.notProvided))
        }
        let combined = reports.mapValues(ControlsReport.combine)
        if combined != controls { controls = combined }
    }

    static var inputMonitoringAllowed: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Whisker doesn't ask macOS to describe a device until Input Monitoring is allowed: it has to be the user
    /// who chooses to turn that on, and asking about an undetermined permission could prompt for it.
    private static func report(for device: IOHIDDevice, allowed: Bool) -> ControlsReport {
        allowed ? controls(for: device) : .unavailable(.inputMonitoringOff)
    }

    /// The elements an interface says it has. macOS hands back nothing for a device it won't describe, which is
    /// read as "unavailable" and never as "no buttons".
    static func controls(for device: IOHIDDevice) -> ControlsReport {
        let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
        return ControlsReport.read(elements?.map {
            HIDElementInfo(
                kind: HIDElementKind(ioKitType: Int(IOHIDElementGetType($0).rawValue)),
                usagePage: Int(IOHIDElementGetUsagePage($0)),
                usage: Int(IOHIDElementGetUsage($0))
            )
        })
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
        publishControls()
        pruneEvidence(keeping: Set(listed.map(\.id)))
        guard listed != devices else {
            syncBatteries(listed)
            return
        }
        let before = Set(devices.map(\.id)), after = Set(listed.map(\.id))
        for device in listed where !before.contains(device.id) {
            Log.devices.info("Connected \(device.name, privacy: .public) [\(device.id, privacy: .public)]\(device.isExcluded ? " (left alone)" : "", privacy: .public)")
        }
        for id in before.subtracting(after) {
            Log.devices.info("Disconnected [\(id, privacy: .public)]")
        }
        devices = listed
        syncBatteries(listed)
        changed()
    }

    private func changed() {
        let usable = devices.filter { !$0.isExcluded }.map(\.id)
        let excluded = Set(devices.filter(\.isExcluded).map(\.id))
        attributor.withLock {
            $0.connected = usable
            $0.excluded = excluded
        }
        onChange?(devices)
    }

    private func input(_ value: IOHIDValue, from device: IOHIDDevice) {
        let reported = IOHIDValueGetElement(value)
        if let runtimeID = runtimeIDs[device], BatteryDiscovery.isBatteryUsage(page: Int(IOHIDElementGetUsagePage(reported)), usage: Int(IOHIDElementGetUsage(reported))) {
            batteryProvider.notified(runtimeID: runtimeID)
            return
        }
        guard let id = deviceIDs[device], IOHIDValueGetIntegerValue(value) != 0 else { return }
        let element = IOHIDValueGetElement(value)
        let page = Int(IOHIDElementGetUsagePage(element))
        let usage = Int(IOHIDElementGetUsage(element))
        let kind: DeviceAttributor.ReportKind
        switch (page, usage) {
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_X), (kHIDPage_GenericDesktop, kHIDUsage_GD_Y):
            guard trackingMotion.withLock({ $0 }) else { return }
            let now = ProcessInfo.processInfo.systemUptime
            attributor.withLock { $0.recordMotion(deviceID: id, at: now) }
            return
        case (kHIDPage_Button, 1...32): kind = .button(usage - 1)
        case (kHIDPage_GenericDesktop, kHIDUsage_GD_Wheel), (kHIDPage_Consumer, kHIDUsage_Csmr_ACPan): kind = .wheel
        default: return
        }
        let now = ProcessInfo.processInfo.systemUptime
        attributor.withLock { $0.record(deviceID: id, kind: kind, at: now) }
        recordInput(from: id, at: Self.clock())
    }

    /// Keeps counting while the Mac sleeps, so input from before a sleep isn't still recent on waking.
    static func clock() -> TimeInterval { TimeInterval(clock_gettime_nsec_np(CLOCK_MONOTONIC_RAW)) / 1_000_000_000 }

    /// Notes that a device sent a button or wheel report. The pane only hears about it when the device becomes
    /// recent, so a busy mouse costs one timestamp update here and nothing more.
    func recordInput(from id: String, at now: TimeInterval) {
        guard evidence.record(deviceID: id, at: now) else { return }
        publishRecent(at: now)
    }

    /// Publishes which devices are recent as of `now`, if that changed, and waits for the next one to go stale.
    func publishRecent(at now: TimeInterval) {
        let recent = evidence.recent(at: now)
        if recent != recentInput { recentInput = recent }
        expiryTimer?.invalidate()
        expiryTimer = nil
        guard let due = evidence.nextExpiry(at: now) else { return }
        let timer = Timer(timeInterval: due - now + 0.1, repeats: false) { [weak self] _ in
            self?.publishRecent(at: Self.clock())
        }
        RunLoop.main.add(timer, forMode: .common)
        expiryTimer = timer
    }

    /// Forgets devices that are gone, so one that comes back has to send input again before it counts.
    func pruneEvidence(keeping connected: Set<String>, at now: TimeInterval = DeviceMonitor.clock()) {
        guard !evidence.isEmpty else { return }
        evidence.prune(keeping: connected, at: now)
        publishRecent(at: now)
    }
}
