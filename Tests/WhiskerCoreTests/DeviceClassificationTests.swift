import Testing
@testable import WhiskerCore

@Suite("Device classification")
struct DeviceClassificationTests {
    private func interface(
        _ product: String, vendor: Int = 0x1234, productID: Int = 0x0001, serial: String? = nil,
        location: Int? = 0x2000_0000, number: Int?, usage: Int, page: Int = HIDUsage.genericDesktopPage,
        transport: String = "USB"
    ) -> HIDInterfaceInfo {
        HIDInterfaceInfo(
            vendorID: vendor, productID: productID, serial: serial, product: product, transport: transport,
            locationID: location, interfaceNumber: number, primaryUsagePage: page, primaryUsage: usage
        )
    }

    @Test func keyboardWithMouseKeysIsNotListed() {
        let moonlander = [
            interface("Moonlander Mark I", serial: "Ry7re", number: 0, usage: HIDUsage.keyboard),
            interface("Moonlander Mark I", serial: "Ry7re", number: 1, usage: 0x61, page: 0xFF60),
            interface("Moonlander Mark I", serial: "Ry7re", number: 2, usage: HIDUsage.mouse),
        ]
        #expect(PointingDeviceClassifier.pointingDevices(from: moonlander).isEmpty)
    }

    @Test func gamingMouseWithMacroKeyboardIsListedOnce() {
        let mouse = [
            interface("Gaming Mouse", number: 0, usage: HIDUsage.mouse),
            interface("Gaming Mouse", number: 1, usage: HIDUsage.keyboard),
            interface("Gaming Mouse", number: 2, usage: HIDUsage.keyboard),
        ]
        let devices = PointingDeviceClassifier.pointingDevices(from: mouse)
        #expect(devices.map(\.name) == ["Gaming Mouse"])
        #expect(devices.first?.physicalKeys == ["location:\(0x2000_0000)"])
    }

    @Test func receiverThatLeadsWithAKeyboardIsStillAMouse() {
        let unifying = [
            interface("Logitech, Inc. Unifying Receiver", vendor: 0x046D, productID: 0xC526, number: 0, usage: HIDUsage.keyboard),
            interface("Logitech, Inc. Unifying Receiver", vendor: 0x046D, productID: 0xC526, number: 1, usage: HIDUsage.mouse),
            interface("Logitech, Inc. Unifying Receiver", vendor: 0x046D, productID: 0xC526, number: 2, usage: HIDUsage.mouse),
        ]
        #expect(PointingDeviceClassifier.pointingDevices(from: unifying).map(\.id) == ["046d:c526"])
    }

    @Test func onlyPrimaryUsageCounts() {
        // Reports mouse usages, but is primarily something else (a digitizer, a vendor page).
        let other = [
            interface("Pen Tablet", number: 0, usage: 0x02, page: 0x0D),
            interface("Pen Tablet", number: 1, usage: 0x01, page: 0xFF0A),
        ]
        #expect(PointingDeviceClassifier.pointingDevices(from: other).isEmpty)
    }

    @Test func interfacesGroupByLocationAndDevicesByIdentity() {
        let devices = PointingDeviceClassifier.pointingDevices(from: [
            interface("Trackball", productID: 1, location: 1, number: 0, usage: HIDUsage.mouse),
            interface("Keyboard", productID: 2, location: 2, number: 0, usage: HIDUsage.keyboard),
            interface("Keyboard", productID: 2, location: 2, number: 1, usage: HIDUsage.mouse),
            // Same model plugged in twice without a serial: one entry, both locations.
            interface("Basic Mouse", productID: 3, location: 3, number: 0, usage: HIDUsage.mouse),
            interface("Basic Mouse", productID: 3, location: 4, number: 0, usage: HIDUsage.mouse),
            // No location: grouped by identity instead.
            interface("BT Mouse", productID: 4, location: nil, number: nil, usage: HIDUsage.pointer, transport: "Bluetooth"),
        ])
        #expect(devices.map(\.name) == ["Basic Mouse", "BT Mouse", "Trackball"])
        #expect(devices.first?.physicalKeys == ["location:3", "location:4"])
    }

    @Test func bluetoothKeyboardAndMouseWithoutInterfaceNumbersKeepsTheMouse() {
        let combo = [
            interface("Combo", location: 9, number: nil, usage: HIDUsage.keyboard, transport: "Bluetooth"),
            interface("Combo", location: 9, number: nil, usage: HIDUsage.mouse, transport: "Bluetooth"),
        ]
        #expect(PointingDeviceClassifier.pointingDevices(from: combo).count == 1)
    }

    @Test func trackpadsAreListedButLeftAlone() {
        let devices = PointingDeviceClassifier.pointingDevices(from: [
            interface("Apple Internal Keyboard / Trackpad", vendor: 0x05AC, location: 5, number: nil, usage: HIDUsage.mouse, transport: "FIFO"),
            interface("Apple Internal Keyboard / Trackpad", vendor: 0x05AC, location: 5, number: nil, usage: HIDUsage.keyboard, transport: "FIFO"),
        ])
        #expect(devices.count == 1)
        #expect(devices.first?.isExcluded == true)
    }
}
