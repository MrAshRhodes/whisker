import Foundation
import IOKit.hid
import Testing
@testable import Whisker
@testable import WhiskerCore

private final class DiscoveryAccess: HIDDeviceAccess {
    var elementsRead: [Int] = []
    var layouts: [Int: [HIDElementDescription]] = [:]
    var observations: [Int: [Int]] = [:]
    var handlers: [Int: (ExtraButtonObservation) -> Void] = [:]
    var ends: [Int: () -> Void] = [:]
    var stopped: [Int] = []
    var refusing = false
    func register(_ device: IOHIDDevice) -> Int { 0 }
    func forget(runtimeID: Int) {}
    func elements(of runtimeID: Int) -> [HIDElementDescription]? {
        elementsRead.append(runtimeID)
        return layouts[runtimeID]
    }
    func readValues(of runtimeID: Int, indexes: [Int], completion: @escaping ([Int?]) -> Void) {
        Issue.record("Discovery must not issue get-value requests")
    }
    func observeReports(of runtimeID: Int, onReport: @escaping @Sendable (HIDReportTiming) -> Void, onEnd: @escaping () -> Void) -> Bool {
        Issue.record("Discovery must not install report callbacks")
        return false
    }
    func observeExtraButtonValues(of runtimeID: Int, indexes: [Int],
                                  onValue: @escaping (ExtraButtonObservation) -> Void, onEnd: @escaping () -> Void) -> Bool {
        guard !refusing else { return false }
        observations[runtimeID] = indexes
        handlers[runtimeID] = onValue
        ends[runtimeID] = onEnd
        return true
    }
    func stopObservingExtraButtonValues(of runtimeID: Int) {
        observations[runtimeID] = nil
        stopped.append(runtimeID)
    }
}

private final class DiscoverySource: ExtraButtonSource {
    var devices: [ConnectedDevice] = []
    var interfaces: [InputTimingInterface] = [InputTimingInterface(runtimeID: 1, interfaceNumber: nil)]
    var metadata: [HIDInterfaceInfo] = []
    func pointingInterfaces(ofDevice id: String) -> [InputTimingInterface] { interfaces }
    func discoveryMetadata(ofDevice id: String) -> [HIDInterfaceInfo] { metadata }
}

@Suite("Extra button discovery controller")
@MainActor
struct ExtraButtonDiscoveryTests {
    private final class Harness {
        let access = DiscoveryAccess()
        let source = DiscoverySource()
        var settings = WhiskerSettings()
        var granted = true
        var timer: (() -> Void)?
        var controller: ExtraButtonDiscoveryController!
        var id: String { source.devices[0].id }

        init(transport: String = "Bluetooth") {
            let info = HIDInterfaceInfo(vendorID: 0x1234, productID: 1, serial: "A", product: "Mouse",
                                        transport: transport, locationID: 10, primaryUsagePage: 1, primaryUsage: 2)
            source.metadata = [info]
            source.devices = PointingDeviceClassifier.pointingDevices(from: [info])
            settings.devices[id] = DeviceSettings(extraButtons: ExtraButtonSettings(discoveryEnabled: true))
            access.layouts[1] = [
                HIDElementDescription(kind: .input, usagePage: 9, usage: 1, logicalMin: 0, logicalMax: 1, topLevelUsagePage: 1, topLevelUsage: 2),
                HIDElementDescription(kind: .input, usagePage: 9, usage: 33, logicalMin: 0, logicalMax: 1, topLevelUsagePage: 1, topLevelUsage: 2),
                HIDElementDescription(kind: .input, usagePage: 12, usage: 0xE9, logicalMin: 0, logicalMax: 1, topLevelUsagePage: 1, topLevelUsage: 2),
                HIDElementDescription(kind: .input, usagePage: 7, usage: 4, logicalMin: 0, logicalMax: 1, topLevelUsagePage: 1, topLevelUsage: 6),
                HIDElementDescription(kind: .input, usagePage: 12, usage: 0xEA, logicalMin: 0, logicalMax: 1, topLevelUsagePage: 1, topLevelUsage: 2, hasKeyboardCollection: true),
            ]
            controller = ExtraButtonDiscoveryController(access: access, source: source,
                permission: { [unowned self] in granted }, settings: { [unowned self] in settings },
                schedule: { [unowned self] _, callback in
                    timer = callback
                    return { [weak self] in self?.timer = nil }
                })
        }

        func emit(_ value: Int, timestamp: UInt64, index: Int = 1, runtimeID: Int = 1) {
            access.handlers[runtimeID]?(ExtraButtonObservation(runtimeID: runtimeID, elementIndex: index, value: value, timestamp: timestamp))
        }
    }

    @Test func offAndPermissionDeniedNeverReadOrObserveDevices() {
        let h = Harness()
        #expect(h.access.elementsRead.isEmpty)
        h.settings.devices[h.id]?.extraButtons.discoveryEnabled = false
        h.controller.start(deviceID: h.id)
        #expect(h.access.elementsRead.isEmpty)
        h.settings.devices[h.id]?.extraButtons.discoveryEnabled = true
        h.granted = false
        h.controller.start(deviceID: h.id)
        #expect(h.access.elementsRead.isEmpty)
        #expect(h.access.observations.isEmpty)
        #expect(h.controller.message.contains("Input Monitoring"))
    }

    @Test func compositeAndUnrelatedKeyboardsNeverSupplyAnInputStream() {
        let h = Harness()
        var keyboard = h.source.metadata[0]; keyboard.primaryUsage = 6
        h.source.metadata.append(keyboard)
        // Keyboard runtime IDs are deliberately not supplied by pointingInterfaces.
        h.access.layouts[2] = h.access.layouts[1]
        h.access.layouts[3] = h.access.layouts[1]
        h.controller.start(deviceID: h.id)
        #expect(h.access.elementsRead == [1])
        #expect(h.access.observations == [1: [1, 2]])
        #expect(h.controller.keyboardInterfaces == 1)
        h.emit(1, timestamp: 10)
        h.timer?()
        #expect(h.controller.interfaces[0].controls[1].status == .observed(1))
        h.emit(0, timestamp: 20)
        h.timer?()
        #expect(h.controller.interfaces[0].controls[1].status == .observed(0))
        #expect(h.controller.interfaces[0].controls.last?.status == .unsupported)
    }

    @Test func receiverAndIdenticalDevicesStayAmbiguousWithNoObservation() {
        let receiver = Harness(transport: "USB")
        var second = receiver.source.metadata[0]; second.interfaceNumber = 2
        receiver.source.metadata.append(second)
        receiver.source.interfaces.append(InputTimingInterface(runtimeID: 2, interfaceNumber: 2))
        receiver.access.layouts[2] = receiver.access.layouts[1]
        receiver.controller.start(deviceID: receiver.id)
        #expect(receiver.access.observations.isEmpty)
        #expect(receiver.controller.interfaces[0].controls[1].status == .ambiguous)
        #expect(receiver.controller.message.contains("metadata only"))
        let twin = Harness()
        twin.source.devices[0].physicalKeys.insert("location:20")
        twin.controller.start(deviceID: twin.id)
        #expect(twin.access.observations.isEmpty)
    }

    @Test func missingIdentityAndExcludedDevicesNeverListen() {
        let missing = Harness()
        missing.source.devices[0].serial = nil
        missing.controller.start(deviceID: missing.id)
        #expect(missing.access.observations.isEmpty)
        let touch = Harness()
        touch.source.devices[0].excludedKind = .touchMouse
        touch.controller.start(deviceID: touch.id)
        #expect(touch.access.elementsRead.isEmpty)
        #expect(touch.access.observations.isEmpty)
    }

    @Test func permissionRevocationClearsImmediatelyAndKeepsSettingsUnchanged() {
        let h = Harness()
        let before = h.settings
        h.controller.start(deviceID: h.id)
        h.emit(1, timestamp: 10)
        h.granted = false
        h.emit(0, timestamp: 20)
        #expect(h.controller.interfaces.isEmpty)
        #expect(h.access.observations.isEmpty)
        #expect(h.timer == nil)
        #expect(h.controller.message.contains("Input Monitoring was lost"))
        #expect(h.settings == before)
    }

    @Test func disableProfileSleepAndCloseClearAndLateCallbacksCannotRepopulate() {
        for reason in ["Disabled", "Profile changed", "Sleep", "Sheet closed"] {
            let h = Harness()
            h.controller.start(deviceID: h.id)
            h.emit(1, timestamp: 10)
            let oldHandler = h.access.handlers[1]
            let oldEnd = h.access.ends[1]
            h.controller.stop(reason: reason)
            #expect(h.controller.interfaces.isEmpty)
            #expect(h.access.observations.isEmpty)
            h.controller.start(deviceID: h.id)
            oldHandler?(ExtraButtonObservation(runtimeID: 1, elementIndex: 1, value: 1, timestamp: 50))
            oldEnd?()
            h.timer?()
            #expect(h.controller.isInspecting)
            #expect(h.controller.interfaces[0].controls[1].status == .awaiting)
        }
    }

    @Test func disconnectedAndReconnectedRuntimeCannotReuseOldState() {
        let h = Harness()
        h.controller.start(deviceID: h.id)
        h.emit(1, timestamp: 10)
        h.source.interfaces = [InputTimingInterface(runtimeID: 5, interfaceNumber: nil)]
        h.access.layouts[5] = h.access.layouts[1]
        h.controller.environmentChanged()
        #expect(h.controller.interfaces.isEmpty)
        #expect(h.access.observations.isEmpty)
        h.controller.start(deviceID: h.id)
        h.emit(1, timestamp: 20)
        h.timer?()
        #expect(h.controller.interfaces[0].controls[1].status == .awaiting)
        h.settings.devices[h.id]?.enabled = false
        h.timer?()
        #expect(h.controller.interfaces.isEmpty)
        #expect(h.access.observations.isEmpty)
    }

    @Test func missingOversizeDescriptorsFailedOpensAndEndedQueuesFailClosed() {
        let h = Harness()
        h.access.layouts[1] = nil
        h.controller.start(deviceID: h.id)
        #expect(!h.controller.isInspecting)
        let huge = Harness()
        huge.access.layouts[1] = Array(repeating: huge.access.layouts[1]![1], count: 513)
        huge.controller.start(deviceID: huge.id)
        #expect(huge.access.observations.isEmpty)
        let refusing = Harness()
        refusing.access.refusing = true
        refusing.controller.start(deviceID: refusing.id)
        #expect(!refusing.controller.isInspecting)
        #expect(refusing.controller.interfaces.isEmpty)
        let ended = Harness()
        ended.controller.start(deviceID: ended.id)
        ended.access.ends[1]?()
        #expect(ended.controller.interfaces.isEmpty)
        #expect(ended.access.observations.isEmpty)
    }
}
