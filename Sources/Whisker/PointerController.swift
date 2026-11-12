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

/// Where the controller reads the settings and writes a switch to: `SettingsStore` in the app, memory alone
/// where nothing needs to be saved.
@MainActor
protocol PointerSettingsSource: AnyObject {
    var settings: WhiskerSettings { get set }
}

extension SettingsStore: PointerSettingsSource {}

@MainActor
final class DetachedSettings: PointerSettingsSource {
    var settings: WhiskerSettings

    init(_ settings: WhiskerSettings = .default) {
        self.settings = settings
    }
}

/// Applies per-device pointer speed and acceleration by writing to the device's HID event service, and puts
/// the original values back when settings are cleared or Whisker quits.
///
/// Every route that changes a speed on purpose goes through here, so they share one confirmation and one
/// rollback: the slider in the Pointer pane, the menu bar and a mapped button. Nothing else writes to a device.
@MainActor
final class PointerController: ObservableObject {
    /// A big speed increase waiting to be kept; it reverts on its own unless confirmed.
    struct PendingChange: Equatable {
        var deviceID: String
        /// The last confirmed speed and preset: what Revert and the timeout put back.
        var previous: PointerSelection
        /// What is applied while the change waits.
        var proposed: PointerSelection
        var deadline: Date
    }

    /// What a request to switch to a preset led to.
    enum Outcome: Equatable {
        case applied
        /// Applied for now; it reverts unless it is kept.
        case awaitingConfirmation
        case alreadyActive
        case rejected(PointerPresetRefusal)
    }

    /// Something the Pointer pane should tell the user: why a switch didn't happen, or what went wrong.
    struct Notice: Equatable {
        var deviceID: String?
        var message: String
    }

    /// A slider drag in progress, with the confirmed speed to compare against when it ends.
    private struct SpeedEdit {
        var deviceID: String
        var baseline: PointerSelection
    }

    @Published private(set) var pending: PendingChange?
    /// Devices whose service refused a write, so the Pointer pane can say speed can't be changed.
    @Published private(set) var unsupported: Set<String> = []
    /// Devices whose original pointer values couldn't be put back, so Whisker can say its values may still be
    /// in use. The originals stay on record and the restore is tried again.
    @Published private(set) var restoreFailures: Set<String> = []
    @Published private(set) var notice: Notice?
    /// Whether an app on the bypass list was in front when settings were last applied. Nothing is written to a
    /// device then, whichever route asks, and presets can't be switched.
    @Published private(set) var isBypassed = false

    /// What was last written to a device, and to which services, so unchanged settings aren't rewritten.
    private struct Applied: Equatable {
        var pointer: PointerSettings?
        var services: Set<UInt64>
    }

    private let hardware: PointerHardware
    private let store: PointerSettingsSource
    private let connected: () -> [ConnectedDevice]
    private let confirmationTimeout: TimeInterval
    /// What Whisker found on each device before changing it. A record stays until the values are back.
    private(set) var originals: [String: OriginalPointer]
    private var applied: [String: Applied] = [:]
    @Published private var speedEdit: SpeedEdit?
    private var revertTimer: Timer?
    var onOriginalsChange: (([String: OriginalPointer]) -> Void)?
    /// Asked to bring the Pointer pane forward: a change is waiting to be kept, or the system refused one.
    var onAttention: (() -> Void)?

    /// Whether a speed change is waiting or being dragged, so no other can start.
    var isBusy: Bool { pending != nil || speedEdit != nil }

    init(
        originals: [String: OriginalPointer] = [:],
        hardware: PointerHardware = IOHIDPointerHardware(),
        store: PointerSettingsSource? = nil,
        connected: @escaping () -> [ConnectedDevice] = { [] },
        confirmationTimeout: TimeInterval = PointerMath.confirmationTimeout
    ) {
        self.originals = originals
        self.hardware = hardware
        self.store = store ?? DetachedSettings()
        self.connected = connected
        self.confirmationTimeout = confirmationTimeout
    }

    /// Writes the settings for every connected device; restores devices whose pointer settings were cleared or
    /// switched off, including while Whisker as a whole is switched off.
    ///
    /// While `bypassed` (an app on the bypass list is in front) nothing is wanted, so every device gets its
    /// original values back; the latest settings are written when the app leaves the front. Writes happen
    /// synchronously on the main actor, so whichever call comes last decides what the device ends up with.
    ///
    /// A device is written again after it disconnects or its services change, and after a failed write or restore.
    /// It never changes `store`: the store publishes before it stores, so a change here would be lost.
    func apply(_ settings: WhiskerSettings, connected: [ConnectedDevice], bypassed: Bool = false) {
        if isBypassed != bypassed { isBypassed = bypassed }
        let present = Set(connected.filter { !$0.isExcluded }.map(\.id))
        applied = applied.filter { present.contains($0.key) }
        for device in connected where !device.isExcluded {
            let wanted = bypassed ? nil : settings.activePointer(for: device.id)
            let target = Applied(pointer: wanted, services: hardware.serviceIDs(for: device.id))
            guard applied[device.id] != target else { continue }
            if let wanted {
                guard write(wanted, to: device) else {
                    applied[device.id] = nil
                    continue
                }
            } else if originals[device.id] != nil {
                // Left unapplied, so the next call tries again.
                guard restore(device.id) else { continue }
            }
            applied[device.id] = target
        }
    }

    /// Applies the stored settings to the connected mice again, in the state `apply` last saw.
    private func reapply() {
        apply(store.settings, connected: connected(), bypassed: isBypassed)
    }

    /// Mice came or went. A change that was waiting on a mouse that is gone is dropped, so that when the
    /// mouse comes back only the last confirmed speed is written to it.
    func devicesChanged(_ connected: [ConnectedDevice], bypassed: Bool = false) {
        if isBypassed != bypassed { isBypassed = bypassed }
        if let edit = speedEdit,
           PointerPresetRefusal.targetRefusal(deviceID: edit.deviceID, connected: connected) != nil {
            speedEdit = nil
            setSelection(edit.baseline, on: edit.deviceID)
        }
        if let pending, PointerPresetRefusal.targetRefusal(deviceID: pending.deviceID, connected: connected) != nil {
            revertPending()
        }
        apply(store.settings, connected: connected, bypassed: isBypassed)
    }

    /// Puts back every value Whisker changed. A device that refuses keeps its record, so the values are
    /// remembered for the next launch.
    func restoreAll() {
        for id in Array(originals.keys) { restore(id) }
        applied.removeAll()
    }

    /// Puts back values recorded by a previous run that didn't quit cleanly.
    func restoreLeftovers(connected: [ConnectedDevice]) {
        let ids = Set(connected.map(\.id))
        for id in Array(originals.keys) where ids.contains(id) { restore(id) }
    }

    // MARK: Switching presets

    /// Why a switch to the preset can't go ahead right now, nil when it can: the checks `selectPreset` makes
    /// before it changes anything, so the pane and the menu bar can grey out what would be refused.
    func refusal(forPreset presetID: String, on deviceID: String) -> PointerPresetRefusal? {
        if isBusy { return .confirmationPending }
        if isBypassed { return .appBypassed }
        return store.settings.pointerPresetRefusal(deviceID: deviceID, presetID: presetID, connected: connected())
    }

    /// Switches a device to one of its saved presets: the single path for the Pointer pane, the menu bar and
    /// a mapped button. Nothing changes unless the switch is allowed (`PointerPresetRefusal`); a switch the
    /// system refuses is rolled back; a big increase waits to be kept (`pending`).
    @discardableResult
    func selectPreset(_ presetID: String, on deviceID: String) -> Outcome {
        if let refusal = refusal(forPreset: presetID, on: deviceID) {
            return reject(refusal, on: deviceID, attention: refusal == .confirmationPending && pending != nil)
        }
        let before = store.settings
        guard var device = before.devices[deviceID] else { return reject(.unknownDevice, on: deviceID) }
        let baseline = device.pointerSelection
        guard device.selectPointerPreset(id: presetID) else { return reject(.unknownPreset, on: deviceID) }
        guard device.pointerSelection != baseline else { return .alreadyActive }

        var updated = before
        updated.devices[deviceID] = device
        store.settings = updated
        reapply()
        guard !refused(deviceID) else {
            return reject(rollBack(to: baseline, on: deviceID), on: deviceID, attention: true)
        }
        clearNotice(for: deviceID)
        let speed = device.pointer?.speed ?? 1
        guard PointerMath.needsConfirmation(confirmed: baseline.pointer?.speed ?? 1, new: speed) else { return .applied }
        beginConfirmation(deviceID: deviceID, previous: baseline)
        onAttention?()
        return .awaitingConfirmation
    }

    /// The Pointer pane's custom speed switch turned off: back to the system's own speed. Allowed while a
    /// change is waiting, which it cancels for this device.
    func useSystemSettings(on deviceID: String) {
        if pending?.deviceID == deviceID { cancelPending() }
        if speedEdit?.deviceID == deviceID { speedEdit = nil }
        var settings = store.settings
        guard var device = settings.devices[deviceID] else { return }
        device.useSystemPointer()
        settings.devices[deviceID] = device
        store.settings = settings
        reapply()
        guard originals[deviceID] != nil, connected().contains(where: { $0.id == deviceID && !$0.isExcluded }) else {
            clearNotice(for: deviceID)
            return
        }
        notify(.restoreFailed, on: deviceID)
    }

    // MARK: Slider

    /// A slider drag starts. What is confirmed now is what a big jump reverts to.
    func beginSpeedEdit(on deviceID: String) {
        endSpeedEdit()
        guard pending == nil, let device = store.settings.devices[deviceID] else { return }
        speedEdit = SpeedEdit(deviceID: deviceID, baseline: device.pointerSelection)
    }

    /// The slider drag ended: the speed it reached is rolled back if the system refused it, and waits to be
    /// kept if it is a big increase.
    func endSpeedEdit() {
        guard let edit = speedEdit else { return }
        speedEdit = nil
        guard let selection = store.settings.devices[edit.deviceID]?.pointerSelection, selection != edit.baseline else { return }
        if refused(edit.deviceID) {
            notify(rollBack(to: edit.baseline, on: edit.deviceID), on: edit.deviceID)
        } else if PointerMath.needsConfirmation(confirmed: edit.baseline.pointer?.speed ?? 1, new: selection.pointer?.speed ?? 1) {
            beginConfirmation(deviceID: edit.deviceID, previous: edit.baseline)
        }
    }

    // MARK: Confirmation

    private func beginConfirmation(deviceID: String, previous: PointerSelection) {
        guard let proposed = store.settings.devices[deviceID]?.pointerSelection else { return }
        revertTimer?.invalidate()
        let deadline = Date().addingTimeInterval(confirmationTimeout)
        pending = PendingChange(deviceID: deviceID, previous: previous, proposed: proposed, deadline: deadline)
        revertTimer = Timer.scheduledTimer(withTimeInterval: confirmationTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.revertPending() }
        }
    }

    /// The waiting speed is now the confirmed one.
    func confirmPending() {
        cancelPending()
    }

    /// Puts back the last confirmed speed and preset. Also what the timeout does.
    func revertPending() {
        guard let change = pending else { return }
        cancelPending()
        Log.pointer.info("Pointer speed change not confirmed; reverting \(change.deviceID, privacy: .public)")
        // Only while the speed is still the proposed one: a settings import or reset since is left alone.
        if store.settings.devices[change.deviceID]?.pointer?.speed == change.proposed.pointer?.speed {
            setSelection(change.previous, on: change.deviceID)
        }
        reapply()
        if refused(change.deviceID), connected().contains(where: { $0.id == change.deviceID && !$0.isExcluded }) {
            notify(.restoreFailed, on: change.deviceID)
        }
    }

    func dismissNotice() {
        notice = nil
    }

    private func cancelPending() {
        revertTimer?.invalidate()
        revertTimer = nil
        pending = nil
    }

    /// Whether the system refused the latest write to the device: a new speed, or the original values.
    private func refused(_ deviceID: String) -> Bool {
        unsupported.contains(deviceID) || restoreFailures.contains(deviceID)
    }

    /// The system refused a new speed, or only part of it: writes the confirmed one back to every service.
    /// `.restoreFailed` when even that is refused; the original values are kept and written again later.
    private func rollBack(to previous: PointerSelection, on deviceID: String) -> PointerPresetRefusal {
        setSelection(previous, on: deviceID)
        reapply()
        let refusal: PointerPresetRefusal = refused(deviceID) ? .restoreFailed : .hardwareRefused
        Log.pointer.error("Pointer speed for \(deviceID, privacy: .public) was refused (\(String(describing: refusal), privacy: .public)); rolled back")
        return refusal
    }

    /// Sets a device's speed and preset back to a confirmed selection. A preset deleted since is dropped.
    private func setSelection(_ selection: PointerSelection, on deviceID: String) {
        var settings = store.settings
        guard var device = settings.devices[deviceID] else { return }
        var selection = selection
        if let id = selection.presetID, device.pointerPreset(id: id) == nil { selection.presetID = nil }
        device.pointerSelection = selection
        settings.devices[deviceID] = device
        store.settings = settings
    }

    // MARK: Notices

    private func reject(_ refusal: PointerPresetRefusal, on deviceID: String, attention: Bool = false) -> Outcome {
        // The Keep/Revert banner already explains a switch refused while one is waiting.
        if refusal != .confirmationPending { notify(refusal, on: deviceID) }
        if attention { onAttention?() }
        return .rejected(refusal)
    }

    private func notify(_ refusal: PointerPresetRefusal, on deviceID: String) {
        let name = connected().first { $0.id == deviceID }?.name ?? store.settings.devices[deviceID]?.name ?? ""
        notice = Notice(deviceID: deviceID, message: refusal.message(device: name))
    }

    private func clearNotice(for deviceID: String) {
        if notice?.deviceID == deviceID { notice = nil }
    }

    // MARK: Writing

    private func write(_ pointer: PointerSettings, to device: ConnectedDevice) -> Bool {
        guard let current = hardware.currentValues(of: device.id) else {
            unsupported.insert(device.id)
            Log.pointer.notice("No pointer service found for \(device.id, privacy: .public)")
            return false
        }
        var recordedNow = false
        if originals[device.id] == nil {
            originals[device.id] = current
            onOriginalsChange?(originals)
            recordedNow = true
        }
        let native = originals[device.id]?.resolution.map { PointerMath.fromIOFixed($0) }
        let resolution = PointerMath.ioFixed(PointerMath.resolution(forSpeed: pointer.speed, nativeResolution: native))
        let acceleration = PointerMath.ioFixed(PointerMath.acceleration(pointer.acceleration, linear: pointer.linear))
        if hardware.write(resolution: Int64(resolution), acceleration: Int64(acceleration), to: device.id) {
            clearFailures(for: device.id)
            Log.pointer.info("Pointer for \(device.id, privacy: .public): speed \(pointer.speed), acceleration \(pointer.linear ? -1 : pointer.acceleration)")
            return true
        }
        unsupported.insert(device.id)
        Log.pointer.error("The system refused pointer settings for \(device.id, privacy: .public)")
        // A first write that was refused without changing anything leaves nothing to put back later.
        if recordedNow, hardware.currentValues(of: device.id) == current {
            originals[device.id] = nil
            onOriginalsChange?(originals)
        }
        return false
    }

    /// Puts a device's own values back. When the system refuses, the record stays (so a later attempt, or the
    /// next launch, can finish the job) and the device is reported in `restoreFailures`.
    @discardableResult
    private func restore(_ deviceID: String) -> Bool {
        guard let original = originals[deviceID] else { return true }
        applied[deviceID] = nil
        // A device that is gone took the values Whisker wrote with it.
        if !hardware.serviceIDs(for: deviceID).isEmpty {
            let resolution = original.resolution ?? Int64(PointerMath.ioFixed(PointerMath.standardResolution))
            guard hardware.write(resolution: resolution, acceleration: original.acceleration, to: deviceID) else {
                restoreFailures.insert(deviceID)
                Log.pointer.error("Couldn’t put the pointer back for \(deviceID, privacy: .public); keeping its original values on record")
                return false
            }
        }
        originals[deviceID] = nil
        clearFailures(for: deviceID)
        onOriginalsChange?(originals)
        Log.pointer.info("Restored pointer for \(deviceID, privacy: .public)")
        return true
    }

    /// The system took a write for the device, or there is nothing left to write: what it refused before, and
    /// the notice about it, no longer stand.
    private func clearFailures(for deviceID: String) {
        let hadWriteFailure = unsupported.remove(deviceID) != nil
        let hadRestoreFailure = restoreFailures.remove(deviceID) != nil
        if hadWriteFailure || hadRestoreFailure { clearNotice(for: deviceID) }
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
