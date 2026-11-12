import Foundation
import Testing
@testable import Whisker
@testable import WhiskerCore

@Suite("Pointer controller")
@MainActor
struct PointerControllerTests {
    /// Stands in for the HID event system: remembers what each device holds and answers writes as scripted.
    final class FakeHardware: PointerHardware {
        enum Answer {
            case accept
            /// The system says no, and the device keeps what it had.
            case refuse
            /// Some of the device's services take the values; the write is reported as failed.
            case partial
        }

        static let native = OriginalPointer(resolution: 400 << 16, acceleration: 1 << 16)

        var services: [String: Set<UInt64>] = [:]
        /// What each device holds right now. A device that isn't in here holds `native`.
        var values: [String: OriginalPointer] = [:]
        var refuses = false
        /// Answers for the next writes, one each; after that every write is accepted.
        var answers: [Answer] = []
        /// Writes that reached a device, wholly or in part.
        private(set) var writes: [String] = []
        /// Told of every write as it arrives, with the resolution asked for.
        var onWrite: ((Int64) -> Void)?

        func serviceIDs(for deviceID: String) -> Set<UInt64> { services[deviceID] ?? [] }

        func currentValues(of deviceID: String) -> OriginalPointer? {
            services[deviceID] == nil ? nil : values[deviceID] ?? Self.native
        }

        func write(resolution: Int64, acceleration: Int64?, to deviceID: String) -> Bool {
            onWrite?(resolution)
            guard services[deviceID] != nil, !refuses else { return false }
            let answer = answers.isEmpty ? Answer.accept : answers.removeFirst()
            if answer == .refuse { return false }
            writes.append(deviceID)
            values[deviceID] = OriginalPointer(resolution: resolution, acceleration: acceleration)
            return answer == .accept
        }
    }

    /// A record kept in memory, which can be told to fail.
    @MainActor
    final class FakeJournal: PointerTrialJournal {
        var entry: PointerTrialJournalEntry = .empty
        var savesFail = false
        var clearsFail = false

        func loadPointerTrial() -> PointerTrialJournalEntry { entry }

        func savePointerTrial(_ record: PointerTrialRecord) throws {
            if savesFail { throw CocoaError(.fileWriteNoPermission) }
            entry = .record(record)
        }

        func clearPointerTrial() throws {
            if clearsFail { throw CocoaError(.fileWriteNoPermission) }
            entry = .empty
        }
    }

    /// A controller on fake hardware, with a real store in a throwaway folder.
    @MainActor
    final class Rig {
        let hardware = FakeHardware()
        let store: SettingsStore
        /// Where unconfirmed changes are written down: the store unless a test brings its own.
        let journal: PointerTrialJournal
        /// The mice the system lists as connected.
        var connected: [PointingDevice]
        /// What the controller last asked to have kept as the mice's original values.
        var savedOriginals: [String: OriginalPointer]?
        var clock = Date(timeIntervalSinceReferenceDate: 800_000_000)
        private let directory: URL
        private(set) lazy var controller: PointerController = {
            let controller = PointerController(
                hardware: hardware, store: store, journal: journal, connected: { [unowned self] in self.connected },
                confirmationTimeout: 3600, now: { [unowned self] in self.clock }
            )
            controller.onOriginalsChange = { [unowned self] originals in
                self.savedOriginals = originals
                var state = self.store.loadRunState()
                state.cleanExit = false
                state.originalPointers = originals
                self.store.saveRunState(state)
            }
            return controller
        }()

        init(settings: WhiskerSettings? = nil, connected: [PointingDevice]? = nil, journal: PointerTrialJournal? = nil) throws {
            directory = try SettingsStoreTests.makeDirectory()
            store = SettingsStore(directory: directory)
            store.settings = settings ?? PointerControllerTests.settings()
            self.journal = journal ?? store
            self.connected = connected ?? [PointerControllerTests.device]
            for device in self.connected { hardware.services[device.id] = [1] }
        }

        /// Removes the folder, and the save the store had scheduled into it.
        func finish() {
            store.saveNow()
            try? FileManager.default.removeItem(at: directory)
        }

        var saved: DeviceSettings { store.settings.devices[PointerControllerTests.id] ?? DeviceSettings() }
        /// The resolution the fake mouse holds, in 16.16 fixed point.
        var held: Int64? { hardware.values[PointerControllerTests.id]?.resolution }

        /// The app applies the settings at launch and whenever they change.
        func start() {
            controller.apply(store.settings, connected: connected)
        }

        func reloadedStore() -> SettingsStore {
            store.saveNow()
            let reloaded = SettingsStore(directory: directory)
            reloaded.saveNow()
            return reloaded
        }

        /// A launch after Whisker stopped without quitting, from what is on disk, in the order
        /// `AppModel.start()` uses: recovery first, then the leftover originals, then the saved settings.
        func relaunch(journal: PointerTrialJournal? = nil) -> (
            store: SettingsStore, controller: PointerController, recovered: PointerController.InterruptedTrial?
        ) {
            let reloaded = SettingsStore(directory: directory)
            let controller = PointerController(
                originals: reloaded.loadRunState().originalPointers, hardware: hardware, store: reloaded,
                journal: journal ?? reloaded, connected: { [unowned self] in self.connected }
            )
            let recovered = controller.recoverInterruptedTrial()
            controller.restoreLeftovers(connected: connected)
            controller.apply(reloaded.settings, connected: connected)
            return (reloaded, controller, recovered)
        }

        func disconnect() {
            hardware.services[PointerControllerTests.id] = nil
            hardware.values[PointerControllerTests.id] = nil
            connected.removeAll { $0.id == PointerControllerTests.id }
            controller.devicesChanged(connected)
        }

        func reconnect(bypassed: Bool = false) {
            hardware.services[PointerControllerTests.id] = [2]
            connected.append(PointerControllerTests.device)
            controller.devicesChanged(connected, bypassed: bypassed)
        }

        /// An app on the bypass list comes to the front, or leaves it.
        func bypass(_ bypassed: Bool) {
            controller.apply(store.settings, connected: connected, bypassed: bypassed)
        }

        /// The slider previews each speed through the controller, without saving it.
        func drag(to speed: Double) {
            controller.setSpeed(speed, on: PointerControllerTests.id)
        }
    }

    static let id = "046d:c52b"
    static let device = PointingDevice(
        id: id, name: "Mouse", vendorID: 0x046D, productID: 0xC52B, serial: nil, transport: "USB", excludedKind: nil, physicalKeys: ["usb"]
    )
    static let otherID = "1532:0043"
    static let other = PointingDevice(
        id: otherID, name: "Other", vendorID: 0x1532, productID: 0x0043, serial: nil, transport: "USB", excludedKind: nil, physicalKeys: ["usb-2"]
    )

    /// The mouse is at "Normal" (×1), with acceleration, and has two more presets.
    static func settings() -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.devices[id] = DeviceSettings(
            name: "Mouse", pointer: PointerSettings(speed: 1, acceleration: 0.5),
            pointerPresets: [
                PointerPreset(id: "normal", name: "Normal", speed: 1),
                PointerPreset(id: "fast", name: "Fast", speed: 1.5),
                PointerPreset(id: "turbo", name: "Turbo", speed: 4),
            ],
            activePointerPresetID: "normal"
        )
        return settings
    }

    /// What the controller writes for a speed on the fake mouse, whose own resolution is 400.
    static func resolution(_ speed: Double) -> Int64 {
        Int64(PointerMath.ioFixed(PointerMath.resolution(forSpeed: speed, nativeResolution: 400)))
    }

    // MARK: Applying settings

    @Test func reconnectedDeviceIsWrittenAgain() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let settings = rig.store.settings

        rig.controller.apply(settings, connected: [Self.device])
        rig.controller.apply(settings, connected: [Self.device])
        #expect(rig.hardware.writes.count == 1)

        rig.controller.apply(settings, connected: [])
        rig.controller.apply(settings, connected: [Self.device])
        #expect(rig.hardware.writes.count == 2)

        // Reconnected without the device list noticing: the service is new.
        rig.hardware.services[Self.id] = [2]
        rig.controller.apply(settings, connected: [Self.device])
        #expect(rig.hardware.writes.count == 3)
    }

    @Test func failedWritesAreRetried() throws {
        let rig = try Rig()
        defer { rig.finish() }
        let settings = rig.store.settings
        rig.hardware.services[Self.id] = nil

        rig.controller.apply(settings, connected: [Self.device])
        #expect(rig.hardware.writes.isEmpty)

        rig.hardware.services[Self.id] = [1]
        rig.hardware.refuses = true
        rig.controller.apply(settings, connected: [Self.device])
        #expect(rig.controller.unsupported.contains(Self.id))

        rig.hardware.refuses = false
        rig.controller.apply(settings, connected: [Self.device])
        #expect(rig.hardware.writes == [Self.id])
        #expect(!rig.controller.unsupported.contains(Self.id))
    }

    @Test func originalsAreKeptUntilTheyAreBackOnTheMouse() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        #expect(rig.savedOriginals == [Self.id: FakeHardware.native])

        rig.hardware.refuses = true
        rig.controller.restoreAll()
        #expect(rig.controller.originals == [Self.id: FakeHardware.native])
        #expect(rig.savedOriginals == [Self.id: FakeHardware.native])
        #expect(rig.held == Self.resolution(1))

        // The next launch tries again.
        rig.hardware.refuses = false
        rig.controller.restoreLeftovers(connected: rig.connected)
        #expect(rig.controller.originals.isEmpty)
        #expect(rig.savedOriginals == [:])
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)
    }

    // MARK: Switching presets

    @Test func switchingPresetsChangesOnlyTheSpeed() throws {
        var settings = Self.settings()
        settings.devices[Self.id]?.pointer = PointerSettings(speed: 1, acceleration: 0.5, linear: true)
        let rig = try Rig(settings: settings)
        defer { rig.finish() }
        rig.start()
        let acceleration = rig.hardware.values[Self.id]?.acceleration

        let outcome = rig.controller.selectPreset("fast", on: Self.id)
        #expect(outcome == .applied)
        #expect(rig.saved.pointer == PointerSettings(speed: 1.5, acceleration: 0.5, linear: true))
        #expect(rig.saved.activePointerPresetID == "fast")
        #expect(rig.held == Self.resolution(1.5))
        #expect(rig.hardware.values[Self.id]?.acceleration == acceleration)
        #expect(rig.controller.pending == nil)

        let writes = rig.hardware.writes.count
        let again = rig.controller.selectPreset("fast", on: Self.id)
        #expect(again == .alreadyActive)
        #expect(rig.hardware.writes.count == writes)
    }

    @Test func aBigIncreaseWaitsToBeKeptAndGoesBackOtherwise() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        var attention = 0
        rig.controller.onAttention = { attention += 1 }

        let outcome = rig.controller.selectPreset("turbo", on: Self.id)
        #expect(outcome == .awaitingConfirmation)
        #expect(attention == 1)
        #expect(rig.saved.pointer?.speed == 1)
        #expect(rig.held == Self.resolution(4))
        let pending = try #require(rig.controller.pending)
        #expect(pending.deviceID == Self.id)
        #expect(pending.previous.pointer?.speed == 1)
        #expect(pending.previous.presetID == "normal")
        #expect(pending.proposed.presetID == "turbo")

        rig.controller.revertPending()
        #expect(rig.controller.pending == nil)
        #expect(rig.saved.pointer?.speed == 1)
        #expect(rig.saved.activePointerPresetID == "normal")
        #expect(rig.held == Self.resolution(1))

        // The same switch, kept this time: a timer that fires late has nothing left to revert.
        _ = rig.controller.selectPreset("turbo", on: Self.id)
        rig.controller.confirmPending()
        rig.controller.revertPending()
        #expect(rig.controller.pending == nil)
        #expect(rig.saved.activePointerPresetID == "turbo")
        #expect(rig.held == Self.resolution(4))
    }

    @Test func aPendingPresetNeverReachesSavedSettingsOrRelaunch() throws {
        var settings = Self.settings()
        settings.devices[Self.otherID] = DeviceSettings(
            pointer: PointerSettings(speed: 0.5, acceleration: 0.2, linear: true),
            pointerPresets: [PointerPreset(id: "precise", name: "Precise", speed: 0.5)],
            activePointerPresetID: "precise"
        )
        let rig = try Rig(settings: settings, connected: [Self.device, Self.other])
        defer { rig.finish() }
        rig.start()
        #expect(rig.controller.selectPreset("fast", on: Self.id) == .applied)
        let confirmed = rig.store.settings

        #expect(rig.controller.selectPreset("turbo", on: Self.id) == .awaitingConfirmation)
        #expect(rig.held == Self.resolution(4))
        let reloaded = rig.reloadedStore()
        #expect(reloaded.settings == confirmed)
        let json = try #require(JSONSerialization.jsonObject(with: Data(contentsOf: reloaded.fileURL)) as? [String: Any])
        #expect(json["schemaVersion"] as? Int == 2)
        let devices = try #require(json["devices"] as? [String: [String: Any]])
        #expect(devices[Self.id]?["activePointerPresetID"] as? String == "fast")
        #expect((devices[Self.id]?["pointer"] as? [String: Any])?["speed"] as? Double == 1.5)

        let restarted = PointerController(
            originals: reloaded.loadRunState().originalPointers, hardware: rig.hardware,
            store: reloaded, connected: { rig.connected }
        )
        restarted.restoreLeftovers(connected: rig.connected)
        restarted.apply(reloaded.settings, connected: rig.connected)
        #expect(restarted.pending == nil)
        #expect(rig.held == Self.resolution(1.5))
        #expect(rig.hardware.values[Self.otherID]?.resolution == Self.resolution(0.5))
        #expect(reloaded.settings.devices[Self.otherID]?.activePointerPresetID == "precise")
    }

    @Test func nothingSwitchesWhileAnyChangeWaits() throws {
        var settings = Self.settings()
        settings.devices[Self.otherID] = settings.devices[Self.id]
        let rig = try Rig(settings: settings, connected: [Self.device, Self.other])
        defer { rig.finish() }
        rig.start()
        let first = rig.controller.selectPreset("turbo", on: Self.id)
        #expect(first == .awaitingConfirmation)
        let writes = rig.hardware.writes.count

        let sameMouse = rig.controller.selectPreset("fast", on: Self.id)
        let otherMouse = rig.controller.selectPreset("fast", on: Self.otherID)
        #expect(sameMouse == .rejected(.confirmationPending))
        #expect(otherMouse == .rejected(.confirmationPending))
        #expect(rig.hardware.writes.count == writes)
        #expect(rig.saved.activePointerPresetID == "normal")
        #expect(rig.store.settings.devices[Self.otherID]?.activePointerPresetID == "normal")
        #expect(rig.controller.pending?.proposed.presetID == "turbo")

        rig.controller.confirmPending()
        let afterwards = rig.controller.selectPreset("fast", on: Self.otherID)
        #expect(afterwards == .applied)
    }

    @Test func switchesThatAreNotAllowedLeaveTheMouseAlone() throws {
        func rejected(
            _ reason: PointerPresetRefusal, preset: String = "fast", connected: Bool = true, change: (inout WhiskerSettings) -> Void = { _ in }
        ) throws {
            var settings = Self.settings()
            change(&settings)
            let rig = try Rig(settings: settings, connected: connected ? [Self.device] : [])
            defer { rig.finish() }
            rig.start()
            let before = rig.store.settings
            let writes = rig.hardware.writes.count

            let outcome = rig.controller.selectPreset(preset, on: Self.id)
            #expect(outcome == .rejected(reason))
            #expect(rig.hardware.writes.count == writes)
            #expect(rig.store.settings == before)
            #expect(rig.controller.notice?.message == reason.message(device: "Mouse"))
            #expect(rig.controller.pending == nil)
        }

        try rejected(.whiskerOff) { $0.general.enabled = false }
        try rejected(.deviceOff) { $0.devices[Self.id]?.enabled = false }
        try rejected(.customSpeedOff) { $0.devices[Self.id]?.pointer = nil }
        try rejected(.unknownPreset, preset: "gone")
        try rejected(.notConnected, connected: false)
    }

    // MARK: Refusals and rollback

    @Test func aRefusedSwitchIsRolledBackAndReported() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        var attention = 0
        rig.controller.onAttention = { attention += 1 }
        rig.hardware.answers = [.refuse]

        let outcome = rig.controller.selectPreset("fast", on: Self.id)
        #expect(outcome == .rejected(.hardwareRefused))
        #expect(rig.saved.pointer?.speed == 1)
        #expect(rig.saved.activePointerPresetID == "normal")
        #expect(rig.held == Self.resolution(1))
        #expect(rig.controller.notice?.message == PointerPresetRefusal.hardwareRefused.message(device: "Mouse"))
        #expect(!rig.controller.unsupported.contains(Self.id))
        #expect(rig.controller.pending == nil)
        #expect(attention == 1)
    }

    @Test func aPartialWriteIsRolledBackOnEveryService() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        rig.hardware.answers = [.partial]

        let outcome = rig.controller.selectPreset("turbo", on: Self.id)
        #expect(outcome == .rejected(.hardwareRefused))
        // The first write left the mouse part way to the new speed; the rollback wrote the confirmed one again.
        #expect(rig.hardware.writes.count == 3)
        #expect(rig.held == Self.resolution(1))
        #expect(rig.saved.activePointerPresetID == "normal")
        #expect(rig.controller.pending == nil)
        #expect(rig.controller.notice?.message == PointerPresetRefusal.hardwareRefused.message(device: "Mouse"))
    }

    @Test func aRollbackTheSystemRefusesIsReportedAndTriedAgain() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        rig.hardware.answers = [.partial, .refuse]

        let outcome = rig.controller.selectPreset("fast", on: Self.id)
        #expect(outcome == .rejected(.restoreFailed))
        // The mouse is stuck at the new speed, but the settings still say what was confirmed.
        #expect(rig.held == Self.resolution(1.5))
        #expect(rig.saved.pointer?.speed == 1)
        #expect(rig.saved.activePointerPresetID == "normal")
        #expect(rig.controller.unsupported.contains(Self.id))
        #expect(rig.controller.originals == [Self.id: FakeHardware.native])
        #expect(rig.controller.notice?.message == PointerPresetRefusal.restoreFailed.message(device: "Mouse"))

        rig.controller.devicesChanged(rig.connected)
        #expect(rig.held == Self.resolution(1))
        #expect(!rig.controller.unsupported.contains(Self.id))
        #expect(rig.controller.notice == nil)
    }

    @Test func aTimeoutThatCantPutTheSpeedBackIsReportedAndTriedAgain() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        _ = rig.controller.selectPreset("turbo", on: Self.id)
        rig.hardware.answers = [.refuse]

        rig.controller.revertPending()
        #expect(rig.saved.pointer?.speed == 1)
        #expect(rig.saved.activePointerPresetID == "normal")
        #expect(rig.held == Self.resolution(4))
        #expect(rig.controller.notice?.message == PointerPresetRefusal.restoreFailed.message(device: "Mouse"))

        rig.controller.devicesChanged(rig.connected)
        #expect(rig.held == Self.resolution(1))
        #expect(rig.controller.notice == nil)
    }

    @Test func aReconnectedMouseGetsTheLastConfirmedSpeedOnly() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()

        _ = rig.controller.selectPreset("fast", on: Self.id)
        rig.disconnect()
        rig.reconnect()
        #expect(rig.held == Self.resolution(1.5))

        // A switch still waiting is dropped when the mouse goes, so it can't come back with it.
        let outcome = rig.controller.selectPreset("turbo", on: Self.id)
        #expect(outcome == .awaitingConfirmation)
        rig.disconnect()
        #expect(rig.controller.pending == nil)
        #expect(rig.saved.activePointerPresetID == "fast")
        rig.reconnect()
        #expect(rig.held == Self.resolution(1.5))
        #expect(rig.controller.pending == nil)
    }

    @Test(arguments: [false, true])
    func aReplacedServiceNeverInheritsAnUnconfirmedSelection(duringDrag: Bool) throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        #expect(rig.controller.selectPreset("fast", on: Self.id) == .applied)
        if duringDrag {
            rig.controller.beginSpeedEdit(on: Self.id)
            rig.drag(to: 4)
        } else {
            #expect(rig.controller.selectPreset("turbo", on: Self.id) == .awaitingConfirmation)
        }

        // The monitor can see replacement services without an intermediate disconnected list.
        rig.hardware.services[Self.id] = [3]
        rig.hardware.values[Self.id] = FakeHardware.native
        rig.controller.devicesChanged(rig.connected)
        #expect(!rig.controller.isBusy)
        #expect(rig.held == Self.resolution(1.5))
        rig.controller.endSpeedEdit()
        rig.controller.confirmPending()
        let reloaded = rig.reloadedStore()
        #expect(reloaded.settings.devices[Self.id]?.pointer?.speed == 1.5)
        #expect(reloaded.settings.devices[Self.id]?.activePointerPresetID == "fast")
    }

    @Test(arguments: [false, true], [false, true])
    func settingsChangesCancelUnconfirmedChoicesWithoutOverwritingReplacements(duringDrag: Bool, disabled: Bool) throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        if duringDrag {
            rig.controller.beginSpeedEdit(on: Self.id)
            rig.drag(to: 1.8)
        } else {
            #expect(rig.controller.selectPreset("turbo", on: Self.id) == .awaitingConfirmation)
        }

        var replacement = rig.store.settings
        if disabled {
            replacement.general.enabled = false
        } else {
            replacement.devices[Self.id]?.pointerSelection = PointerSelection(
                pointer: PointerSettings(speed: duringDrag ? 1.8 : 4, acceleration: 0.2, linear: true)
            )
        }
        rig.store.settings = replacement
        rig.controller.apply(replacement, connected: rig.connected)
        #expect(rig.controller.isBusy == false)
        rig.controller.endSpeedEdit()
        rig.controller.confirmPending()
        rig.controller.revertPending()
        let reloaded = rig.reloadedStore()
        #expect(reloaded.settings == replacement)
        if disabled {
            #expect(rig.hardware.values[Self.id] == FakeHardware.native)
        } else {
            #expect(rig.hardware.values[Self.id]?.acceleration == -1 << 16)
        }
    }

    @Test(arguments: [false, true])
    func restoringAllCancelsUnconfirmedChoicesWithoutSavingThem(duringDrag: Bool) throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        #expect(rig.controller.selectPreset("fast", on: Self.id) == .applied)
        if duringDrag {
            rig.controller.beginSpeedEdit(on: Self.id)
            rig.drag(to: 4)
        } else {
            #expect(rig.controller.selectPreset("turbo", on: Self.id) == .awaitingConfirmation)
        }
        rig.controller.restoreAll()
        #expect(rig.controller.isBusy == false)
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)
        rig.controller.endSpeedEdit()
        rig.controller.confirmPending()
        let reloaded = rig.reloadedStore()
        #expect(reloaded.settings.devices[Self.id]?.pointer?.speed == 1.5)
        #expect(reloaded.settings.devices[Self.id]?.activePointerPresetID == "fast")
        #expect(reloaded.loadRunState().originalPointers.isEmpty)
    }

    @Test func useSystemSettingsCancelsAWaitingChangeAndPutsTheOriginalsBack() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        _ = rig.controller.selectPreset("turbo", on: Self.id)

        rig.controller.useSystemSettings(on: Self.id)
        #expect(rig.controller.pending == nil)
        #expect(rig.saved.pointer == nil)
        #expect(rig.saved.activePointerPresetID == nil)
        #expect(rig.saved.pointerPresets.count == 3)
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)
        #expect(rig.controller.originals.isEmpty)
        #expect(rig.controller.notice == nil)
    }

    @Test func useSystemSettingsThatTheSystemRefusesIsReportedAndTriedAgain() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        rig.hardware.answers = [.refuse]

        rig.controller.useSystemSettings(on: Self.id)
        #expect(rig.saved.pointer == nil)
        #expect(rig.controller.originals == [Self.id: FakeHardware.native])
        #expect(rig.held == Self.resolution(1))
        #expect(rig.controller.notice?.message == PointerPresetRefusal.restoreFailed.message(device: "Mouse"))

        rig.controller.devicesChanged(rig.connected)
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)
        #expect(rig.controller.originals.isEmpty)
        #expect(rig.controller.notice == nil)
    }

    // MARK: Bypassed apps

    @Test func presetsAreNotSwitchedWhileAnAppIsBypassed() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        rig.bypass(true)
        #expect(rig.controller.isBypassed)
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)
        let before = rig.store.settings
        let writes = rig.hardware.writes.count

        #expect(rig.controller.refusal(forPreset: "fast", on: Self.id) == .appBypassed)
        let outcome = rig.controller.selectPreset("fast", on: Self.id)
        #expect(outcome == .rejected(.appBypassed))
        #expect(rig.store.settings == before)
        #expect(rig.hardware.writes.count == writes)
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)
        #expect(rig.controller.notice?.message == PointerPresetRefusal.appBypassed.message(device: "Mouse"))

        rig.bypass(false)
        #expect(!rig.controller.isBypassed)
        #expect(rig.controller.refusal(forPreset: "fast", on: Self.id) == nil)
        let afterwards = rig.controller.selectPreset("fast", on: Self.id)
        #expect(afterwards == .applied)
        #expect(rig.held == Self.resolution(1.5))
    }

    @Test func aWaitingChangeRevertsWithoutWritingWhileAnAppIsBypassed() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        let outcome = rig.controller.selectPreset("turbo", on: Self.id)
        #expect(outcome == .awaitingConfirmation)
        rig.bypass(true)
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)
        let writes = rig.hardware.writes.count

        rig.controller.revertPending()
        #expect(rig.controller.pending == nil)
        #expect(rig.saved.pointer?.speed == 1)
        #expect(rig.saved.activePointerPresetID == "normal")
        #expect(rig.hardware.writes.count == writes)
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)

        // The mouse gets the confirmed speed when the app leaves, not the one that was reverted.
        rig.bypass(false)
        #expect(rig.held == Self.resolution(1))
    }

    @Test func aRefusedPendingWriteCannotBeKeptAndRetainsRecoveryOnDisk() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        #expect(rig.controller.selectPreset("fast", on: Self.id) == .applied)
        #expect(rig.controller.selectPreset("turbo", on: Self.id) == .awaitingConfirmation)
        rig.bypass(true)
        rig.hardware.answers = [.partial, .refuse]

        rig.bypass(false)
        #expect(rig.controller.pending == nil)
        #expect(rig.controller.notice?.message == PointerPresetRefusal.restoreFailed.message(device: "Mouse"))
        rig.controller.confirmPending()
        let reloaded = rig.reloadedStore()
        #expect(reloaded.settings.devices[Self.id]?.pointer?.speed == 1.5)
        #expect(reloaded.settings.devices[Self.id]?.activePointerPresetID == "fast")
        #expect(reloaded.loadRunState().originalPointers == [Self.id: FakeHardware.native])

        let restarted = PointerController(
            originals: reloaded.loadRunState().originalPointers, hardware: rig.hardware,
            store: reloaded, connected: { rig.connected }
        )
        restarted.restoreLeftovers(connected: rig.connected)
        restarted.apply(reloaded.settings, connected: rig.connected)
        #expect(rig.held == Self.resolution(1.5))
        #expect(restarted.notice == nil)
    }

    @Test func useSystemSettingsStillWorksWhileAnAppIsBypassed() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        rig.bypass(true)

        rig.controller.useSystemSettings(on: Self.id)
        #expect(rig.saved.pointer == nil)
        #expect(rig.saved.pointerPresets.count == 3)
        #expect(rig.hardware.values[Self.id] == FakeHardware.native)
        #expect(rig.controller.restoreFailures.isEmpty)
        #expect(rig.controller.notice == nil)
    }

    @Test func aMouseThatReturnsWhileAnAppIsBypassedIsLeftAloneUntilItLeaves() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        rig.bypass(true)
        rig.disconnect()
        let writes = rig.hardware.writes.count

        rig.reconnect(bypassed: true)
        #expect(rig.controller.isBypassed)
        #expect(rig.hardware.writes.count == writes)

        rig.bypass(false)
        #expect(rig.held == Self.resolution(1))
    }

    @Test func aSliderDragFollowsTheSameConfirmationRule() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()

        // Up to double the confirmed speed needs no confirmation.
        rig.controller.beginSpeedEdit(on: Self.id)
        rig.drag(to: 2)
        rig.controller.endSpeedEdit()
        #expect(rig.controller.pending == nil)
        #expect(!rig.controller.isBusy)

        rig.controller.beginSpeedEdit(on: Self.id)
        rig.drag(to: 4.5)
        rig.controller.endSpeedEdit()
        let pending = try #require(rig.controller.pending)
        #expect(pending.previous.pointer?.speed == 2)
        #expect(pending.proposed.pointer?.speed == 4.5)
        #expect(rig.held == Self.resolution(4.5))

        rig.controller.revertPending()
        #expect(rig.saved.pointer?.speed == 2)
        #expect(rig.held == Self.resolution(2))
    }

    @Test(arguments: [false, true])
    func anUnconfirmedSliderEditNeverReachesSavedSettingsOrRelaunch(ended: Bool) throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        #expect(rig.controller.selectPreset("fast", on: Self.id) == .applied)
        rig.controller.beginSpeedEdit(on: Self.id)
        rig.drag(to: 4)
        if ended { rig.controller.endSpeedEdit() }
        #expect(rig.held == Self.resolution(4))

        let reloaded = rig.reloadedStore()
        #expect(reloaded.settings.devices[Self.id]?.pointer?.speed == 1.5)
        #expect(reloaded.settings.devices[Self.id]?.activePointerPresetID == "fast")
        let restarted = PointerController(
            originals: reloaded.loadRunState().originalPointers, hardware: rig.hardware,
            store: reloaded, connected: { rig.connected }
        )
        restarted.restoreLeftovers(connected: rig.connected)
        restarted.apply(reloaded.settings, connected: rig.connected)
        #expect(!restarted.isBusy)
        #expect(rig.held == Self.resolution(1.5))
    }

    @Test(arguments: [false, true])
    func aSliderFailureKeepsTheConfirmedSelectionAndRecovery(rollbackRefused: Bool) throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()

        rig.controller.beginSpeedEdit(on: Self.id)
        rig.hardware.answers = rollbackRefused ? [.partial, .refuse] : [.refuse]
        rig.drag(to: 1.8)
        rig.controller.endSpeedEdit()
        #expect(rig.saved.pointer?.speed == 1)
        #expect(rig.saved.activePointerPresetID == "normal")
        #expect(rig.held == Self.resolution(rollbackRefused ? 1.8 : 1))
        let refusal: PointerPresetRefusal = rollbackRefused ? .restoreFailed : .hardwareRefused
        #expect(rig.controller.notice?.message == refusal.message(device: "Mouse"))
        #expect(!rig.controller.isBusy)
        let reloaded = rig.reloadedStore()
        #expect(reloaded.settings.devices[Self.id]?.pointerSelection == Self.settings().devices[Self.id]?.pointerSelection)
        #expect(reloaded.loadRunState().originalPointers == [Self.id: FakeHardware.native])
    }

    @Test func noPresetSwitchesDuringADragAndAMouseThatLeavesEndsIt() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()

        rig.controller.beginSpeedEdit(on: Self.id)
        #expect(rig.controller.isBusy)
        let outcome = rig.controller.selectPreset("fast", on: Self.id)
        #expect(outcome == .rejected(.confirmationPending))

        rig.drag(to: 3)
        rig.disconnect()
        #expect(!rig.controller.isBusy)
        #expect(rig.saved.pointer?.speed == 1)
        #expect(rig.saved.activePointerPresetID == "normal")
        rig.reconnect()
        #expect(rig.held == Self.resolution(1))
    }

    // MARK: Unconfirmed changes on record

    static func record(confirmed: PointerSelection?, trial: PointerSelection?, at date: Date) throws -> PointerTrialRecord {
        PointerTrialRecord(
            deviceID: id, confirmed: .init(try #require(confirmed)), trial: trial.map { .init($0) }, startedAt: date
        )
    }

    /// Saved settings with the mouse at "Turbo", as if an unconfirmed switch had been saved.
    static func leakedSettings() -> WhiskerSettings {
        var settings = settings()
        _ = settings.devices[id]?.selectPointerPreset(id: "turbo")
        return settings
    }

    @Test func aChangeThatMustBeKeptIsOnRecordBeforeItReachesTheMouse() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        var onRecord: [Int64: PointerTrialJournalEntry] = [:]
        rig.hardware.onWrite = { onRecord[$0] = rig.store.loadPointerTrial() }

        #expect(rig.controller.selectPreset("fast", on: Self.id) == .applied)
        #expect(onRecord[Self.resolution(1.5)] == PointerTrialJournalEntry.empty)
        let confirmed = rig.saved.pointerSelection

        #expect(rig.controller.selectPreset("turbo", on: Self.id) == .awaitingConfirmation)
        let expected = try Self.record(
            confirmed: confirmed, trial: rig.controller.pending?.proposed, at: rig.clock
        )
        #expect(expected.trial?.presetID == "turbo")
        #expect(onRecord[Self.resolution(4)] == .record(expected))
        #expect(rig.store.loadPointerTrial() == .record(expected))
        rig.controller.revertPending()
        #expect(rig.store.loadPointerTrial() == .empty)

        #expect(rig.controller.selectPreset("turbo", on: Self.id) == .awaitingConfirmation)
        #expect(rig.store.loadPointerTrial() != .empty)
        rig.controller.confirmPending()
        #expect(rig.store.loadPointerTrial() == .empty)
        #expect(rig.saved.activePointerPresetID == "turbo")
    }

    @Test func aDragOnRecordKeepsTheSpeedConfirmedBeforeItAndBlocksOtherChanges() throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        let confirmed = rig.saved.pointerSelection
        var onRecord: [Int64: PointerTrialJournalEntry] = [:]
        rig.hardware.onWrite = { onRecord[$0] = rig.store.loadPointerTrial() }

        rig.controller.beginSpeedEdit(on: Self.id)
        rig.drag(to: 1.8)
        #expect(rig.store.loadPointerTrial() == .empty)
        rig.drag(to: 2.5)
        var expected = try Self.record(confirmed: confirmed, trial: nil, at: rig.clock)
        #expect(onRecord[Self.resolution(2.5)] == .record(expected))
        rig.clock += 5
        rig.drag(to: 4)
        #expect(rig.controller.selectPreset("turbo", on: Self.id) == .rejected(.confirmationPending))
        #expect(rig.store.loadPointerTrial() == .record(expected))

        rig.controller.endSpeedEdit()
        expected.trial = .init(PointerSelection(pointer: PointerSettings(speed: 4, acceleration: 0.5)))
        #expect(rig.store.loadPointerTrial() == .record(expected))
        rig.clock += 5
        #expect(rig.controller.selectPreset("fast", on: Self.id) == .rejected(.confirmationPending))
        #expect(rig.store.loadPointerTrial() == .record(expected))

        rig.controller.revertPending()
        #expect(rig.store.loadPointerTrial() == .empty)
        #expect(rig.held == Self.resolution(1))
    }

    @Test func aChangeThatCantBeOnRecordIsNeverApplied() throws {
        let journal = FakeJournal()
        journal.savesFail = true
        let rig = try Rig(journal: journal)
        defer { rig.finish() }
        rig.start()
        let writes = rig.hardware.writes.count
        let message = PointerPresetRefusal.trialNotRecorded.message(device: "Mouse")

        #expect(rig.controller.selectPreset("turbo", on: Self.id) == .rejected(.trialNotRecorded))
        #expect(rig.hardware.writes.count == writes)
        #expect(rig.controller.notice?.message == message)
        #expect(!rig.controller.isBusy)
        #expect(rig.saved.activePointerPresetID == "normal")

        rig.controller.beginSpeedEdit(on: Self.id)
        rig.drag(to: 1.8)
        #expect(rig.held == Self.resolution(1.8))
        rig.drag(to: 3)
        #expect(rig.held == Self.resolution(1))
        #expect(rig.controller.notice?.message == message)
        // The rest of the drag is ignored.
        rig.drag(to: 1.5)
        #expect(rig.held == Self.resolution(1))
        rig.controller.endSpeedEdit()
        #expect(!rig.controller.isBusy)
        #expect(rig.saved.pointer?.speed == 1)

        // A change that doesn't have to be kept needs no record.
        #expect(rig.controller.selectPreset("fast", on: Self.id) == .applied)
        #expect(rig.held == Self.resolution(1.5))
    }

    @Test(arguments: [false, true])
    func aChangeLeftWaitingWhenWhiskerStoppedIsNotUsedAtTheNextLaunch(macRestarted: Bool) throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.start()
        #expect(rig.controller.selectPreset("fast", on: Self.id) == .applied)
        #expect(rig.controller.selectPreset("turbo", on: Self.id) == .awaitingConfirmation)
        #expect(rig.held == Self.resolution(4))
        // Whisker crashes or is force quit with the change waiting; a restart also gives the mouse its own values back.
        rig.store.saveNow()
        if macRestarted { rig.hardware.values[Self.id] = nil }

        let next = rig.relaunch()
        #expect(next.recovered == .reverted(deviceID: Self.id))
        #expect(next.store.loadPointerTrial() == .empty)
        #expect(next.controller.notice?.deviceID == Self.id)
        #expect(!next.controller.isBusy)
        #expect(next.store.settings.devices[Self.id]?.activePointerPresetID == "fast")
        #expect(rig.held == Self.resolution(1.5))

        #expect(rig.relaunch().recovered == nil)
        #expect(rig.held == Self.resolution(1.5))
    }

    @Test(arguments: [false, true])
    func anUnconfirmedSelectionInSavedSettingsIsPutBack(recordedConfirmedIsValid: Bool) throws {
        let rig = try Rig(settings: Self.leakedSettings())
        defer { rig.finish() }
        var confirmed = try #require(Self.settings().devices[Self.id]?.pointerSelection)
        if !recordedConfirmedIsValid { confirmed.pointer?.speed = 50 }
        try rig.store.savePointerTrial(Self.record(
            confirmed: confirmed, trial: Self.leakedSettings().devices[Self.id]?.pointerSelection, at: rig.clock
        ))
        rig.store.saveNow()

        let next = rig.relaunch()
        #expect(next.recovered == .reverted(deviceID: Self.id))
        let expected = recordedConfirmedIsValid ? confirmed : .system
        #expect(next.store.settings.devices[Self.id]?.pointerSelection == expected)
        #expect(SettingsStore(directory: next.store.directory).settings.devices[Self.id]?.pointerSelection == expected)
        #expect(next.store.loadPointerTrial() == .empty)
        // The unknown speed is never written: the mouse gets the confirmed one, or keeps its own.
        #expect(rig.held == (recordedConfirmedIsValid ? Self.resolution(1) : nil))
    }

    @Test(arguments: [false, true])
    func aRecordThatCantBeTrustedIsRemovedWithoutUsingAnythingInIt(fromAnotherVersion: Bool) throws {
        let rig = try Rig()
        defer { rig.finish() }
        rig.store.saveNow()
        if fromAnotherVersion {
            var record = try Self.record(confirmed: .system, trial: Self.leakedSettings().devices[Self.id]?.pointerSelection, at: rig.clock)
            record.version = PointerTrialRecord.currentVersion + 1
            try JSONEncoder().encode(record).write(to: rig.store.pointerTrialURL)
        } else {
            try Data("{\"version\": 1, \"deviceID\": ".utf8).write(to: rig.store.pointerTrialURL)
        }

        let next = rig.relaunch()
        #expect(next.recovered == .unreadable)
        #expect(next.controller.notice != nil)
        #expect(next.store.settings.devices[Self.id]?.pointerSelection == Self.settings().devices[Self.id]?.pointerSelection)
        #expect(next.store.loadPointerTrial() == .empty)
        #expect(rig.held == Self.resolution(1))
    }

    @Test func aRecoveryCutShortGivesTheSameResultWhenItRunsAgain() throws {
        let rig = try Rig(settings: Self.leakedSettings())
        defer { rig.finish() }
        rig.store.saveNow()
        let confirmed = try #require(Self.settings().devices[Self.id]?.pointerSelection)
        let journal = FakeJournal()
        journal.entry = try .record(Self.record(
            confirmed: confirmed, trial: Self.leakedSettings().devices[Self.id]?.pointerSelection, at: rig.clock
        ))
        let recorded = journal.entry
        journal.clearsFail = true

        let first = rig.relaunch(journal: journal)
        #expect(first.recovered == .reverted(deviceID: Self.id))
        #expect(first.store.settings.devices[Self.id]?.pointerSelection == confirmed)
        #expect(journal.entry == recorded)
        #expect(rig.held == Self.resolution(1))

        journal.clearsFail = false
        let second = rig.relaunch(journal: journal)
        #expect(second.recovered == .reverted(deviceID: Self.id))
        #expect(second.store.settings.devices[Self.id]?.pointerSelection == confirmed)
        #expect(journal.entry == .empty)
        #expect(rig.held == Self.resolution(1))
        #expect(rig.relaunch(journal: journal).recovered == nil)
    }
}
