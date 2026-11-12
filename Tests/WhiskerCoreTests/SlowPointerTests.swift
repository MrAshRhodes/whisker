import Foundation
import Testing
@testable import WhiskerCore

@Suite("Slow pointer holds")
struct SlowPointerTests {
    static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)
    static let other = DeviceAttribution(id: "1532:0043", exact: true)
    static let available: Set<String> = [mouse.id, other.id]

    func settings(button: Int = 3, modifiers: ModifierSet = []) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [
            Mapping(trigger: .button(button), modifiers: modifiers, action: .slowPointer(factor: 0.5)),
            Mapping(trigger: .button(4), action: .slowPointer(factor: 0.3)),
        ]
        return CompiledSettings(settings)
    }

    @Test func overlappingHoldsUseSlowestFactorAndReleaseIndependently() {
        var processor = EventProcessor()
        let compiled = settings()
        #expect(processor.process(InputEvent(.buttonDown(3), device: Self.mouse), settings: compiled, slowPointerDevices: Self.available) == .swallow)
        let began = processor.slowPointerCommand
        #expect(began.factors == [Self.mouse.id: 0.5])
        _ = processor.process(InputEvent(.buttonDown(4), device: Self.mouse), settings: compiled, slowPointerDevices: Self.available)
        #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.3])
        #expect(processor.slowPointerCommand.sessions == began.sessions)
        #expect(processor.process(InputEvent(.buttonDragged(3), device: Self.mouse), settings: compiled) == .dragAsMove)
        #expect(processor.process(InputEvent(.buttonUp(4), device: Self.mouse), settings: compiled) == .swallow)
        #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.5])
        _ = processor.process(InputEvent(.buttonUp(3), device: Self.mouse), settings: compiled)
        #expect(processor.slowPointerCommand.factors.isEmpty)
        #expect(processor.slowPointerCommand.generation > began.generation)
        _ = processor.process(InputEvent(.buttonDown(3), device: Self.mouse), settings: compiled, slowPointerDevices: Self.available)
        #expect(processor.slowPointerCommand.sessions != began.sessions)
    }

    @Test func sameButtonOnTwoMiceAndDuplicatePressesKeepTheirOwners() {
        var processor = EventProcessor()
        let compiled = settings()
        for mouse in [Self.mouse, Self.other] {
            _ = processor.process(InputEvent(.buttonDown(3), device: mouse), settings: compiled, slowPointerDevices: Self.available)
        }
        let both = processor.slowPointerCommand
        _ = processor.process(InputEvent(.buttonDown(3), device: Self.mouse), settings: compiled, slowPointerDevices: Self.available)
        #expect(processor.slowPointerCommand == both)
        _ = processor.process(InputEvent(.buttonUp(3), device: Self.mouse), settings: compiled)
        #expect(processor.slowPointerCommand.factors == [Self.other.id: 0.5])
        _ = processor.process(InputEvent(.buttonUp(3), device: Self.other), settings: compiled)
        #expect(processor.slowPointerCommand.factors.isEmpty)
    }

    @Test func originalReleaseSurvivesModifiersProfileEditsAndCancellation() {
        var processor = EventProcessor()
        let compiled = settings(modifiers: .shift)
        _ = processor.process(InputEvent(.buttonDown(3), modifiers: .shift, device: Self.mouse), settings: compiled, slowPointerDevices: Self.available)
        processor.cancelSlowPointer()
        let cancelled = processor.slowPointerCommand
        #expect(cancelled.factors.isEmpty)
        // A duplicate down cannot revive a cancelled hold, even if the mapping is gone.
        let changed = CompiledSettings(WhiskerSettings())
        #expect(processor.process(InputEvent(.buttonDown(3), device: Self.mouse), settings: changed, slowPointerDevices: Self.available) == .swallow)
        #expect(processor.slowPointerCommand == cancelled)
        #expect(processor.process(InputEvent(.buttonUp(3), device: Self.mouse), settings: changed) == .swallow)
        #expect(processor.process(InputEvent(.buttonUp(3), device: Self.mouse), settings: changed) == .passThrough)
    }

    @Test func ambiguityUnavailableDevicesAndPrimaryGuardFailOpen() {
        for mouse in [nil, DeviceAttribution(id: Self.mouse.id, exact: false), Self.other] {
            var processor = EventProcessor()
            #expect(processor.process(InputEvent(.buttonDown(3), device: mouse), settings: settings(), slowPointerDevices: [Self.mouse.id]) == .passThrough)
            #expect(processor.slowPointerCommand.factors.isEmpty)
        }
        var processor = EventProcessor()
        #expect(processor.process(InputEvent(.buttonDown(0), device: Self.mouse), settings: settings(button: 0), slowPointerDevices: Self.available) == .passThrough)
        #expect(WhiskerSettings.problem(with: Mapping(trigger: .button(0), action: .slowPointer(factor: 0.5)), allowPrimary: false) != nil)
        #expect(WhiskerSettings.problem(with: Mapping(trigger: .wheel(.up), action: .slowPointer(factor: 0.5)), allowPrimary: false) != nil)
    }

    @Test func delayedReleaseDrainsThePressAndAllowsTheNextHold() {
        for connected in [[Self.mouse.id], [Self.mouse.id, Self.other.id]] {
            var attribution = DeviceAttributor(connected: connected)
            attribution.record(deviceID: Self.mouse.id, kind: .button(3), at: 1)
            var processor = EventProcessor()
            let compiled = settings()
            let press = attribution.attribute(kind: .button(3), at: 1.01)
            #expect(press == Self.mouse)
            _ = processor.process(InputEvent(.buttonDown(3), device: press), settings: compiled, slowPointerDevices: Self.available)
            let release = attribution.attribute(kind: .button(3), at: 2)
            #expect(release?.exact != true)
            #expect(processor.process(InputEvent(.buttonUp(3), device: release), settings: compiled) == .swallow)
            #expect(processor.slowPointerCommand.factors.isEmpty)
            #expect(processor.process(InputEvent(.buttonDown(3), device: Self.mouse), settings: compiled, slowPointerDevices: Self.available) == .swallow)
            #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.5])
            #expect(processor.process(InputEvent(.buttonUp(3), device: release), settings: compiled) == .swallow)
            #expect(processor.process(InputEvent(.buttonUp(3), device: Self.mouse), settings: compiled) == .passThrough)
        }
    }

    @Test func ambiguousOverlappingReleasesRetireOwnersWithoutGuessingAndDrainTheirTails() {
        var processor = EventProcessor()
        let compiled = settings()
        for mouse in [Self.mouse, Self.other] {
            _ = processor.process(InputEvent(.buttonDown(3), device: mouse), settings: compiled, slowPointerDevices: Self.available)
        }
        _ = processor.process(InputEvent(.buttonDown(4), device: Self.mouse), settings: compiled, slowPointerDevices: Self.available)
        #expect(processor.process(InputEvent(.buttonUp(3)), settings: compiled) == .swallow)
        #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.3])
        let unrelated = DeviceAttribution(id: "unrelated", exact: true)
        #expect(processor.process(InputEvent(.buttonUp(3), device: unrelated), settings: compiled) == .passThrough)
        // Either owner may have released first. A new press must not be mistaken for a duplicate.
        _ = processor.process(InputEvent(.buttonDown(3), device: Self.other), settings: compiled, slowPointerDevices: Self.available)
        #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.3, Self.other.id: 0.5])
        #expect(processor.process(InputEvent(.buttonUp(3), device: Self.mouse), settings: compiled) == .swallow)
        #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.3, Self.other.id: 0.5])
        #expect(processor.process(InputEvent(.buttonUp(3), device: Self.other), settings: compiled) == .swallow)
        #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.3])
        #expect(processor.process(InputEvent(.buttonUp(3)), settings: compiled) == .passThrough)
    }

    @Test func bypassAndDeviceLossCancelButKeepOriginalRelease() {
        var processor = EventProcessor()
        for mouse in [Self.mouse, Self.other] {
            _ = processor.process(InputEvent(.buttonDown(3), device: mouse), settings: settings(), slowPointerDevices: Self.available)
        }
        processor.cancelSlowPointer(unlessAvailable: [Self.other.id])
        #expect(processor.slowPointerCommand.factors == [Self.other.id: 0.5])
        _ = processor.releaseAllForBypass()
        #expect(processor.slowPointerCommand.factors.isEmpty)
        for mouse in [Self.mouse, Self.other] {
            #expect(processor.process(InputEvent(.buttonUp(3), device: mouse), settings: settings()) == .swallow)
        }
    }

    @Test func slowdownCoexistsWithSwappingAndExplicitPrimaryMappingWins() {
        var saved = WhiskerSettings()
        saved.general.allowPrimaryButtonRemap = true
        saved.devices[Self.mouse.id] = DeviceSettings(swapPrimarySecondary: true)
        saved.profiles[0].mappings = [Mapping(trigger: .button(3), action: .slowPointer(factor: 0.5))]
        var processor = EventProcessor()
        let compiled = CompiledSettings(saved)
        #expect(processor.process(InputEvent(.buttonDown(0), device: Self.mouse), settings: compiled) == .perform(.click(button: 1, modifiers: []), .down))
        #expect(processor.process(InputEvent(.buttonDown(3), device: Self.mouse), settings: compiled, slowPointerDevices: Self.available) == .swallow)
        #expect(processor.process(InputEvent(.buttonUp(0), device: Self.mouse), settings: compiled) == .perform(.click(button: 1, modifiers: []), .up))
        #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.5])
        _ = processor.process(InputEvent(.buttonUp(3), device: Self.mouse), settings: compiled)
        saved.profiles[0].mappings = [Mapping(trigger: .button(0), action: .slowPointer(factor: 0.5))]
        let changed = CompiledSettings(saved)
        #expect(processor.process(InputEvent(.buttonDown(0), device: Self.mouse), settings: changed, slowPointerDevices: Self.available) == .swallow)
        #expect(processor.process(InputEvent(.buttonUp(0), device: Self.mouse), settings: changed) == .swallow)
        #expect(processor.slowPointerCommand.factors.isEmpty)
    }

    @Test func codingRejectsMalformedFactorsAndLeavesOldActionsAlone() throws {
        let decoder = JSONDecoder()
        let encoder = JSONEncoder()
        let action = Action.slowPointer(factor: 0.4)
        #expect(try decoder.decode(Action.self, from: encoder.encode(action)) == action)
        #expect(try decoder.decode(Action.self, from: Data(#"{"kind":"passthrough","future":true}"#.utf8)) == .passthrough)
        for factor in ["0", "1", "-0.5", "10", "\"0.5\"", "null"] {
            #expect(throws: (any Error).self) {
                try decoder.decode(Action.self, from: Data("{\"kind\":\"slowPointer\",\"factor\":\(factor)}".utf8))
            }
        }
        #expect(!SlowPointer.isValid(.nan))
        #expect(!SlowPointer.isValid(.infinity))
        let baseline = PointerSettings(speed: 0.1, acceleration: 0.75, linear: true)
        #expect(SlowPointer.applying(0.1, to: baseline) == baseline)
    }

    @Test func oldSettingsAndUnknownTopLevelKeysSurviveAddingTheAction() throws {
        let old = Data(#"{"schemaVersion":1,"future":{"enabled":true}}"#.utf8)
        var settings = try SettingsCodec.decode(old)
        let oldProfile = settings.defaultProfile
        let mapping = Mapping(trigger: .button(7), action: .slowPointer(factor: 0.5))
        settings.profiles[0].mappings.append(mapping)
        let encoded = try SettingsCodec.encode(settings)
        let loaded = try SettingsCodec.decodeValidated(encoded)
        #expect(loaded.profiles[0].mappings.last == mapping)
        #expect(loaded.profiles[0].mappings.dropLast() == oldProfile.mappings[...])
        let json = try #require(JSONSerialization.jsonObject(with: encoded) as? [String: Any])
        #expect((json["future"] as? [String: Bool]) == ["enabled": true])
        #expect(loaded.schemaVersion == settings.schemaVersion)
    }
}
