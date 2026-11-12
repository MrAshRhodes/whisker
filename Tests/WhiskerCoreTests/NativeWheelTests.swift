import Foundation
import Testing
@testable import WhiskerCore

@Suite("Native wheel")
struct NativeWheelTests {
    private static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)
    private static let other = DeviceAttribution(id: "1234:abcd", exact: true)

    private func compiled(nativeActive: Set<String>, scroll: ScrollSettings) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].scroll = scroll
        return CompiledSettings(settings, nativeWheelActive: nativeActive)
    }

    private func notch(_ device: DeviceAttribution?, modifiers: ModifierSet = []) -> InputEvent {
        InputEvent(.scroll(ScrollSample(vertical: .lines(-1))), modifiers: modifiers, timestamp: 0, device: device, app: "com.example.app")
    }

    @Test func settingsRoundTripAndOlderFilesDecodeWithoutNative() throws {
        var settings = WhiskerSettings()
        settings.devices["046d:c52b"] = DeviceSettings(wheel: WheelSettings(invertVertical: true, native: NativeWheelSettings(enabled: true, speed: 0.5, acceleration: 1.25)))
        settings.unknownKeys["future"] = .string("kept")
        let decoded = try SettingsCodec.decode(SettingsCodec.encode(settings))
        #expect(decoded == settings)
        #expect(decoded.validate().isEmpty)

        let old = #"{"schemaVersion":1,"devices":{"046d:c52b":{"wheel":{"invertVertical":true}}},"future":{"x":1}}"#
        let upgraded = try SettingsCodec.decode(Data(old.utf8))
        #expect(upgraded.devices["046d:c52b"]?.wheel == WheelSettings(invertVertical: true))
        let rewritten = String(decoding: try SettingsCodec.encode(upgraded), as: UTF8.self)
        #expect(!rewritten.contains("native"))
        #expect(rewritten.contains("future"))

        // Native settings without "enabled" stay off.
        let sparse = Data(#"{"speed":2}"#.utf8)
        #expect(try JSONDecoder().decode(NativeWheelSettings.self, from: sparse) == NativeWheelSettings(enabled: false, speed: 2))
    }

    @Test func outOfRangeValuesAreRepaired() {
        var settings = WhiskerSettings()
        settings.devices["046d:c52b"] = DeviceSettings(wheel: WheelSettings(native: NativeWheelSettings(enabled: true, speed: 40, acceleration: -2)))
        let repaired = settings.repairedWithIssues()
        #expect(repaired.issues.count == 2)
        #expect(repaired.settings.devices["046d:c52b"]?.wheel.native == NativeWheelSettings(enabled: true, speed: 4, acceleration: 0))
    }

    @Test func onlyEnabledSettingsWithAValueAreRequested() {
        #expect(!NativeWheelSettings(enabled: false, speed: 2).isRequested)
        #expect(!NativeWheelSettings(enabled: true).isRequested)
        var settings = WhiskerSettings()
        settings.devices["a"] = DeviceSettings(wheel: WheelSettings(native: NativeWheelSettings(enabled: true, speed: 2)))
        #expect(settings.activeNativeWheel(for: "a")?.speed == 2)
        settings.devices["a"]?.enabled = false
        #expect(settings.activeNativeWheel(for: "a") == nil)
        settings.devices["a"]?.enabled = true
        settings.general.enabled = false
        #expect(settings.activeNativeWheel(for: "a") == nil)
    }

    @Test func nativeAndSoftwareAreExclusive() {
        let scroll = ScrollSettings(linesPerNotch: 4)
        #expect(ScrollModeResolver.mode(scroll: scroll, nativeActive: false) == .software)
        #expect(ScrollModeResolver.mode(scroll: scroll, nativeActive: true) == .native)
        #expect(ScrollModeResolver.mode(scroll: .system, nativeActive: false) == .system)
    }

    @Test func nativeModeSuspendsSoftwareDistanceOnlyForThatMouse() {
        let scroll = ScrollSettings(linesPerNotch: 4, acceleration: 0.5)
        let settings = compiled(nativeActive: [Self.mouse.id], scroll: scroll)
        let four = EventPlan.scroll(ScrollSample(vertical: .lines(-4)), removing: [])
        var processor = EventProcessor()
        #expect(processor.process(notch(Self.mouse), settings: settings) == .passThrough)
        var fresh = EventProcessor()
        #expect(fresh.process(notch(Self.other), settings: settings) == four)
        // An event that can't be attributed is not assumed to come from the native mouse.
        fresh = EventProcessor()
        #expect(fresh.process(notch(nil), settings: settings) == four)
        // The saved values are untouched, and apply again once native mode ends.
        #expect(settings.settings.defaultProfile.scroll == scroll)
        fresh = EventProcessor()
        #expect(fresh.process(notch(Self.mouse), settings: compiled(nativeActive: [], scroll: scroll)) == four)
    }

    @Test func nativeModeKeepsSidewaysAndHoldScalingSeparate() {
        let scroll = ScrollSettings(linesPerNotch: 4, horizontalModifier: .shift, modifierScaling: ModifierScaling(modifiers: .option, multiplier: 2))
        let settings = compiled(nativeActive: [Self.mouse.id], scroll: scroll)
        var processor = EventProcessor()
        #expect(processor.process(notch(Self.mouse, modifiers: .shift), settings: settings)
            == .scroll(ScrollSample(horizontal: .lines(-1)), removing: .shift))
        guard case let .scroll(sample, removing) = processor.process(notch(Self.mouse, modifiers: .option), settings: settings) else {
            Issue.record("expected scaling"); return
        }
        #expect(sample.vertical.lines == -2)
        #expect(removing == .option)
    }

    @Test func valuesScaleFromTheServicesOwnOriginal() {
        let original = Int64(NativeWheelMath.ioFixed(2))
        #expect(NativeWheelMath.value(for: .speed, setting: 2, original: original) == Int64(NativeWheelMath.ioFixed(1)))
        #expect(NativeWheelMath.value(for: .speed, setting: 2, original: 0) == nil)
        #expect(NativeWheelMath.value(for: .speed, setting: .nan, original: original) == nil)
        #expect(NativeWheelMath.value(for: .acceleration, setting: 99, original: 0) == Int64(NativeWheelMath.ioFixed(3)))
    }
}
