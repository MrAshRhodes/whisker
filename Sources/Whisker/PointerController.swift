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
/// where nothing needs to be saved. Only confirmed selections are ever written here.
@MainActor
protocol PointerSettingsSource: AnyObject {
    var settings: WhiskerSettings { get set }
    /// Writes the settings out now rather than shortly.
    func saveNow()
}

extension SettingsStore: PointerSettingsSource {}

@MainActor
final class DetachedSettings: PointerSettingsSource {
    var settings: WhiskerSettings

    init(_ settings: WhiskerSettings = .default) {
        self.settings = settings
    }

    func saveNow() {}
}

/// A speed change that has to be kept, written down before it reaches the mouse so that the next launch
/// knows it never was, whether Whisker crashed, was force quit or the Mac restarted.
struct PointerTrialRecord: Codable, Equatable {
    static let currentVersion = 1

    struct Pointer: Codable, Equatable {
        var speed: Double
        var acceleration: Double
        var linear: Bool
    }

    /// A `PointerSelection` as written to disk.
    struct Selection: Codable, Equatable {
        /// Nil is the system's own speed.
        var pointer: Pointer?
        var presetID: String?

        init(_ selection: PointerSelection) {
            pointer = selection.pointer.map { Pointer(speed: $0.speed, acceleration: $0.acceleration, linear: $0.linear) }
            presetID = selection.presetID
        }

        var selection: PointerSelection {
            PointerSelection(
                pointer: pointer.map { PointerSettings(speed: $0.speed, acceleration: $0.acceleration, linear: $0.linear) },
                presetID: presetID
            )
        }

        /// The selection, or nil when a value is outside what Whisker would ever write.
        var validSelection: PointerSelection? {
            if let pointer {
                guard pointer.speed.isFinite, PointerMath.speedRange.contains(pointer.speed),
                      pointer.acceleration.isFinite, PointerMath.accelerationRange.contains(pointer.acceleration)
                else { return nil }
            }
            return selection
        }
    }

    var version = PointerTrialRecord.currentVersion
    var deviceID: String
    /// The last confirmed speed and preset, from before the first unconfirmed value was applied.
    var confirmed: Selection
    /// What is waiting to be kept; nil while a slider drag is still choosing it.
    var trial: Selection?
    var startedAt: Date
}

/// What `PointerTrialJournal.loadPointerTrial()` found.
enum PointerTrialJournalEntry: Equatable {
    case empty
    case record(PointerTrialRecord)
    /// Something is there but can't be read, or is from another version: nothing in it is trusted.
    case unreadable
}

/// Where an unconfirmed speed change is written down: `pointer-trial.json` next to the settings in the app,
/// memory in tests. A save must be complete (atomic) when it returns.
@MainActor
protocol PointerTrialJournal: AnyObject {
    func loadPointerTrial() -> PointerTrialJournalEntry
    func savePointerTrial(_ record: PointerTrialRecord) throws
    func clearPointerTrial() throws
}

extension SettingsStore: PointerTrialJournal {}

/// Applies per-device pointer speed and acceleration by writing to the device's HID event service, and puts
/// the original values back when settings are cleared or Whisker quits.
///
/// Every route that changes a speed on purpose goes through here, so they share one confirmation and one
/// rollback: the slider in the Pointer pane, the menu bar and a mapped button. Nothing else writes to a device.
///
/// Unconfirmed values (a slider drag, a change waiting to be kept) live only in memory and on the mouse; the
/// settings store only ever receives confirmed selections. A change that has to be kept is also written to the
/// `PointerTrialJournal` before it reaches the mouse, and `recoverInterruptedTrial()` deals with one left behind.
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
        fileprivate var services: Set<UInt64>
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

    /// What launch recovery found left behind by the previous run.
    enum InterruptedTrial: Equatable {
        /// A change on the device was never kept; its last confirmed selection stands.
        case reverted(deviceID: String)
        /// A record was there but couldn't be trusted; the saved settings are used as they are.
        case unreadable
    }

    /// A slider drag in progress, with the confirmed speed to compare against when it ends.
    private struct SpeedEdit {
        var deviceID: String
        var baseline: PointerSelection
        var proposed: PointerSelection
        var services: Set<UInt64>
        /// Its unconfirmed speed couldn't be written down, so the rest of the drag is ignored.
        var stopped = false
    }

    @Published private(set) var pending: PendingChange? {
        didSet {
            onSlowPointerAvailabilityChange?()
            settleTrialRecord()
        }
    }
    /// Devices whose service refused a write, so the Pointer pane can say speed can't be changed.
    @Published private(set) var unsupported: Set<String> = []
    /// Devices whose original pointer values couldn't be put back, so Whisker can say its values may still be
    /// in use. The originals stay on record and the restore is tried again.
    @Published private(set) var restoreFailures: Set<String> = []
    @Published private(set) var notice: Notice?
    /// Whether an app on the bypass list was in front when settings were last applied. Nothing is written to a
    /// device then, whichever route asks, and presets can't be switched.
    @Published private(set) var isBypassed = false
    @Published private(set) var slowPointerFactors: [String: Double] = [:]
    private var slowPointerGeneration: UInt64 = 0
    private var blockedSlowPointer: [String: UInt64] = [:]
    private var slowPointerSessions: [String: UInt64] = [:]
    private var slowPointerRestorations: Set<String> = []
    private var latestSettings: WhiskerSettings = .default

    /// What was last written to a device, and to which services, so unchanged settings aren't rewritten.
    private struct Applied: Equatable {
        var pointer: PointerSettings?
        var services: Set<UInt64>
    }

    private let hardware: PointerHardware
    private let store: PointerSettingsSource
    private let journal: PointerTrialJournal?
    private let now: () -> Date
    private let connected: () -> [ConnectedDevice]
    private let confirmationTimeout: TimeInterval
    /// What Whisker found on each device before changing it. A record stays until the values are back.
    private(set) var originals: [String: OriginalPointer]
    private var applied: [String: Applied] = [:]
    @Published private var speedEdit: SpeedEdit? {
        didSet {
            onSlowPointerAvailabilityChange?()
            settleTrialRecord()
        }
    }
    /// What is in the journal for the change in progress.
    private var journaled: PointerTrialRecord?
    private var revertTimer: Timer?
    var onOriginalsChange: (([String: OriginalPointer]) -> Void)?
    /// Asked to bring the Pointer pane forward: a change is waiting to be kept, or the system refused one.
    var onAttention: (() -> Void)?
    var onSlowPointerAvailabilityChange: (() -> Void)?

    /// Whether a speed change is waiting or being dragged, so no other can start.
    var isBusy: Bool { pending != nil || speedEdit != nil }

    /// The live selection shown by controls; only the confirmed selection belongs in saved settings.
    func selection(on deviceID: String) -> PointerSelection {
        if let pending, pending.deviceID == deviceID { return pending.proposed }
        if let speedEdit, speedEdit.deviceID == deviceID { return speedEdit.proposed }
        return store.settings.devices[deviceID]?.pointerSelection ?? .system
    }

    var slowPointerDevices: Set<String> {
        Set(connected().filter { slowPointerUnavailable(on: $0.id) == nil }.map(\.id))
    }

    func slowPointerUnavailable(on deviceID: String) -> String? {
        if isBypassed { return "Whisker is bypassed for the app in front." }
        if isBusy { return "Finish or revert the pointer speed edit first." }
        if let refusal = PointerPresetRefusal.targetRefusal(deviceID: deviceID, connected: connected()) {
            return refusal.message(device: latestSettings.devices[deviceID]?.name ?? "")
        }
        guard latestSettings.activePointer(for: deviceID) != nil else {
            return "Enable Whisker and custom pointer speed for this mouse first."
        }
        guard !refused(deviceID), applied[deviceID]?.pointer != nil,
              applied[deviceID]?.services == hardware.serviceIDs(for: deviceID),
              !hardware.serviceIDs(for: deviceID).isEmpty else {
            return "A supported pointer service and an applied Whisker baseline are needed."
        }
        return nil
    }

    /// Only the engine's newest full begin/end state is accepted. This never edits saved settings.
    func applySlowPointer(_ command: SlowPointerCommand) {
        guard command.generation > slowPointerGeneration else { return }
        slowPointerGeneration = command.generation
        blockedSlowPointer = blockedSlowPointer.filter { command.factors[$0.key] != nil }
        slowPointerSessions = command.sessions
        var accepted: [String: Double] = [:]
        for (id, factor) in command.factors {
            guard let session = command.sessions[id] else { continue }
            guard SlowPointer.isValid(factor), blockedSlowPointer[id] != session,
                  slowPointerUnavailable(on: id) == nil else {
                blockedSlowPointer[id] = session
                continue
            }
            blockedSlowPointer[id] = nil
            accepted[id] = factor
        }
        slowPointerRestorations.formUnion(Set(slowPointerFactors.keys).subtracting(accepted.keys))
        slowPointerFactors = accepted
        reapply()
    }

    init(
        originals: [String: OriginalPointer] = [:],
        hardware: PointerHardware = IOHIDPointerHardware(),
        store: PointerSettingsSource? = nil,
        journal: PointerTrialJournal? = nil,
        connected: @escaping () -> [ConnectedDevice] = { [] },
        confirmationTimeout: TimeInterval = PointerMath.confirmationTimeout,
        now: @escaping () -> Date = Date.init
    ) {
        self.originals = originals
        self.hardware = hardware
        self.store = store ?? DetachedSettings()
        self.journal = journal
        self.connected = connected
        self.confirmationTimeout = confirmationTimeout
        self.now = now
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
        latestSettings = settings
        if isBypassed != bypassed { isBypassed = bypassed }
        if let pending, !canContinuePreview(
            pending.previous, on: pending.deviceID, services: pending.services, settings: settings, connected: connected
        ) {
            cancelPending()
        }
        if let speedEdit, !canContinuePreview(
            speedEdit.baseline, on: speedEdit.deviceID, services: speedEdit.services, settings: settings, connected: connected
        ) {
            self.speedEdit = nil
        }
        let present = Set(connected.filter { !$0.isExcluded }.map(\.id))
        for id in Array(slowPointerFactors.keys) {
            if bypassed || !present.contains(id) || settings.activePointer(for: id) == nil
                || applied[id]?.services != hardware.serviceIDs(for: id)
                || PointerPresetRefusal.targetRefusal(deviceID: id, connected: connected) != nil {
                slowPointerFactors[id] = nil
                blockedSlowPointer[id] = slowPointerSessions[id]
                slowPointerRestorations.insert(id)
            }
        }
        applied = applied.filter { present.contains($0.key) }
        for device in connected where !device.isExcluded {
            var baseline = bypassed ? nil : settings.activePointer(for: device.id)
            if baseline != nil, let pending, pending.deviceID == device.id,
               settings.devices[device.id]?.pointerSelection == pending.previous {
                baseline = pending.proposed.pointer
            }
            if baseline != nil, let speedEdit, speedEdit.deviceID == device.id,
               settings.devices[device.id]?.pointerSelection == speedEdit.baseline {
                baseline = speedEdit.proposed.pointer
            }
            let wanted = baseline.map { pointer in
                slowPointerFactors[device.id].map { SlowPointer.applying($0, to: pointer) } ?? pointer
            }
            let target = Applied(pointer: wanted, services: hardware.serviceIDs(for: device.id))
            guard applied[device.id] != target else { continue }
            if let wanted {
                guard write(wanted, to: device) else {
                    applied[device.id] = nil
                    if slowPointerFactors.removeValue(forKey: device.id) != nil, let baseline {
                        blockedSlowPointer[device.id] = slowPointerSessions[device.id]
                        slowPointerRestorations.insert(device.id)
                        if write(baseline, to: device) {
                            applied[device.id] = Applied(pointer: baseline, services: target.services)
                            slowPointerRestorations.remove(device.id)
                            notify(.hardwareRefused, on: device.id)
                            continue
                        }
                    }
                    if pending?.deviceID == device.id, let confirmed = settings.activePointer(for: device.id) {
                        cancelPending()
                        if write(confirmed, to: device) {
                            applied[device.id] = Applied(pointer: confirmed, services: target.services)
                            slowPointerRestorations.remove(device.id)
                            notify(.hardwareRefused, on: device.id)
                        } else {
                            restoreFailures.insert(device.id)
                            notify(.restoreFailed, on: device.id)
                        }
                        continue
                    }
                    if slowPointerRestorations.contains(device.id) {
                        restoreFailures.insert(device.id)
                        notify(.restoreFailed, on: device.id)
                    }
                    continue
                }
            } else if originals[device.id] != nil {
                // Left unapplied, so the next call tries again.
                guard restore(device.id) else {
                    if slowPointerRestorations.contains(device.id) { notify(.restoreFailed, on: device.id) }
                    continue
                }
            }
            slowPointerRestorations.remove(device.id)
            applied[device.id] = target
        }
    }

    /// Applies the stored settings to the connected mice again, in the state `apply` last saw.
    private func reapply() {
        apply(store.settings, connected: connected(), bypassed: isBypassed)
    }

    private func canContinuePreview(
        _ baseline: PointerSelection, on deviceID: String, services: Set<UInt64>,
        settings: WhiskerSettings, connected: [ConnectedDevice]
    ) -> Bool {
        settings.activePointer(for: deviceID) != nil
            && settings.devices[deviceID]?.pointerSelection == baseline
            && !services.isEmpty && services == hardware.serviceIDs(for: deviceID)
            && PointerPresetRefusal.targetRefusal(deviceID: deviceID, connected: connected) == nil
    }

    /// Mice came or went. A change that was waiting on a mouse that is gone is dropped, so that when the
    /// mouse comes back only the last confirmed speed is written to it.
    func devicesChanged(_ connected: [ConnectedDevice], bypassed: Bool = false) {
        if isBypassed != bypassed { isBypassed = bypassed }
        if let edit = speedEdit,
           PointerPresetRefusal.targetRefusal(deviceID: edit.deviceID, connected: connected) != nil {
            speedEdit = nil
        }
        if let pending, PointerPresetRefusal.targetRefusal(deviceID: pending.deviceID, connected: connected) != nil {
            revertPending()
        }
        apply(store.settings, connected: connected, bypassed: isBypassed)
    }

    /// Puts back every value Whisker changed. A device that refuses keeps its record, so the values are
    /// remembered for the next launch.
    func restoreAll() {
        cancelPending()
        speedEdit = nil
        for id in slowPointerFactors.keys { blockedSlowPointer[id] = slowPointerSessions[id] }
        slowPointerFactors.removeAll()
        for id in Array(originals.keys) { restore(id) }
        applied.removeAll()
    }

    /// Puts back values recorded by a previous run that didn't quit cleanly.
    func restoreLeftovers(connected: [ConnectedDevice]) {
        let ids = Set(connected.map(\.id))
        for id in Array(originals.keys) where ids.contains(id) { restore(id) }
    }

    /// Runs once at launch, before anything is written to a mouse. A record left in the journal means the
    /// previous run stopped (a crash, force quit or restart) while a change waited to be kept.
    ///
    /// Saved settings only ever hold confirmed selections, so they are what gets applied; nothing in the record
    /// is ever written to a mouse. Should the unconfirmed selection have reached the settings anyway, the
    /// record's confirmed one is put back, or the system's own speed when that copy isn't valid. The record is
    /// removed only after that is saved, so a recovery cut short runs again to the same result.
    @discardableResult
    func recoverInterruptedTrial() -> InterruptedTrial? {
        guard let journal else { return nil }
        let found: InterruptedTrial
        switch journal.loadPointerTrial() {
        case .empty:
            return nil
        case .unreadable:
            Log.pointer.error("An unconfirmed pointer change was left on record but can’t be read; using the saved pointer settings")
            found = .unreadable
            notice = Notice(
                deviceID: nil,
                message: "Whisker stopped before a pointer speed change was kept. Its record couldn’t be read, so the saved speeds are in use."
            )
        case .record(let record):
            found = .reverted(deviceID: record.deviceID)
            var settings = store.settings
            if var device = settings.devices[record.deviceID], let trial = record.trial?.selection,
               trial != record.confirmed.selection, device.pointerSelection == trial {
                var confirmed = record.confirmed.validSelection ?? .system
                if let id = confirmed.presetID, device.pointerPreset(id: id) == nil { confirmed.presetID = nil }
                device.pointerSelection = confirmed
                settings.devices[record.deviceID] = device
                store.settings = settings
                store.saveNow()
            }
            Log.pointer.notice("A pointer change for \(record.deviceID, privacy: .public) was never kept; the confirmed speed stands")
            let name = settings.devices[record.deviceID]?.name ?? ""
            notice = Notice(
                deviceID: record.deviceID,
                message: "Whisker stopped before the new speed for \(name.isEmpty ? "this mouse" : name) was kept, so the last kept speed is in use."
            )
        }
        do {
            try journal.clearPointerTrial()
        } catch {
            Log.pointer.error("Couldn’t remove the pointer change record: \(error.localizedDescription, privacy: .public)")
        }
        journaled = nil
        return found
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

        let services = hardware.serviceIDs(for: deviceID)
        var updated = before
        updated.devices[deviceID] = device
        let needsConfirmation = PointerMath.needsConfirmation(
            confirmed: baseline.pointer?.speed ?? 1, new: device.pointer?.speed ?? 1
        )
        if needsConfirmation, !recordTrial(on: deviceID, confirmed: baseline, trial: device.pointerSelection) {
            return reject(.trialNotRecorded, on: deviceID, attention: true)
        }
        // Trial writes never enter the store: a crash can only reload a confirmed selection.
        apply(updated, connected: connected(), bypassed: isBypassed)
        guard !refused(deviceID) else {
            let refusal = rollBack(to: baseline, on: deviceID)
            settleTrialRecord()
            return reject(refusal, on: deviceID, attention: true)
        }
        clearNotice(for: deviceID)
        guard needsConfirmation else {
            store.settings = updated
            reapply()
            return .applied
        }
        beginConfirmation(deviceID: deviceID, previous: baseline, proposed: device.pointerSelection, services: services)
        reapply()
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
        if speedEdit?.deviceID == deviceID { return }
        endSpeedEdit()
        guard pending == nil, let device = store.settings.devices[deviceID], device.pointer != nil else { return }
        speedEdit = SpeedEdit(
            deviceID: deviceID, baseline: device.pointerSelection, proposed: device.pointerSelection,
            services: hardware.serviceIDs(for: deviceID)
        )
    }

    /// Slider values stay in memory until the drag ends and, for a big increase, Keep is chosen.
    /// Keyboard/accessibility adjustments without drag callbacks use the same confirmation path.
    func setSpeed(_ speed: Double, on deviceID: String) {
        guard pending == nil, speed.isFinite else { return }
        let standalone = speedEdit == nil
        if standalone { beginSpeedEdit(on: deviceID) }
        guard var edit = speedEdit, edit.deviceID == deviceID, !edit.stopped, var pointer = edit.proposed.pointer else { return }
        pointer.speed = min(max(speed, PointerMath.speedRange.lowerBound), PointerMath.speedRange.upperBound)
        edit.proposed = PointerSelection(pointer: pointer)
        // A speed that will have to be kept is written down before the mouse gets it; the drag's first such
        // record keeps its confirmed baseline however far the drag goes on.
        if PointerMath.needsConfirmation(confirmed: edit.baseline.pointer?.speed ?? 1, new: pointer.speed),
           !recordTrial(on: deviceID, confirmed: edit.baseline, trial: nil) {
            // The confirmed speed goes back on the mouse, and nothing more from this drag is applied.
            edit.proposed = edit.baseline
            edit.stopped = true
            notify(.trialNotRecorded, on: deviceID)
        }
        speedEdit = edit
        reapply()
        if standalone { endSpeedEdit() }
    }

    /// The slider drag ended: the speed it reached is rolled back if the system refused it, and waits to be
    /// kept if it is a big increase.
    func endSpeedEdit() {
        guard let edit = speedEdit else { return }
        guard canContinuePreview(edit.baseline, on: edit.deviceID, services: edit.services, settings: store.settings, connected: connected()) else {
            speedEdit = nil
            reapply()
            return
        }
        let selection = edit.proposed
        guard selection != edit.baseline else {
            speedEdit = nil
            return
        }
        if refused(edit.deviceID) {
            speedEdit = nil
            notify(rollBack(to: edit.baseline, on: edit.deviceID), on: edit.deviceID)
            return
        } else if PointerMath.needsConfirmation(confirmed: edit.baseline.pointer?.speed ?? 1, new: selection.pointer?.speed ?? 1) {
            // Waiting starts before the drag ends, so the record of the unconfirmed speed is never dropped between them.
            beginConfirmation(deviceID: edit.deviceID, previous: edit.baseline, proposed: selection, services: edit.services)
            speedEdit = nil
        } else {
            speedEdit = nil
            setSelection(selection, on: edit.deviceID)
        }
        reapply()
    }

    // MARK: Confirmation

    private func beginConfirmation(deviceID: String, previous: PointerSelection, proposed: PointerSelection, services: Set<UInt64>) {
        // Usually written already, before the value reached the mouse; this adds the speed a drag settled on.
        _ = recordTrial(on: deviceID, confirmed: previous, trial: proposed)
        revertTimer?.invalidate()
        let deadline = now().addingTimeInterval(confirmationTimeout)
        pending = PendingChange(deviceID: deviceID, previous: previous, proposed: proposed, deadline: deadline, services: services)
        revertTimer = Timer.scheduledTimer(withTimeInterval: confirmationTimeout, repeats: false) { [weak self] _ in
            MainActor.assumeIsolated { self?.revertPending() }
        }
    }

    /// The waiting speed is now the confirmed one.
    func confirmPending() {
        guard let change = pending else { return }
        cancelPending()
        if canContinuePreview(change.previous, on: change.deviceID, services: change.services, settings: store.settings, connected: connected()) {
            guard !refused(change.deviceID) else {
                notify(rollBack(to: change.previous, on: change.deviceID), on: change.deviceID)
                return
            }
            setSelection(change.proposed, on: change.deviceID)
        }
        reapply()
    }

    /// Puts back the last confirmed speed and preset. Also what the timeout does.
    func revertPending() {
        guard let change = pending else { return }
        cancelPending()
        Log.pointer.info("Pointer speed change not confirmed; reverting \(change.deviceID, privacy: .public)")
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

    // MARK: Journal

    /// Writes down an unconfirmed change before it reaches the mouse. A record already kept for the device keeps
    /// its confirmed baseline and start, so later writes in the same change can't move the baseline. False when
    /// it couldn't be written; the caller then applies nothing.
    private func recordTrial(on deviceID: String, confirmed: PointerSelection, trial: PointerSelection?) -> Bool {
        guard let journal else { return true }
        var record = PointerTrialRecord(
            deviceID: deviceID, confirmed: .init(confirmed), trial: trial.map { .init($0) }, startedAt: now()
        )
        if let journaled, journaled.deviceID == deviceID {
            record.confirmed = journaled.confirmed
            record.startedAt = journaled.startedAt
            if record.trial == nil { record.trial = journaled.trial }
        }
        guard record != journaled else { return true }
        do {
            try journal.savePointerTrial(record)
        } catch {
            Log.pointer.error("Couldn’t write down an unconfirmed pointer change: \(error.localizedDescription, privacy: .public)")
            return false
        }
        journaled = record
        return true
    }

    /// Removes the record once no unconfirmed change is left. One that can't be removed only means the next
    /// launch goes back to the speed confirmed before that change.
    private func settleTrialRecord() {
        guard journaled != nil, pending == nil, speedEdit == nil, let journal else { return }
        journaled = nil
        do {
            try journal.clearPointerTrial()
        } catch {
            Log.pointer.error("Couldn’t remove the pointer change record: \(error.localizedDescription, privacy: .public)")
        }
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
