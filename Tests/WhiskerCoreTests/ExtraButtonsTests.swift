import Foundation
import Testing
@testable import WhiskerCore

@Suite("Extra button discovery")
struct ExtraButtonsTests {
    private func button(_ usage: Int = 33) -> ExtraButtonElement {
        ExtraButtonElement(kind: .input, page: 0x09, usage: usage)
    }

    @Test func compositeKeyboardAndPrimaryStayMetadataOnly() {
        let elements = [
            button(1), button(),
            ExtraButtonElement(kind: .input, page: 0x0C, usage: 0xE9),
            ExtraButtonElement(kind: .input, page: 0x07, usage: 4),
            ExtraButtonElement(kind: .input, page: 0x0C, usage: 0xEA, topUsage: 6),
            ExtraButtonElement(kind: .input, page: 0x09, usage: 34, keyboardCollection: true),
        ]
        let controls = ExtraButtonDiscovery.controls(elements: elements, associationProven: true)
        #expect(controls.map(\.id) == [0, 1, 2, 4, 5])
        #expect(controls.map(\.status) == [.unsupported, .awaiting, .awaiting, .unsupported, .unsupported])
        #expect(controls[1].identity == ExtraControlIdentity(namespace: "hid.generic", control: "report:0/page:9/usage:33"))
    }

    @Test func duplicateDescriptorsAreAmbiguousRatherThanInventedButtons() {
        let controls = ExtraButtonDiscovery.controls(elements: [button(), button()], associationProven: true)
        #expect(controls.map(\.status) == [.ambiguous, .ambiguous])
        #expect(controls[0].identity == controls[1].identity)
        #expect(ExtraButtonDiscovery.controls(elements: [button()], associationProven: false)[0].status == .ambiguous)
    }

    @Test func unknownMalformedArraysAndUnprovenCollectionsAreNotObserved() {
        var malformed = button(); malformed.maximum = -1
        var array = button(); array.isArray = true
        var unknown = button(); unknown.kind = .other
        var output = button(); output.kind = .output
        var feature = button(); feature.kind = .feature
        var unproven = button(); unproven.topPage = 0
        var wrongRange = button(); wrongRange.maximum = 255
        var badReport = button(); badReport.reportID = 256
        for element in [malformed, array, unknown, output, feature, unproven, wrongRange, badReport, button(0), button(65536)] {
            #expect(ExtraButtonDiscovery.controls(elements: [element], associationProven: true)[0].status == .unsupported)
        }
        #expect(ExtraButtonDiscovery.controls(elements: Array(repeating: button(), count: 513), associationProven: true).isEmpty)
    }

    @Test func associationNeverUsesTheOnlyListedMouseOrReceiverIdentity() throws {
        let direct = HIDInterfaceInfo(vendorID: 0x1234, productID: 1, serial: "A", product: "Mouse",
                                      transport: "Bluetooth", locationID: 10, primaryUsagePage: 1, primaryUsage: 2)
        let device = try #require(PointingDeviceClassifier.pointingDevices(from: [direct]).first)
        #expect(ExtraButtonDiscovery.associationProven(device: device, metadata: [direct]))
        #expect(!ExtraButtonDiscovery.associationProven(device: device, metadata: []))
        var receiver = direct; receiver.transport = "USB"
        let usb = try #require(PointingDeviceClassifier.pointingDevices(from: [receiver]).first)
        #expect(!ExtraButtonDiscovery.associationProven(device: usb, metadata: [receiver]))
        var second = receiver; second.interfaceNumber = 2
        #expect(!ExtraButtonDiscovery.associationProven(device: usb, metadata: [receiver, second]))
        var noSerial = device; noSerial.serial = nil
        #expect(!ExtraButtonDiscovery.associationProven(device: noSerial, metadata: [direct]))
        var twin = direct; twin.locationID = 20
        let twins = try #require(PointingDeviceClassifier.pointingDevices(from: [direct, twin]).first)
        #expect(!ExtraButtonDiscovery.associationProven(device: twins, metadata: [direct, twin]))
        var unrelatedKeyboard = direct; unrelatedKeyboard.primaryUsage = 6; unrelatedKeyboard.locationID = 30
        #expect(!ExtraButtonDiscovery.associationProven(device: device, metadata: [unrelatedKeyboard]))
        var touch = device; touch.excludedKind = .touchMouse
        #expect(!ExtraButtonDiscovery.associationProven(device: touch, metadata: [direct]))
    }

    @Test func duplicateAndReorderedValuesKeepReleasesWithoutInventingPresses() {
        var recorder = ExtraButtonRecorder(runtimeID: 7, allowed: [2, 3])
        func value(_ index: Int, _ value: Int, _ timestamp: UInt64) -> ExtraButtonObservation {
            ExtraButtonObservation(runtimeID: 7, elementIndex: index, value: value, timestamp: timestamp)
        }
        let accepted = [
            recorder.accept(value(2, 0, 10)), recorder.accept(value(2, 1, 20)),
            recorder.accept(value(2, 1, 30)), recorder.accept(value(2, 0, 25)),
            recorder.accept(value(3, 1, 15)), // Ordering belongs to each control, not the whole interface.
            recorder.accept(value(2, 0, 40)), recorder.accept(value(2, 1, 40)), recorder.accept(value(3, 0, 50)),
        ]
        #expect(accepted == [true, true, false, false, true, true, false, true])
        #expect(recorder.observations.map(\.value) == [0, 1, 1, 0, 0])
    }

    @Test func malformedUnknownAndStaleConnectionValuesAreRejectedAndHistoryIsBounded() {
        var recorder = ExtraButtonRecorder(runtimeID: 7, allowed: [2])
        for observation in [
            ExtraButtonObservation(runtimeID: 8, elementIndex: 2, value: 1, timestamp: 1),
            ExtraButtonObservation(runtimeID: 7, elementIndex: 3, value: 1, timestamp: 1),
            ExtraButtonObservation(runtimeID: 7, elementIndex: 2, value: -1, timestamp: 1),
            ExtraButtonObservation(runtimeID: 7, elementIndex: 2, value: 2, timestamp: 1),
            ExtraButtonObservation(runtimeID: 7, elementIndex: 2, value: 1, timestamp: 0),
        ] {
            let accepted = recorder.accept(observation)
            #expect(!accepted)
        }
        for t in 1...1000 {
            recorder.accept(ExtraButtonObservation(runtimeID: 7, elementIndex: 2, value: t % 2, timestamp: UInt64(t)))
        }
        #expect(recorder.observations.count == 128)
        #expect(recorder.observations.last?.value == 0)
        recorder = ExtraButtonRecorder(runtimeID: 8, allowed: [2])
        #expect(recorder.observations.isEmpty)
        let accepted = recorder.accept(ExtraButtonObservation(runtimeID: 8, elementIndex: 2, value: 1, timestamp: 1))
        #expect(accepted)
    }

    @Test func additiveSettingsKeepOrdinaryMappingsAndOpaqueFutureRecords() throws {
        let old = try SettingsCodec.decode(Data(#"{"schemaVersion":2,"devices":{"1234:0001":{"enabled":true}},"future":{"keep":[1,true]}}"#.utf8))
        #expect(!old.device("1234:0001").extraButtons.discoveryEnabled)
        #expect(old.device("1234:0001").extraButtonMappings.isEmpty)
        let oldEncoded = String(decoding: try SettingsCodec.encode(old), as: UTF8.self)
        #expect(!oldEncoded.contains("extraButtons"))
        #expect(!oldEncoded.contains("extraButtonMappings"))
        var configured = old
        configured.devices["1234:0001"]?.extraButtons.discoveryEnabled = true
        configured.devices["1234:0001"]?.extraButtonMappings = [
            "vendor.example:control": .object(["futureAction": .object(["unknown": .bool(true)])])
        ]
        let decoded = try SettingsCodec.decodeValidated(SettingsCodec.encode(configured))
        #expect(decoded == configured)
        #expect(decoded.profiles == old.profiles)
        #expect(decoded.unknownKeys == old.unknownKeys)
        #expect(decoded.general == old.general)
        #expect(try JSONDecoder().decode(ExtraButtonSettings.self, from: Data("{}".utf8)).discoveryEnabled == false)
    }
}
