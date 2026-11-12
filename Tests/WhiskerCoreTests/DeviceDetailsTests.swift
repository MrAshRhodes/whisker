import Foundation
import Testing
@testable import WhiskerCore

@Suite("Device details")
struct DeviceDetailsTests {
    private func interface(
        _ product: String?, vendor: Int = 0x046D, productID: Int = 0xC52B, serial: String? = nil,
        location: Int? = 0x1400_0000, transport: String? = "USB"
    ) -> HIDInterfaceInfo {
        HIDInterfaceInfo(
            vendorID: vendor, productID: productID, serial: serial, product: product, transport: transport,
            locationID: location, interfaceNumber: 0, primaryUsagePage: HIDUsage.genericDesktopPage, primaryUsage: HIDUsage.mouse
        )
    }

    private func devices(_ interfaces: HIDInterfaceInfo...) -> [PointingDevice] {
        PointingDeviceClassifier.pointingDevices(from: interfaces)
    }

    private func details(
        _ devices: [PointingDevice], controls: [String: ControlsReport] = [:],
        identification: IdentificationStatus = .listening, recent: Set<String> = []
    ) -> [DeviceDetails] {
        DeviceDetailsBuilder.details(for: devices, controls: controls, identification: identification, recentInput: recent)
    }

    /// An element of the kind IOKit reports: 2 is a button input, 1 a miscellaneous input such as a wheel.
    private func element(_ page: Int, _ usage: Int, type: Int = 2) -> HIDElementInfo {
        HIDElementInfo(kind: HIDElementKind(ioKitType: type), usagePage: page, usage: usage)
    }

    // MARK: Reported controls

    @Test func reportedButtonsAreDeduplicatedAndNumberedFromZero() {
        let controls = ReportedControls(elements: [3, 1, 2, 1, 3].map { element(HIDUsage.buttonPage, $0) })
        #expect(controls.buttons == [0, 1, 2])
    }

    @Test func onlyInputElementsWithMappableUsagesCount() {
        let controls = ReportedControls(elements: [
            element(HIDUsage.buttonPage, 2),
            element(HIDUsage.buttonPage, 5, type: 129),
            element(HIDUsage.buttonPage, 6, type: 513),
            element(HIDUsage.buttonPage, 0),
            element(HIDUsage.buttonPage, 33),
            element(0xFF00, 3),
            element(HIDUsage.genericDesktopPage, HIDUsage.wheel, type: 257),
        ])
        #expect(controls.buttons == [1])
        #expect(!controls.verticalWheel && !controls.horizontalWheel)
    }

    @Test func wheelsAreRecognisedByTheirUsages() {
        let vertical = element(HIDUsage.genericDesktopPage, HIDUsage.wheel, type: 1)
        let horizontal = element(HIDUsage.consumerPage, HIDUsage.acPan, type: 1)
        #expect(ReportedControls(elements: [vertical]).wheelSummary == "Vertical wheel")
        #expect(ReportedControls(elements: [horizontal]).wheelSummary == "Horizontal wheel")
        #expect(ReportedControls(elements: [vertical, horizontal]).wheelSummary == "Vertical and horizontal wheel")
        #expect(ReportedControls(elements: [element(HIDUsage.buttonPage, 1)]).wheelSummary == nil)
    }

    @Test func buttonSummaryNamesTheFirstThreeAndCollapsesRuns() {
        #expect(ReportedControls(buttons: []).buttonSummary == nil)
        #expect(ReportedControls(buttons: [0]).buttonSummary == "Primary Button")
        #expect(ReportedControls(buttons: [0, 1, 2]).buttonSummary == "Primary Button, Secondary Button, Middle Button")
        #expect(ReportedControls(buttons: [3]).buttonSummary == "Button 4")
        #expect(ReportedControls(buttons: Array(0...7)).buttonSummary == "Primary Button, Secondary Button, Middle Button, Buttons 4–8")
        #expect(ReportedControls(buttons: [0, 4, 6, 7]).buttonSummary == "Primary Button, Button 5, Buttons 7–8")
    }

    @Test func noElementsIsUnavailableWhileAnEmptyListIsStillAList() {
        #expect(ControlsReport.read(nil) == .unavailable(.notProvided))
        #expect(ControlsReport.read([]) == .unavailable(.notProvided))
        #expect(ControlsReport.read([element(0xFF00, 1)]) == .reported(ReportedControls()))
    }

    @Test func missingControlsAreNeverShownAsZeroButtons() throws {
        let device = devices(interface("Mouse"))
        let none = try #require(details(device, controls: [device[0].id: .reported(ReportedControls())]).first)
        let missing = try #require(details(device, controls: [:]).first)
        #expect(none.controlsButtonsText == "None reported")
        #expect(none.controlsWheelsText == "None reported")
        #expect(missing.controlsButtonsText == "Unavailable")
        #expect(missing.controlsWheelsText == "Unavailable")
        #expect(missing.notes.contains(.controlsUnavailable(.notProvided)))
        #expect(!none.notes.contains(.controlsUnavailable(.notProvided)))
    }

    @Test func eachUnavailableReasonSaysWhyWithoutImplyingNoButtons() {
        let off = DeviceNote.controlsUnavailable(.inputMonitoringOff).text
        let notProvided = DeviceNote.controlsUnavailable(.notProvided).text
        let away = DeviceNote.controlsUnavailable(.notConnected).text
        #expect(off.contains("Input Monitoring"))
        #expect(off.contains("doesn't ask for it just to show details"))
        #expect(!notProvided.contains("Input Monitoring"))
        #expect(away.contains("connected"))
        for text in [off, notProvided] {
            #expect(text.contains("says nothing about how many buttons"))
        }
    }

    @Test func interfacesOfOneDeviceCombineIntoOneList() {
        let first = ControlsReport.reported(ReportedControls(buttons: [0, 1], verticalWheel: true))
        let second = ControlsReport.reported(ReportedControls(buttons: [1, 2, 3], horizontalWheel: true))
        #expect(ControlsReport.combine([first, second])
            == .reported(ReportedControls(buttons: [0, 1, 2, 3], verticalWheel: true, horizontalWheel: true)))
        #expect(ControlsReport.combine([.unavailable(.notProvided), .unavailable(.notProvided)]) == .unavailable(.notProvided))
        #expect(ControlsReport.combine([]) == .unavailable(.notProvided))
    }

    @Test func combinedUnavailableReportsKeepThePermissionReason() {
        let off = ControlsReport.unavailable(.inputMonitoringOff)
        let none = ControlsReport.unavailable(.notProvided)
        #expect(ControlsReport.combine([off, off]) == .unavailable(.inputMonitoringOff))
        #expect(ControlsReport.combine([none, off]) == .unavailable(.inputMonitoringOff))

        let readable = ControlsReport.reported(ReportedControls(buttons: [0]))
        guard case .reported(let controls) = ControlsReport.combine([readable, off]) else {
            Issue.record("The readable interface should still be listed")
            return
        }
        #expect(controls.isIncomplete)
    }

    @Test func aPartlyReadDeviceIsMarkedIncomplete() throws {
        let first = ControlsReport.reported(ReportedControls(buttons: [0, 1]))
        guard case .reported(let controls) = ControlsReport.combine([first, .unavailable(.notProvided)]) else {
            Issue.record("The readable interface should still be listed")
            return
        }
        #expect(controls.buttons == [0, 1])
        #expect(controls.isIncomplete)

        let device = devices(interface("Mouse"))
        let shown = try #require(details(device, controls: [device[0].id: .reported(controls)]).first)
        #expect(shown.notes.contains(.controlsIncomplete))
    }

    // MARK: Names and identities

    @Test func missingOrBlankProductNamesFallBackToTheIds() throws {
        let products: [String?] = [nil, "", "  \n"]
        for product in products {
            let shown = try #require(details(devices(interface(product))).first)
            #expect(shown.name == "Mouse 046D:C52B")
            #expect(shown.productName == nil)
            #expect(shown.productNameText == "Not reported")
            #expect(shown.notes.contains(.noProductName))
        }
        let named = try #require(details(devices(interface("  Logitech MX Master 3  "))).first)
        #expect(named.name == "Logitech MX Master 3")
        #expect(named.productName == "Logitech MX Master 3")
        #expect(!named.notes.contains(.noProductName))
    }

    @Test func absentPropertiesAreSaidToBeNotReported() throws {
        for transport in [nil, "  "] as [String?] {
            let shown = try #require(details(devices(interface(nil, location: nil, transport: transport))).first)
            #expect(shown.transport == nil)
            #expect(shown.transportText == "Not reported")
            #expect(shown.serialText == "Not reported")
            #expect(shown.identifiersText == "046D:C52B")
            #expect(shown.vendorIDText == "046D")
            #expect(shown.productIDText == "C52B")
        }
    }

    @Test func idsAMouseDidntReportAreNotShownAsZero() throws {
        let silent = try #require(details(devices(interface("Basic Mouse", vendor: 0, productID: 0))).first)
        #expect(silent.vendorIDText == "Not reported" && silent.productIDText == "Not reported")
        // The settings identity is unchanged: such mice share 0000:0000.
        #expect(silent.id == "0000:0000" && silent.identifiersText == "0000:0000")

        let zeroProduct = try #require(details(devices(interface("Basic Mouse", productID: 0))).first)
        #expect(zeroProduct.vendorIDText == "046D" && zeroProduct.productIDText == "0000")
    }

    @Test func serialNumbersAreReportedButConcealed() throws {
        let shown = try #require(details(devices(interface("MX Master", serial: "ABC123"))).first)
        #expect(shown.id == "046d:c52b:ABC123")
        #expect(shown.serial == .reported("ABC123"))
        #expect(shown.serialText == "Reported, hidden")
        #expect(shown.serialValue == "ABC123")

        let visibleByDefault: [String] = [
            shown.name, shown.identifiersText, shown.summaryText, shown.vendorIDText, shown.productIDText, shown.productNameText,
            shown.transportText, shown.serialText, shown.controlsButtonsText, shown.controlsWheelsText,
            shown.identification.title, shown.identification.explanation, shown.attribution.title, shown.attribution.explanation,
        ] + shown.notes.map(\.text)
        #expect(!visibleByDefault.contains { $0.contains("ABC123") })
        #expect(shown.summaryText == "046D:C52B · serial number hidden")

        let without = try #require(details(devices(interface("Basic Mouse"))).first)
        #expect(without.summaryText == "046D:C52B")
    }

    @Test func identitiesWithAndWithoutASerialAreKeptApartAndExplained() throws {
        let result = details(devices(
            interface("Basic Mouse", serial: "S1", location: 1),
            interface("Basic Mouse", location: 2),
            interface("Basic Mouse", serial: "   ", location: 3)
        ))
        // A blank serial is no serial, so the last two are one identity seen at two locations.
        #expect(Set(result.map(\.id)) == ["046d:c52b:S1", "046d:c52b"])
        let withSerial = try #require(result.first { $0.serial != .notReported })
        let without = try #require(result.first { $0.serial == .notReported })
        #expect(!withSerial.notes.contains(.noSerial))
        #expect(without.notes.contains(.noSerial))
        #expect(without.notes.contains(.sharedIdentity(devices: 2, hasSerial: false)))
    }

    @Test func devicesSharingAnIdentityAreOneAmbiguousEntry() throws {
        let result = details(
            devices(interface("Basic Mouse", location: 1), interface("Basic Mouse", location: 2)),
            recent: ["046d:c52b"]
        )
        #expect(result.count == 1)
        let shared = try #require(result.first)
        #expect(shared.presence == .connected(physicalDevices: 2))
        // Recent input can't single one of two identical devices out.
        #expect(shared.attribution == .ambiguousIdentity(devices: 2))
        #expect(shared.notes.contains(.sharedIdentity(devices: 2, hasSerial: false)))

        let withSerial = try #require(details(devices(
            interface("Basic Mouse", serial: "S1", location: 1), interface("Basic Mouse", serial: "S1", location: 2)
        )).first)
        #expect(withSerial.notes.contains(.sharedIdentity(devices: 2, hasSerial: true)))
        #expect(DeviceNote.sharedIdentity(devices: 2, hasSerial: true).text.contains("serial number"))
        #expect(!DeviceNote.sharedIdentity(devices: 2, hasSerial: false).text.contains("serial number"))
    }

    @Test func aSharedIdentityShowsTheSameDeviceWhateverTheOrder() {
        let bluetooth = interface("Basic Mouse", location: 1, transport: "Bluetooth")
        let usb = interface("Basic Mouse", location: 2, transport: "USB")
        let forwards = PointingDeviceClassifier.pointingDevices(from: [bluetooth, usb])
        let backwards = PointingDeviceClassifier.pointingDevices(from: [usb, bluetooth])
        #expect(forwards == backwards)
        #expect(forwards.first?.transport == "Bluetooth")
    }

    @Test func detailsFollowTheOrderOfTheDevices() {
        let list = devices(interface("B", productID: 2, location: 2), interface("A", productID: 1, location: 1))
        #expect(details(list).map(\.id) == list.map(\.id))
    }

    // MARK: Attribution and permission

    @Test func permissionAndAttributionAreReportedSeparately() throws {
        let solo = devices(interface("Solo"))
        for status in [IdentificationStatus.notAllowed, .couldNotListen, .listening] {
            let shown = try #require(details(solo, identification: status).first)
            #expect(shown.identification == status)
            #expect(shown.attribution == .inferredFromOnlyMouse)
        }

        let pair = devices(interface("A", productID: 1, location: 1), interface("B", productID: 2, location: 2))
        #expect(details(pair, identification: .listening).map(\.attribution) == [.unknown(.listening), .unknown(.listening)])
        #expect(details(pair, identification: .notAllowed).map(\.attribution) == [.unknown(.notAllowed), .unknown(.notAllowed)])
        #expect(details(pair, identification: .couldNotListen).map(\.attribution) == [.unknown(.couldNotListen), .unknown(.couldNotListen)])
        #expect(details(pair, identification: .listening, recent: [pair[1].id]).map(\.attribution) == [.unknown(.listening), .recentInput])
    }

    @Test func recentInputOutranksInference() throws {
        let shown = try #require(details(devices(interface("Solo")), recent: ["046d:c52b"]).first)
        #expect(shown.attribution == .recentInput)
    }

    @Test func leftAloneDevicesAreExplainedAndDontCountAsASecondMouse() throws {
        let trackpad = interface("Apple Internal Keyboard / Trackpad", vendor: 0x05AC, productID: 0x0341, location: 5, transport: "FIFO")
        let touchMouse = interface("Magic Mouse", vendor: 0x05AC, productID: 0x0269, location: 6, transport: "Bluetooth")
        let result = details(devices(interface("Solo", location: 1), trackpad, touchMouse))

        let pad = try #require(result.first { $0.excludedKind == .trackpad })
        let mouse = try #require(result.first { $0.excludedKind == .touchMouse })
        let solo = try #require(result.first { $0.excludedKind == nil })
        #expect(pad.attribution == .leftAlone(.trackpad))
        #expect(pad.notes.contains(.excluded(.trackpad)))
        #expect(mouse.attribution == .leftAlone(.touchMouse))
        #expect(mouse.notes.contains(.excluded(.touchMouse)))
        #expect(!pad.notes.contains(.noSerial))
        #expect(solo.attribution == .inferredFromOnlyMouse)
    }

    @Test func identificationStatusFollowsAccessAndListening() {
        #expect(IdentificationStatus(accessGranted: false, listening: false) == .notAllowed)
        #expect(IdentificationStatus(accessGranted: true, listening: false) == .couldNotListen)
        #expect(IdentificationStatus(accessGranted: true, listening: true) == .listening)
        #expect(IdentificationStatus(accessGranted: false, listening: true) == .listening)
    }

    @Test func everyStateHasItsOwnTextLabel() {
        let bases: [AttributionBasis] = [
            .recentInput, .inferredFromOnlyMouse, .unknown(.listening), .ambiguousIdentity(devices: 2), .leftAlone(.trackpad), .notConnected,
        ]
        let statuses: [IdentificationStatus] = [.listening, .notAllowed, .couldNotListen]
        #expect(Set(bases.map(\.title)).count == bases.count)
        #expect(Set(statuses.map(\.title)).count == statuses.count)
        #expect(Set(bases.map(\.title)).isDisjoint(with: statuses.map(\.title)))
        // Why a mouse is unknown depends on whether Whisker could be listening.
        #expect(Set(statuses.map { AttributionBasis.unknown($0).explanation }).count == statuses.count)
    }

    @Test func aFailedOrDeniedProbeChangesOnlyItsOwnPart() throws {
        let pair = devices(interface("A", productID: 1, location: 1), interface("B", productID: 2, location: 2))
        let controls = Dictionary(uniqueKeysWithValues: pair.map { ($0.id, ControlsReport.reported(ReportedControls(buttons: [0, 1, 2], verticalWheel: true))) })
        let full = details(pair, controls: controls, identification: .listening, recent: [pair[0].id])

        // Enumeration failed: the controls change, nothing else does.
        let noControls = details(pair, controls: [:], identification: .listening, recent: [pair[0].id])
        for (before, after) in zip(full, noControls) {
            #expect(after.controls == .unavailable(.notProvided))
            #expect(before.id == after.id && before.name == after.name && before.serial == after.serial)
            #expect(before.presence == after.presence && before.attribution == after.attribution)
        }

        // Input Monitoring denied: the status changes, and the recorded evidence still counts.
        let denied = details(pair, controls: controls, identification: .notAllowed, recent: [pair[0].id])
        for (before, after) in zip(full, denied) {
            #expect(after.identification == .notAllowed)
            #expect(before.id == after.id && before.controls == after.controls && before.notes == after.notes)
        }
        #expect(denied.map(\.attribution) == [.recentInput, .unknown(.notAllowed)])
    }

    // MARK: Recent evidence

    @Test func inputIsRecentForTheWindowOnly() {
        var evidence = AttributionEvidence()
        evidence.record(deviceID: "a", at: 100)
        #expect(evidence.isRecent("a", at: 100))
        #expect(evidence.isRecent("a", at: 100 + AttributionEvidence.window - 0.5))
        #expect(!evidence.isRecent("a", at: 100 + AttributionEvidence.window))
        #expect(!evidence.isRecent("b", at: 100))
        #expect(evidence.recent(at: 101) == ["a"])
        #expect(evidence.recent(at: 101 + AttributionEvidence.window).isEmpty)
        #expect(evidence.nextExpiry(at: 101) == 100 + AttributionEvidence.window)
        #expect(evidence.nextExpiry(at: 100 + AttributionEvidence.window) == nil)
    }

    @Test func recordingSaysWhenADeviceBecomesRecent() {
        let window = AttributionEvidence.window
        var evidence = AttributionEvidence()
        let first = evidence.record(deviceID: "a", at: 0)
        let again = evidence.record(deviceID: "a", at: 5)
        let stillInUse = evidence.record(deviceID: "a", at: 5 + window - 1)
        #expect(first)
        #expect(!again)
        #expect(!stillInUse)
        // The last report counts, so a device in use stays recent.
        #expect(evidence.isRecent("a", at: 5 + window - 1 + window - 1))

        let afterAGap = evidence.record(deviceID: "a", at: 1000)
        #expect(afterAGap)
    }

    @Test func aDisconnectedDeviceIsForgottenAndDoesntComeBackRecent() {
        var evidence = AttributionEvidence()
        evidence.record(deviceID: "a", at: 10)
        evidence.record(deviceID: "b", at: 12)

        evidence.prune(keeping: ["a"], at: 15)
        #expect(evidence.recent(at: 15) == ["a"])

        // "b" reconnects: nothing counts until it reports again.
        #expect(!evidence.isRecent("b", at: 16))
        let reported = evidence.record(deviceID: "b", at: 20)
        #expect(reported)

        evidence.prune(keeping: ["a", "b"], at: 10 + AttributionEvidence.window)
        #expect(evidence.recent(at: 10 + AttributionEvidence.window) == ["b"])
        evidence.prune(keeping: ["a", "b"], at: 1000)
        #expect(evidence.isEmpty)
    }

    // MARK: Remembered mice

    @Test func rememberedMiceExplainWhatIsUnavailable() {
        let shown = DeviceDetailsBuilder.remembered(id: "046d:c52b:ABC123", name: "MX Master", identification: .notAllowed)
        #expect(shown.name == "MX Master")
        #expect(shown.presence == .notConnected)
        #expect(shown.attribution == .notConnected)
        #expect(shown.controls == .unavailable(.notConnected))
        #expect(shown.vendorIDText == "046D" && shown.productIDText == "C52B")
        #expect(shown.productNameText == "Unknown while not connected")
        #expect(shown.transportText == "Unknown while not connected")
        #expect(shown.serialText == "Reported, hidden")
        #expect(shown.serialValue == "ABC123")
        #expect(shown.notes.contains(.controlsUnavailable(.notConnected)))
        #expect(!shown.serialText.contains("ABC123") && !shown.identifiersText.contains("ABC123") && !shown.name.contains("ABC123"))
    }

    @Test func rememberedMiceWithBlankNamesOrUnreadableIdentitiesStillShowSomething() {
        let blank = DeviceDetailsBuilder.remembered(id: "046d:c52b", name: "  ", identification: .listening)
        #expect(blank.name == "Mouse 046D:C52B")
        #expect(blank.serial == .notReported)
        #expect(blank.notes.contains(.noSerial))

        let unreadable = DeviceDetailsBuilder.remembered(id: "not-an-identity", name: "Old Mouse", identification: .listening)
        #expect(unreadable.name == "Old Mouse")
        #expect(unreadable.serial == .unknown)
        #expect(unreadable.vendorIDText == "Unknown" && unreadable.identifiersText == "Unknown")
        #expect(unreadable.notes.contains(.unrecognisedIdentity))

        #expect(DeviceDetailsBuilder.remembered(id: "not-an-identity", name: "", identification: .listening).name == "not-an-identity")
    }
}

@Suite struct TouchInputPolicyTests {
    @Test func touchMouseIsLeftAloneByDefault() {
        #expect(TouchInputPolicy.decide(kind: .touchMouse) == .leftAlone(.noOptIn))
        #expect(TouchInputPolicy.decide(kind: nil) == .notExcluded)
    }

    @Test func trackpadIsNeverEligible() {
        for optedIn in [false, true] {
            for attribution in [TouchInputPolicy.Attribution.exact, .inferred, .conflicting, .unavailable] {
                #expect(TouchInputPolicy.decide(kind: .trackpad, optedIn: optedIn, attribution: attribution, capability: .verified) == .leftAlone(.trackpad))
            }
        }
    }

    @Test func inferredOrConflictingAttributionIsNeverEnough() {
        for attribution in [TouchInputPolicy.Attribution.inferred, .conflicting, .unavailable] {
            #expect(TouchInputPolicy.decide(kind: .touchMouse, optedIn: true, attribution: attribution, capability: .verified) == .leftAlone(.attributionNotExact))
        }
    }

    @Test func unverifiedHardwareKeepsExclusionEvenWithOptInAndExactAttribution() {
        #expect(TouchInputPolicy.decide(kind: .touchMouse, optedIn: true, attribution: .exact) == .leftAlone(.capabilityUnverified))
        #expect(TouchInputPolicy.decide(kind: .touchMouse, optedIn: true, attribution: .exact, capability: .verified) == .buttonsEligible)
    }

    @Test func scrollFromExcludedDevicesAlwaysPassesThrough() {
        #expect(TouchInputPolicy.scrollIsPassedThrough(from: .touchMouse))
        #expect(TouchInputPolicy.scrollIsPassedThrough(from: .trackpad))
        #expect(!TouchInputPolicy.scrollIsPassedThrough(from: nil))
    }
}
