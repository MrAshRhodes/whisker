import Foundation
import Testing
@testable import Whisker
@testable import WhiskerCore

@Suite("Pointer controller")
@MainActor
struct PointerControllerTests {
    final class FakeHardware: PointerHardware {
        var services: [String: Set<UInt64>] = [:]
        var refuses = false
        private(set) var writes: [String] = []

        func serviceIDs(for deviceID: String) -> Set<UInt64> { services[deviceID] ?? [] }

        func currentValues(of deviceID: String) -> OriginalPointer? {
            services[deviceID] == nil ? nil : OriginalPointer(resolution: 400 << 16, acceleration: 1 << 16)
        }

        func write(resolution: Int64, acceleration: Int64?, to deviceID: String) -> Bool {
            guard services[deviceID] != nil, !refuses else { return false }
            writes.append(deviceID)
            return true
        }
    }

    static let id = "046d:c52b"
    static let device = PointingDevice(
        id: id, name: "Mouse", vendorID: 0x046D, productID: 0xC52B, serial: nil, transport: "USB", excludedKind: nil, physicalKeys: ["usb"]
    )

    static func settings() -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.devices[id] = DeviceSettings(pointer: PointerSettings(speed: 7, acceleration: 0.5))
        return settings
    }

    @Test func reconnectedDeviceIsWrittenAgain() {
        let hardware = FakeHardware()
        hardware.services[Self.id] = [1]
        let controller = PointerController(hardware: hardware)

        controller.apply(Self.settings(), connected: [Self.device])
        controller.apply(Self.settings(), connected: [Self.device])
        #expect(hardware.writes.count == 1)

        controller.apply(Self.settings(), connected: [])
        controller.apply(Self.settings(), connected: [Self.device])
        #expect(hardware.writes.count == 2)

        // Reconnected without the device list noticing: the service is new.
        hardware.services[Self.id] = [2]
        controller.apply(Self.settings(), connected: [Self.device])
        #expect(hardware.writes.count == 3)
    }

    @Test func failedWritesAreRetried() {
        let hardware = FakeHardware()
        let controller = PointerController(hardware: hardware)

        controller.apply(Self.settings(), connected: [Self.device])
        #expect(hardware.writes.isEmpty)

        hardware.services[Self.id] = [1]
        hardware.refuses = true
        controller.apply(Self.settings(), connected: [Self.device])
        #expect(controller.unsupported.contains(Self.id))

        hardware.refuses = false
        controller.apply(Self.settings(), connected: [Self.device])
        #expect(hardware.writes == [Self.id])
        #expect(!controller.unsupported.contains(Self.id))
    }
}
