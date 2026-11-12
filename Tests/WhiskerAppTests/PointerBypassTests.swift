import Foundation
import Testing
@testable import Whisker
@testable import WhiskerCore

@Suite("Pointer controller application bypass")
@MainActor
struct PointerBypassTests {
    /// A mouse that remembers what it was last given, so tests see what the pointer would really be doing.
    final class ModelHardware: PointerHardware {
        var services: [String: Set<UInt64>] = [:]
        var values: [String: OriginalPointer] = [:]
        var refuses = false
        private(set) var writes = 0

        func serviceIDs(for deviceID: String) -> Set<UInt64> { services[deviceID] ?? [] }

        func currentValues(of deviceID: String) -> OriginalPointer? {
            services[deviceID] == nil ? nil : values[deviceID]
        }

        func write(resolution: Int64, acceleration: Int64?, to deviceID: String) -> Bool {
            guard services[deviceID] != nil, !refuses else { return false }
            writes += 1
            values[deviceID] = OriginalPointer(resolution: resolution, acceleration: acceleration ?? values[deviceID]?.acceleration)
            return true
        }
    }

    /// The recovery record as saved to disk after each change.
    final class SavedRecords {
        var saved: [[String: OriginalPointer]] = []
    }

    struct Rig {
        let controller: PointerController
        let hardware: ModelHardware
        let records: SavedRecords
    }

    static let id = "046d:c52b"
    static let native = OriginalPointer(resolution: 400 << 16, acceleration: 1 << 16)
    static let device = PointingDevice(
        id: id, name: "Mouse", vendorID: 0x046D, productID: 0xC52B, serial: nil, transport: "USB", excludedKind: nil, physicalKeys: ["usb"]
    )

    static func settings(speed: Double = 2) -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.devices[id] = DeviceSettings(pointer: PointerSettings(speed: speed, acceleration: 0.5))
        return settings
    }

    static func makeRig() -> Rig {
        let hardware = ModelHardware()
        hardware.services[id] = [1]
        hardware.values[id] = native
        let records = SavedRecords()
        let controller = PointerController(hardware: hardware)
        controller.onOriginalsChange = { records.saved.append($0) }
        return Rig(controller: controller, hardware: hardware, records: records)
    }

    @Test func standingAsideRestoresTheOriginalsAndLeavingWritesTheLatestSettings() {
        let rig = Self.makeRig()
        rig.controller.apply(Self.settings(), connected: [Self.device])
        let before = rig.hardware.values[Self.id]
        #expect(before != Self.native)
        #expect(rig.controller.originals == [Self.id: Self.native])

        rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
        #expect(rig.hardware.values[Self.id] == Self.native)
        #expect(rig.controller.originals.isEmpty)
        #expect(rig.records.saved.last == [:])

        // Edits made while the app is in front change nothing on the device.
        let writes = rig.hardware.writes
        rig.controller.apply(Self.settings(speed: 4), connected: [Self.device], bypassed: true)
        rig.controller.apply(Self.settings(speed: 4), connected: [Self.device], bypassed: true)
        #expect(rig.hardware.writes == writes)
        #expect(rig.hardware.values[Self.id] == Self.native)

        rig.controller.apply(Self.settings(speed: 4), connected: [Self.device])
        let after = rig.hardware.values[Self.id]
        #expect(after != Self.native)
        #expect(after != before)
        #expect(rig.controller.originals == [Self.id: Self.native])
        #expect(rig.records.saved.last == [Self.id: Self.native])
    }

    @Test func rapidFocusChangesEndWithTheLatestSettingsAndTheTrueOriginals() {
        let rig = Self.makeRig()
        rig.controller.apply(Self.settings(), connected: [Self.device])
        let overridden = rig.hardware.values[Self.id]

        for _ in 0..<5 {
            rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
            rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
            #expect(rig.hardware.values[Self.id] == Self.native)
            rig.controller.apply(Self.settings(), connected: [Self.device])
            #expect(rig.hardware.values[Self.id] == overridden)
        }

        #expect(rig.controller.originals == [Self.id: Self.native])
        // One write to start with, then one to restore and one to apply again each time round.
        #expect(rig.hardware.writes == 1 + 5 * 2)
    }

    @Test func aMouseReconnectedWhileBypassedIsLeftAloneUntilTheAppLeaves() {
        let rig = Self.makeRig()
        rig.controller.apply(Self.settings(), connected: [Self.device])
        rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
        let writes = rig.hardware.writes

        rig.controller.apply(Self.settings(), connected: [], bypassed: true)
        rig.hardware.services[Self.id] = [2]
        rig.hardware.values[Self.id] = Self.native
        rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
        #expect(rig.hardware.writes == writes)

        rig.controller.apply(Self.settings(), connected: [Self.device])
        #expect(rig.hardware.writes == writes + 1)
        #expect(rig.hardware.values[Self.id] != Self.native)
    }

    @Test func aFailedRestoreIsReportedKeepsTheRecordAndIsRetried() {
        let rig = Self.makeRig()
        rig.controller.apply(Self.settings(), connected: [Self.device])
        let saved = rig.records.saved.count
        rig.hardware.refuses = true

        rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
        #expect(rig.controller.restoreFailures == [Self.id])
        #expect(rig.controller.originals == [Self.id: Self.native])
        #expect(rig.records.saved.count == saved)

        rig.hardware.refuses = false
        rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
        #expect(rig.controller.restoreFailures.isEmpty)
        #expect(rig.controller.originals.isEmpty)
        #expect(rig.hardware.values[Self.id] == Self.native)
        #expect(rig.records.saved.last == [:])
    }

    @Test func leavingAfterAFailedRestoreKeepsTheTrueOriginals() {
        let rig = Self.makeRig()
        rig.controller.apply(Self.settings(), connected: [Self.device])
        rig.hardware.refuses = true
        rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
        rig.hardware.refuses = false

        rig.controller.apply(Self.settings(), connected: [Self.device])
        #expect(rig.controller.restoreFailures.isEmpty)
        #expect(rig.controller.originals == [Self.id: Self.native])

        rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
        #expect(rig.hardware.values[Self.id] == Self.native)
        #expect(rig.controller.originals.isEmpty)
    }

    @Test func quittingAfterAFailedRestoreLeavesTheRecordForTheNextLaunch() {
        let rig = Self.makeRig()
        rig.controller.apply(Self.settings(), connected: [Self.device])
        rig.hardware.refuses = true

        rig.controller.restoreAll()
        #expect(rig.controller.originals == [Self.id: Self.native])
        #expect(rig.controller.restoreFailures == [Self.id])
        #expect(rig.records.saved.last == [Self.id: Self.native])

        rig.hardware.refuses = false
        let next = PointerController(originals: rig.records.saved.last ?? [:], hardware: rig.hardware)
        next.restoreLeftovers(connected: [Self.device])
        #expect(next.originals.isEmpty)
        #expect(rig.hardware.values[Self.id] == Self.native)
    }

    @Test func aRefusedFirstWriteLeavesNothingToRestore() {
        let rig = Self.makeRig()
        rig.hardware.refuses = true

        rig.controller.apply(Self.settings(), connected: [Self.device])
        #expect(rig.controller.unsupported == [Self.id])
        #expect(rig.controller.originals.isEmpty)

        rig.controller.apply(Self.settings(), connected: [Self.device], bypassed: true)
        #expect(rig.controller.restoreFailures.isEmpty)
    }

    @Test func leavingABypassedAppNeverTurnsPointerSettingsOnWhileWhiskerIsOff() {
        let rig = Self.makeRig()
        var off = Self.settings()
        off.general.enabled = false

        rig.controller.apply(off, connected: [Self.device], bypassed: true)
        rig.controller.apply(off, connected: [Self.device])

        #expect(rig.hardware.writes == 0)
        #expect(rig.hardware.values[Self.id] == Self.native)
    }
}
