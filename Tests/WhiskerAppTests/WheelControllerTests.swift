import Foundation
import Testing
@testable import Whisker
@testable import WhiskerCore

@Suite("Wheel controller")
@MainActor
struct WheelControllerTests {
    final class FakeWheelHardware: WheelHardware {
        struct Key: Hashable { var control: NativeWheelControl; var service: UInt64 }
        var lookups: [String: WheelServiceLookup] = [:]
        var values: [Key: WheelReading] = [:]
        var present: Set<UInt64> = []
        var refusedWrites: Set<Key> = []
        /// Writes that report success but leave a different value behind.
        var ignoredWrites: Set<Key> = []
        var failingRestores: Set<Key> = []
        private(set) var writes: [(Key, Int64)] = []

        func lookup(deviceID: String) -> WheelServiceLookup { lookups[deviceID] ?? WheelServiceLookup.none }
        func isPresent(service: UInt64, deviceID: String) -> Bool { present.contains(service) }
        func read(_ control: NativeWheelControl, service: UInt64) -> WheelReading { values[Key(control: control, service: service)] ?? .missing }

        func write(_ control: NativeWheelControl, value: Int64, byteSize: Int, service: UInt64) -> Bool {
            let key = Key(control: control, service: service)
            writes.append((key, value))
            if refusedWrites.contains(key) { return false }
            if failingRestores.contains(key), case .integer(let current, _)? = values[key], current != value, writes.count > 0, isRestore(key, value) { return false }
            if !ignoredWrites.contains(key) { values[key] = .integer(value, byteSize: byteSize) }
            return true
        }

        var originals: [Key: Int64] = [:]
        private func isRestore(_ key: Key, _ value: Int64) -> Bool { originals[key] == value }

        func add(_ service: UInt64, speed: Int64 = 2 << 16, acceleration: Int64 = 1 << 16) {
            present.insert(service)
            values[Key(control: .speed, service: service)] = .integer(speed, byteSize: 4)
            values[Key(control: .acceleration, service: service)] = .integer(acceleration, byteSize: 4)
            originals[Key(control: .speed, service: service)] = speed
            originals[Key(control: .acceleration, service: service)] = acceleration
        }

        func speed(_ service: UInt64) -> Int64? {
            if case .integer(let v, _)? = values[Key(control: .speed, service: service)] { return v }
            return nil
        }
    }

    nonisolated static let id = "046d:c52b"
    static func device(_ id: String = id, serial: String? = nil, keys: Set<String> = ["usb"]) -> PointingDevice {
        PointingDevice(id: id, name: "Mouse", vendorID: 0x046D, productID: 0xC52B, serial: serial, transport: "USB", excludedKind: nil, physicalKeys: keys)
    }

    static func settings(_ id: String = id, speed: Double? = 2, acceleration: Double? = nil) -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.devices[id] = DeviceSettings(wheel: WheelSettings(native: NativeWheelSettings(enabled: true, speed: speed, acceleration: acceleration)))
        return settings
    }

    static func setup(services: Set<UInt64> = [1]) -> (WheelController, FakeWheelHardware) {
        let hardware = FakeWheelHardware()
        for service in services { hardware.add(service) }
        hardware.lookups[id] = .services(services)
        return (WheelController(hardware: hardware), hardware)
    }

    @Test func appliesVerifiesAndRestoresOnDisable() {
        let (controller, hardware) = Self.setup()
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(controller.activeDevices == [Self.id])
        #expect(hardware.speed(1) == 1 << 16)
        #expect(controller.status(of: .speed, device: Self.id) == .active)
        #expect(controller.status(of: .acceleration, device: Self.id) == .available)

        controller.apply(WhiskerSettings(), connected: [Self.device()])
        #expect(hardware.speed(1) == 2 << 16)
        #expect(controller.activeDevices.isEmpty)
        #expect(controller.records.isEmpty)
    }

    @Test func eachServiceKeepsItsOwnOriginal() {
        let (controller, hardware) = Self.setup(services: [1, 2])
        hardware.add(2, speed: 4 << 16)
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(hardware.speed(1) == 1 << 16)
        #expect(hardware.speed(2) == 2 << 16)
        controller.restoreAll()
        #expect(hardware.speed(1) == 2 << 16)
        #expect(hardware.speed(2) == 4 << 16)
    }

    @Test func recordsArePersistedBeforeTheFirstWrite() {
        let (controller, hardware) = Self.setup()
        var writesWhenFirstRecorded: Int?
        controller.onRecordsChange = { records in
            if writesWhenFirstRecorded == nil, !records.isEmpty { writesWhenFirstRecorded = hardware.writes.count }
        }
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(writesWhenFirstRecorded == 0)
    }

    @Test func refusedWriteRollsBackEveryServiceAndLeavesNativeInactive() {
        let (controller, hardware) = Self.setup(services: [1, 2])
        hardware.refusedWrites = [.init(control: .speed, service: 2)]
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(controller.activeDevices.isEmpty)
        #expect(hardware.speed(1) == 2 << 16)
        #expect(controller.records.isEmpty)
        #expect(controller.status(of: .speed, device: Self.id) == .failed(.refused))
        // A failure isn't retried until something changes.
        let writes = hardware.writes.count
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(hardware.writes.count == writes)
    }

    @Test func mismatchedReadBackIsRolledBack() {
        let (controller, hardware) = Self.setup()
        hardware.ignoredWrites = [.init(control: .speed, service: 1)]
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(controller.status(of: .speed, device: Self.id) == .failed(.readBackMismatch))
        #expect(controller.activeDevices.isEmpty)
        #expect(controller.records.isEmpty)
    }

    @Test func partialFailureAcrossControlsUndoesTheControlThatWorked() {
        let (controller, hardware) = Self.setup()
        hardware.refusedWrites = [.init(control: .acceleration, service: 1)]
        controller.apply(Self.settings(speed: 2, acceleration: 1), connected: [Self.device()])
        #expect(hardware.speed(1) == 2 << 16)
        #expect(controller.activeDevices.isEmpty)
        #expect(controller.status(of: .acceleration, device: Self.id) == .failed(.refused))
    }

    @Test func failedRestorationKeepsTheRecordAndIsRetried() {
        let (controller, hardware) = Self.setup()
        controller.apply(Self.settings(), connected: [Self.device()])
        hardware.failingRestores = [.init(control: .speed, service: 1)]
        controller.apply(WhiskerSettings(), connected: [Self.device()])
        #expect(controller.restoreFailures == [Self.id])
        #expect(controller.records[Self.id] != nil)
        // Software stays out of the way while the mouse may still hold Whisker's value.
        #expect(controller.activeDevices == [Self.id])

        hardware.failingRestores = []
        controller.apply(WhiskerSettings(), connected: [Self.device()])
        #expect(controller.restoreFailures.isEmpty)
        #expect(controller.records.isEmpty)
        #expect(hardware.speed(1) == 2 << 16)
    }

    @Test func disconnectedServicesAreNotWrittenAndReconnectsGetFreshOriginals() {
        let (controller, hardware) = Self.setup()
        controller.apply(Self.settings(), connected: [Self.device()])
        // Unplugged and plugged back in under a new service; the old one is gone.
        hardware.present = [7]
        hardware.add(7, speed: 3 << 16)
        hardware.lookups[Self.id] = .services([7])
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(hardware.writes.allSatisfy { $0.0.service != 7 || $0.1 != 2 << 16 })
        #expect(hardware.speed(7) == Int64(98304))
        #expect(controller.records[Self.id]?.services.keys.contains("1") == false)
        controller.restoreAll()
        #expect(hardware.speed(7) == 3 << 16)
    }

    @Test func aDisconnectedDeviceKeepsItsRecordUntilItReturns() {
        let (controller, hardware) = Self.setup()
        controller.apply(Self.settings(), connected: [Self.device()])
        controller.apply(Self.settings(), connected: [])
        #expect(controller.records[Self.id] != nil)
        controller.restoreLeftovers(connected: [Self.device()])
        #expect(hardware.speed(1) == 2 << 16)
        #expect(controller.records.isEmpty)
    }

    @Test func leftoversFromAnInterruptedRunAreRestored() {
        let hardware = FakeWheelHardware()
        hardware.add(1)
        hardware.values[.init(control: .speed, service: 1)] = .integer(1 << 16, byteSize: 4)
        hardware.originals[.init(control: .speed, service: 1)] = 2 << 16
        let record = WheelRecord(services: ["1": ["speed": WheelControlRecord(original: 2 << 16, byteSize: 4, written: 1 << 16)]])
        let controller = WheelController(records: [Self.id: record], hardware: hardware)
        controller.restoreLeftovers(connected: [Self.device()])
        #expect(hardware.speed(1) == 2 << 16)
        #expect(controller.records.isEmpty)
    }

    @Test func aValueChangedOutsideWhiskerIsNotOverwrittenOnRestore() {
        let (controller, hardware) = Self.setup()
        controller.apply(Self.settings(), connected: [Self.device()])
        hardware.values[.init(control: .speed, service: 1)] = .integer(9 << 16, byteSize: 4)
        controller.restoreAll()
        #expect(hardware.speed(1) == 9 << 16)
        #expect(controller.records.isEmpty)
    }

    @Test func ambiguousIdenticalDevicesAreNeverWritten() {
        let (controller, hardware) = Self.setup(services: [1, 2])
        hardware.lookups[Self.id] = .ambiguous
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(hardware.writes.isEmpty)
        #expect(controller.status(of: .speed, device: Self.id) == .unavailable(.ambiguousDevice))

        // Two identical mice without serials are listed as one device with two physical keys.
        let (second, secondHardware) = Self.setup(services: [1, 2])
        second.apply(Self.settings(), connected: [Self.device(keys: ["usb-a", "usb-b"])])
        #expect(secondHardware.writes.isEmpty)
        #expect(second.status(of: .speed, device: Self.id) == .unavailable(.ambiguousDevice))

        // A serial number makes the identity unambiguous.
        let id = "046d:c52b:ABC"
        let (third, thirdHardware) = Self.setup(services: [1])
        thirdHardware.lookups[id] = .services([1])
        third.apply(Self.settings(id), connected: [Self.device(id, serial: "ABC", keys: ["a", "b"])])
        #expect(third.activeDevices == [id])
    }

    @Test func controlsWithoutATypedOriginalStayUnavailableAndUntouched() {
        let (controller, hardware) = Self.setup()
        hardware.values[.init(control: .speed, service: 1)] = .unsupportedType
        hardware.values[.init(control: .acceleration, service: 1)] = .missing
        controller.apply(Self.settings(speed: 2, acceleration: 1), connected: [Self.device()])
        #expect(hardware.writes.isEmpty)
        #expect(controller.status(of: .speed, device: Self.id) == .unavailable(.unexpectedType))
        #expect(controller.status(of: .acceleration, device: Self.id) == .unavailable(.noOriginal))
        #expect(controller.activeDevices.isEmpty)

        hardware.values[.init(control: .speed, service: 1)] = .integer(Int64.max, byteSize: 8)
        controller.apply(Self.settings(speed: 2, acceleration: 1).withTouchedSpeed(), connected: [Self.device()])
        #expect(controller.status(of: .speed, device: Self.id) == .unavailable(.outOfRange))
    }

    @Test func bypassPutsTheUsersValuesBackAndReappliesAfterwards() {
        let (controller, hardware) = Self.setup()
        controller.apply(Self.settings(), connected: [Self.device()])
        controller.apply(Self.settings(), connected: [Self.device()], bypassed: true)
        #expect(hardware.speed(1) == 2 << 16)
        #expect(controller.activeDevices.isEmpty)
        controller.apply(Self.settings(), connected: [Self.device()])
        #expect(hardware.speed(1) == 1 << 16)
        #expect(controller.activeDevices == [Self.id])
    }

    @Test func otherDevicesAndExcludedOnesAreUntouched() {
        let (controller, hardware) = Self.setup()
        let otherID = "1234:abcd"
        hardware.lookups[otherID] = .services([5])
        hardware.add(5)
        var settings = Self.settings()
        settings.devices[otherID] = DeviceSettings(wheel: WheelSettings(native: NativeWheelSettings(enabled: true, speed: 2)))
        var trackpad = Self.device(otherID)
        trackpad.excludedKind = .trackpad
        controller.apply(settings, connected: [Self.device(), trackpad])
        #expect(hardware.speed(5) == 2 << 16)
        #expect(controller.activeDevices == [Self.id])
    }

    @Test func changingTheValueRestoresFirstSoOriginalsStayTheSystems() {
        let (controller, hardware) = Self.setup()
        controller.apply(Self.settings(speed: 2), connected: [Self.device()])
        controller.apply(Self.settings(speed: 4), connected: [Self.device()])
        #expect(hardware.speed(1) == Int64(32768))
        #expect(controller.records[Self.id]?.services["1"]?["speed"]?.original == 2 << 16)
    }

    @Test func runStateRoundTripsRecordsAndOlderFilesDecode() throws {
        let record = WheelRecord(services: ["1": ["speed": WheelControlRecord(original: 5, byteSize: 4, written: 3)]])
        var state = RunState()
        state.cleanExit = false
        state.originalWheels = [Self.id: record]
        #expect(try JSONDecoder().decode(RunState.self, from: JSONEncoder().encode(state)) == state)
        let old = try JSONDecoder().decode(RunState.self, from: Data(#"{"cleanExit":false,"originalPointers":{}}"#.utf8))
        #expect(old.originalWheels.isEmpty && !old.cleanExit)
    }
}

private extension WhiskerSettings {
    /// Forces a re-apply by changing the request.
    func withTouchedSpeed() -> WhiskerSettings {
        var copy = self
        copy.devices.keys.forEach { copy.devices[$0]?.wheel.native?.speed = 3 }
        return copy
    }
}
