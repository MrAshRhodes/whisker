import Foundation
import Testing
@testable import WhiskerCore

@Suite("Tilt-wheel controls")
struct TiltControlsTests {
    private func notch(vertical: Int = 0, horizontal: Int = 0) -> ControlObservation {
        .scroll(ScrollSample(vertical: .lines(vertical), horizontal: .lines(horizontal)))
    }

    // MARK: Classification

    @Test func aNumberedButtonStaysAButton() {
        let candidate = TiltClassifier.classify([.buttonDown(5)])
        #expect(candidate == .button(5))
        #expect(candidate.trigger == .button(5))
        #expect(candidate.explanation.contains("press and release"))
    }

    @Test func horizontalNotchesStayWheelTriggersAndExplainTheAmbiguity() {
        let left = TiltClassifier.classify([notch(horizontal: 1)])
        let right = TiltClassifier.classify([notch(horizontal: -1), notch(horizontal: -1)])
        #expect(left.trigger == .wheel(.left))
        #expect(right.trigger == .wheel(.right))
        #expect(left.explanation.contains("any other horizontal scrolling"))
        #expect(left.explanation != TiltClassifier.classify([.buttonDown(4)]).explanation)
    }

    @Test func buttonsAreNeverGuessedFromScrolling() {
        let fractional = ScrollSample(horizontal: ScrollAxis(lines: 0, fixed: 0.4, points: 3))
        let smooth = ScrollSample(horizontal: ScrollAxis(lines: 0, fixed: 2, points: 12), isContinuous: true)
        let coasting = ScrollSample(horizontal: .lines(1), isMomentum: true)
        let mixed = ScrollSample(vertical: .lines(1), horizontal: .lines(1))
        #expect(TiltClassifier.classify([.scroll(fractional)]) == .unusable(.fractionalScrolling))
        #expect(TiltClassifier.classify([.scroll(smooth)]) == .unusable(.continuousScrolling))
        #expect(TiltClassifier.classify([.scroll(coasting)]) == .unusable(.momentumScrolling))
        #expect(TiltClassifier.classify([.scroll(mixed)]) == .unusable(.mixedAxes))
        for sample in [fractional, smooth, coasting, mixed] {
            #expect(TiltClassifier.classify([.scroll(sample)]).trigger == nil)
        }
    }

    @Test func noiseAndDisagreementGiveExplanationsNotMappings() {
        #expect(TiltClassifier.classify([]) == .unusable(.noInput))
        #expect(TiltClassifier.classify([.scroll(ScrollSample())]) == .unusable(.noInput))
        #expect(TiltClassifier.classify([notch(vertical: 1)]) == .unusable(.verticalWheel))
        #expect(TiltClassifier.classify([notch(horizontal: 1), notch(horizontal: -1)]) == .unusable(.conflicting))
        #expect(TiltClassifier.classify([.buttonDown(3), .buttonDown(4)]) == .unusable(.conflicting))
        #expect(TiltClassifier.classify([.buttonDown(3), notch(horizontal: 1)]) == .unusable(.conflicting))
        #expect(TiltClassifier.classify([notch(horizontal: 1), .scroll(ScrollSample(horizontal: .lines(1), isContinuous: true))]) == .unusable(.continuousScrolling))
    }

    @Test func sampleClassificationMatchesTheRuntimeNotionOfANotch() {
        #expect(ScrollSample(horizontal: .lines(2)).classification == .notch(.left))
        #expect(ScrollSample(vertical: .lines(-1)).classification == .notch(.down))
        #expect(ScrollSample(horizontal: .lines(1), isMomentum: true).classification == .momentum)
        #expect(ScrollSample().classification == .noMovement)
    }

    @Test func oneControlCannotBeOfferedUnderTwoNames() {
        let results: [TiltStep: ControlCandidate] = [.tiltLeft: .horizontalScroll(.left), .tiltRight: .horizontalScroll(.left), .wheelPress: .button(2)]
        #expect(TiltReview.duplicateProblem(results, for: .tiltLeft) != nil)
        #expect(TiltReview.duplicateProblem(results, for: .wheelPress) == nil)
    }

    // MARK: Attribution

    private func details(_ ids: [(String, Int)], recent: Set<String> = []) -> [DeviceDetails] {
        let interfaces = ids.map { name, product in
            HIDInterfaceInfo(
                vendorID: 0x046D, productID: product, serial: nil, product: name, transport: "USB",
                locationID: 0x1400_0000 + product, interfaceNumber: 0,
                primaryUsagePage: HIDUsage.genericDesktopPage, primaryUsage: HIDUsage.mouse
            )
        }
        return DeviceDetailsBuilder.details(for: PointingDeviceClassifier.pointingDevices(from: interfaces), identification: .listening, recentInput: recent)
    }

    @Test func onlyRecentInputFromOneMouseAllowsLabels() {
        let two = details([("A", 1), ("B", 2)], recent: ["046d:0001"])
        #expect(TiltDeviceAttribution.resolve(two) == .exact(id: "046d:0001", name: "A"))
        #expect(TiltDeviceAttribution.resolve(two).allowsLabels)

        let both = details([("A", 1), ("B", 2)], recent: ["046d:0001", "046d:0002"])
        #expect(TiltDeviceAttribution.resolve(both).deviceID == nil)
        #expect(!TiltDeviceAttribution.resolve(both).allowsLabels)

        let silent = details([("A", 1), ("B", 2)])
        #expect(!TiltDeviceAttribution.resolve(silent).allowsLabels)
    }

    @Test func aGuessedDeviceIsShownButNeverLabelled() {
        let only = TiltDeviceAttribution.resolve(details([("A", 1)]))
        #expect(only == .inferred(id: "046d:0001", name: "A"))
        #expect(!only.allowsLabels)
        #expect(!TiltDeviceAttribution.resolve([]).allowsLabels)
    }

    // MARK: Labels

    @Test func labelsRoundTripAndOldDevicesDecodeWithoutThem() throws {
        var settings = WhiskerSettings()
        settings.devices["046d:0001"] = DeviceSettings(name: "A", controlLabels: [ControlLabel(trigger: .wheel(.left), name: "Wheel tilt left")])
        settings.unknownKeys["future"] = .string("kept")
        let decoded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(decoded == settings)
        #expect(decoded.devices["046d:0001"]?.controlLabel(for: .wheel(.left)) == "Wheel tilt left")
        #expect(decoded.unknownKeys["future"] == .string("kept"))

        let old = #"{"schemaVersion":2,"devices":{"046d:0001":{"name":"A","enabled":true}},"profiles":[{"id":"default"}]}"#
        let loaded = try SettingsCodec.decodeValidated(Data(old.utf8))
        #expect(loaded.devices["046d:0001"]?.controlLabels == [])
        let reencoded = String(decoding: try SettingsCodec.encode(loaded), as: UTF8.self)
        #expect(!reencoded.contains("controlLabels"))
    }

    @Test func invalidLabelsAreRepaired() {
        var settings = WhiskerSettings()
        settings.devices["046d:0001"] = DeviceSettings(controlLabels: [
            ControlLabel(trigger: .button(99), name: "Out of range"),
            ControlLabel(trigger: .button(5), name: "  Thumb  "),
            ControlLabel(trigger: .button(5), name: "Duplicate"),
            ControlLabel(trigger: .wheel(.right), name: "   "),
        ])
        let repaired = settings.repairedWithIssues()
        #expect(repaired.settings.devices["046d:0001"]?.controlLabels == [ControlLabel(trigger: .button(5), name: "Thumb")])
        #expect(repaired.issues.count == 4)
    }

    @Test func labelsNeverChangeMatchingOrPrimaryButtonValidation() {
        var device = DeviceSettings()
        device.setControlLabel("Tilt", for: .button(0))
        #expect(device.controlLabel(for: .button(0)) == "Tilt")
        let mapping = Mapping(trigger: .button(0), action: .navigate(.back))
        #expect(WhiskerSettings.problem(with: mapping, allowPrimary: false) != nil)
        #expect(Mapping(trigger: .button(0), action: .navigate(.back)).key == MappingKey(.button(0), []))
        device.setControlLabel("", for: .button(0))
        #expect(device.controlLabels.isEmpty)
    }
}
