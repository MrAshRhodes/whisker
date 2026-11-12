import Foundation
import Testing
@testable import WhiskerCore

@Suite("Click debounce")
struct ClickDebounceTests {
    private static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)
    private static let other = DeviceAttribution(id: "1234:5678", exact: true)
    private let interval = 0.05

    private func settings(buttons: [Int] = [0, 3], interval: Double = 0.05, allowPrimary: Bool = true, configure: (inout WhiskerSettings) -> Void = { _ in }) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.general.allowPrimaryButtonRemap = allowPrimary
        settings.devices[Self.mouse.id] = DeviceSettings(clickDebounce: ClickDebounceSettings(buttons: buttons, interval: interval))
        settings.devices[Self.other.id] = DeviceSettings(clickDebounce: ClickDebounceSettings(buttons: buttons, interval: interval))
        configure(&settings)
        return CompiledSettings(settings)
    }

    private func down(_ t: TimeInterval, _ button: Int = 0, device: DeviceAttribution? = mouse, count: Int64 = 1, modifiers: ModifierSet = []) -> InputEvent {
        InputEvent(.buttonDown(button), modifiers: modifiers, timestamp: t, device: device, clickCount: count)
    }

    private func up(_ t: TimeInterval, _ button: Int = 0, device: DeviceAttribution? = mouse, count: Int64 = 1) -> InputEvent {
        InputEvent(.buttonUp(button), timestamp: t, device: device, clickCount: count)
    }

    private func drag(_ t: TimeInterval, _ button: Int = 0, device: DeviceAttribution? = mouse) -> InputEvent {
        InputEvent(.buttonDragged(button), timestamp: t, device: device)
    }

    private func proceed(_ count: Int64 = 1) -> ClickDebounceDecision { .proceed(clickCount: count) }

    /// A click that was let through, so the filter has seen a release to measure the next press from.
    private func firstClick(_ d: inout ClickDebouncer, _ s: CompiledSettings, press: TimeInterval = 1.0, release: TimeInterval = 1.02, button: Int = 0) {
        #expect(d.process(down(press, button), settings: s).decision == proceed())
        #expect(d.process(up(release, button), settings: s).decision == proceed())
    }

    // MARK: Transparency

    @Test func absentOrEmptySettingsLeaveEverythingAlone() {
        for config in [nil, ClickDebounceSettings(buttons: [])] {
            var d = ClickDebouncer()
            let s = settings { $0.devices[Self.mouse.id] = DeviceSettings(clickDebounce: config) }
            for (t, event) in [(1.0, down(1.0)), (1.01, up(1.01)), (1.02, down(1.02, count: 2)), (1.03, up(1.03, count: 2))] {
                _ = t
                let outcome = d.process(event, settings: s)
                #expect(outcome.flushed.isEmpty)
                if case .proceed = outcome.decision {} else { Issue.record("dropped \(event)") }
            }
            #expect(!d.hasPending)
        }
    }

    @Test func primaryButtonWithoutModifiersIsExemptUnlessRemappingIsAllowed() {
        var d = ClickDebouncer()
        let guarded = settings(allowPrimary: false)
        firstClick(&d, guarded)
        #expect(d.process(down(1.03), settings: guarded).decision == proceed())
        #expect(!d.hasPending)

        // With a modifier held it is not the bare primary button, so the filter applies.
        var modified = ClickDebouncer()
        #expect(modified.process(down(1, modifiers: .command), settings: guarded).decision == proceed())
        _ = modified.process(up(1.01), settings: guarded)
        #expect(modified.process(down(1.03, modifiers: .command), settings: guarded).decision == .drop)
    }

    @Test func inexactUnknownDisabledAndBypassedSourcesAreNotFiltered() {
        let s = settings()
        for device in [DeviceAttribution(id: Self.mouse.id, exact: false), nil] {
            var d = ClickDebouncer()
            _ = d.process(down(1, device: device), settings: s)
            _ = d.process(up(1.01, device: device), settings: s)
            #expect(d.process(down(1.03, device: device), settings: s).decision == proceed())
        }
        let off = settings { $0.devices[Self.mouse.id]?.enabled = false }
        let bypass = settings { $0.general.bypassApps = ["com.example.game"] }
        for (s, app) in [(off, nil), (bypass, "com.example.game"), (settings { $0.general.enabled = false }, nil)] as [(CompiledSettings, String?)] {
            var d = ClickDebouncer()
            _ = d.process(InputEvent(.buttonDown(0), timestamp: 1, device: Self.mouse, app: app), settings: s)
            _ = d.process(InputEvent(.buttonUp(0), timestamp: 1.01, device: Self.mouse, app: app), settings: s)
            #expect(d.process(InputEvent(.buttonDown(0), timestamp: 1.03, device: Self.mouse, app: app), settings: s).decision == proceed())
        }
    }

    @Test func buttonsNotListedAreNotFiltered() {
        var d = ClickDebouncer()
        let s = settings(buttons: [3])
        firstClick(&d, s, button: 4)
        #expect(d.process(down(1.03, 4), settings: s).decision == proceed())
    }

    @Test func theFirstClickIsNeverDelayed() {
        var d = ClickDebouncer()
        let s = settings()
        #expect(d.process(down(5), settings: s) == ClickDebounceOutcome(flushed: [], decision: proceed()))
        #expect(!d.hasPending)
    }

    // MARK: Pairs

    @Test func aShortRepeatPairIsDroppedPressAndRelease() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        #expect(d.process(down(1.04, count: 2), settings: s).decision == .drop)
        #expect(d.hasPending)
        #expect(d.process(up(1.06, count: 2), settings: s) == ClickDebounceOutcome(flushed: [], decision: .drop))
        #expect(!d.hasPending)
    }

    @Test func aNormalDoubleClickGoesThroughWithItsCount() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        // 0.2 s after the release: well outside the interval.
        #expect(d.process(down(1.22, count: 2), settings: s).decision == proceed(2))
        #expect(d.process(up(1.24, count: 2), settings: s).decision == proceed(2))
    }

    @Test func theIntervalBoundaryLetsThePressThrough() {
        var d = ClickDebouncer()
        let s = settings(interval: 0.05)
        firstClick(&d, s, press: 1.0, release: 1.25)
        #expect(d.process(down(1.30, count: 2), settings: s).decision == proceed(2))
        _ = d.process(up(1.31, count: 2), settings: s)
        // Just inside the interval is held.
        #expect(d.process(down(1.359, count: 3), settings: s).decision == .drop)
    }

    @Test func aReleaseExactlyAtTheIntervalFlushesInsteadOfDropping() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s, press: 1.0, release: 1.2)
        _ = d.process(down(1.22, count: 2), settings: s)
        let outcome = d.process(up(1.27, count: 2), settings: s)
        #expect(outcome.flushed.map(\.clickCount) == [2])
        #expect(outcome.decision == proceed(2))
    }

    @Test func aCountAfterADroppedPairIsPutRight() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        _ = d.process(down(1.04, count: 2), settings: s)
        _ = d.process(up(1.05, count: 2), settings: s)
        // The system saw a double click and now counts the next press as the third; the app saw only one.
        #expect(d.process(down(1.3, count: 3), settings: s).decision == proceed(2))
        #expect(d.process(up(1.31, count: 3), settings: s).decision == proceed(2))
        // A new run of clicks starts again at one.
        #expect(d.process(down(3, count: 1), settings: s).decision == proceed(1))
    }

    @Test func aBurstOfChatterIsMeasuredFromTheLastDeliveredRelease() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        for (i, t) in [1.03, 1.06, 1.09].enumerated() {
            let count = Int64(i + 2)
            let decision = d.process(down(t, count: count), settings: s).decision
            // The third bounce is more than an interval after the delivered release, so it gets through.
            if t < 1.02 + interval { #expect(decision == .drop) }
            if decision == .drop { _ = d.process(up(t + 0.005, count: count), settings: s) }
        }
    }

    // MARK: Flushing

    @Test func aDragFlushesTheHeldPressFirstAndKeepsOrder() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        let held = down(1.04, count: 2)
        #expect(d.process(held, settings: s).decision == .drop)
        let outcome = d.process(drag(1.05), settings: s)
        #expect(outcome.flushed == [FlushedPress(event: held, clickCount: 2)])
        #expect(outcome.decision == proceed(2))
        // The release of the delivered press is delivered.
        #expect(d.process(up(1.5, count: 2), settings: s).decision == proceed(2))
    }

    @Test func expiryFlushesAHeldPressOnce() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        let held = down(1.03, count: 2)
        _ = d.process(held, settings: s)
        #expect(d.nextDeadline == 1.03 + interval)
        #expect(d.expire(now: 1.07).isEmpty)
        #expect(d.expire(now: 1.082).map(\.event) == [held])
        #expect(d.expire(now: 2).isEmpty)
        #expect(d.nextDeadline == nil)
        #expect(d.process(up(2.1, count: 2), settings: s).decision == proceed(2))
    }

    @Test func unrelatedInputFlushesTheHeldPress() {
        let s = settings(buttons: [0, 3])
        let unrelated: [InputEvent] = [
            down(1.04, 4), up(1.04, 4), up(1.04, 3), down(1.04, 3, device: Self.other),
            InputEvent(.scroll(ScrollSample(vertical: .lines(1))), timestamp: 1.04, device: Self.mouse),
        ]
        for event in unrelated {
            var d = ClickDebouncer()
            firstClick(&d, s)
            let held = down(1.03, count: 2)
            _ = d.process(held, settings: s)
            let outcome = d.process(event, settings: s)
            #expect(outcome.flushed.map(\.event) == [held], "\(event.kind)")
        }
    }

    @Test func aWheelEventIsNeverDroppedOrDelayed() {
        var d = ClickDebouncer()
        let s = settings()
        let wheel = InputEvent(.scroll(ScrollSample(vertical: .lines(1))), timestamp: 1, device: Self.mouse)
        #expect(d.process(wheel, settings: s) == ClickDebounceOutcome(flushed: [], decision: proceed()))
    }

    // MARK: Devices and buttons

    @Test func devicesAndButtonsAreFilteredIndependently() {
        var d = ClickDebouncer()
        let s = settings(buttons: [0, 3])
        firstClick(&d, s)
        // Another mouse's press right after this mouse's release is its own first click.
        #expect(d.process(down(1.03, device: Self.other), settings: s).decision == proceed())
        _ = d.process(up(1.04, device: Self.other), settings: s)
        // Another button of the same mouse likewise.
        #expect(d.process(down(1.05, 3), settings: s).decision == proceed())
    }

    @Test func interleavedUpsFindTheirOwnPress() {
        var d = ClickDebouncer()
        let s = settings(buttons: [0, 3])
        firstClick(&d, s)
        firstClick(&d, s, button: 3)
        #expect(d.process(down(1.03, count: 2), settings: s).decision == .drop)
        #expect(d.process(down(1.031, 3, count: 2), settings: s).flushed.map(\.event.kind) == [.buttonDown(0)])
        // Button 3's press is held too, so the release of button 0 is unrelated input for it and lets it through.
        let release = d.process(up(1.04, count: 2), settings: s)
        #expect(release.decision == proceed(2))
        #expect(release.flushed.map(\.event.kind) == [.buttonDown(3)])
        #expect(d.process(up(1.041, 3, count: 2), settings: s).decision == proceed(2))
    }

    @Test func aReleaseWithoutExactAttributionStillFindsItsPress() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        _ = d.process(down(1.03, count: 2), settings: s)
        #expect(d.process(up(1.04, device: nil, count: 2), settings: s).decision == .drop)
        #expect(!d.hasPending)
    }

    // MARK: Pairing guarantees

    @Test func everyDeliveredPressGetsItsReleaseAndNoDroppedPressDoes() {
        var d = ClickDebouncer()
        let s = settings()
        var delivered = 0, released = 0
        var t = 1.0
        var rng = SystemRandomNumberGenerator()
        for _ in 0..<500 {
            t += Double.random(in: 0.005...0.2, using: &rng)
            let press = d.process(down(t, count: 2), settings: s)
            delivered += press.flushed.count
            if press.decision != .drop { delivered += 1 }
            t += Double.random(in: 0.001...0.08, using: &rng)
            for flushed in d.expire(now: t) { _ = flushed; delivered += 1 }
            let release = d.process(up(t, count: 2), settings: s)
            delivered += release.flushed.count
            if release.decision != .drop { released += 1 }
        }
        #expect(delivered == released)
    }

    // MARK: Resets

    @Test func resetDiscardsAHeldPressAndDropsItsReleaseButNotADeliveredOnes() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        _ = d.process(down(1.03, count: 2), settings: s)
        d.reset()
        #expect(!d.hasPending)
        #expect(d.nextDeadline == nil)
        #expect(d.process(drag(1.04), settings: s).decision == .moveOnly)
        #expect(d.process(up(1.05, count: 2), settings: s).decision == .drop)
        #expect(d.process(up(1.06), settings: s).decision == proceed())

        var delivered = ClickDebouncer()
        _ = delivered.process(down(1), settings: s)
        delivered.reset()
        #expect(delivered.process(up(1.1), settings: s).decision == proceed())
    }

    @Test func resetForgetsTheLastReleaseSoTheNextPressIsFresh() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        d.reset()
        #expect(d.process(down(1.03, count: 2), settings: s).decision == proceed(2))
    }

    @Test func aNewPressClearsAnOrphanWhoseReleaseWasMissed() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        _ = d.process(down(1.03, count: 2), settings: s)
        d.reset()
        #expect(d.process(down(5), settings: s).decision == proceed())
        #expect(d.process(up(5.1), settings: s).decision == proceed())
    }

    @Test func disconnectedMiceAreForgotten() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        _ = d.process(down(1.03, count: 2), settings: s)
        d.devicesChanged(connected: [Self.other.id])
        #expect(!d.hasPending)
        #expect(d.process(up(1.04, count: 2), settings: s).decision == proceed(2))
        firstClick(&d, s, press: 2, release: 2.01)
        d.devicesChanged(connected: [Self.mouse.id])
        #expect(d.process(down(2.03, count: 2), settings: s).decision == .drop)
    }

    // MARK: Invalid timestamps

    @Test func timestampsThatGoBackwardsOrAreNotNumbersAreNeverFiltered() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s, press: 5, release: 5.01)
        #expect(d.process(down(4), settings: s).decision == proceed())
        _ = d.process(up(4.01), settings: s)
        #expect(d.process(down(.nan), settings: s).decision == proceed())
        _ = d.process(up(.nan), settings: s)
        #expect(d.process(down(.infinity), settings: s).decision == proceed())

        var held = ClickDebouncer()
        firstClick(&held, s)
        _ = held.process(down(1.03, count: 2), settings: s)
        #expect(held.process(up(1.0), settings: s).flushed.count == 1)
        var expired = ClickDebouncer()
        firstClick(&expired, s)
        _ = expired.process(down(1.03, count: 2), settings: s)
        #expect(expired.expire(now: 0).count == 1)
    }

    // MARK: Settings

    @Test func settingsRoundTripAndOlderFilesDecodeWithoutThem() throws {
        var settings = WhiskerSettings()
        settings.devices["046d:c52b"] = DeviceSettings(name: "Mouse", clickDebounce: ClickDebounceSettings(buttons: [0, 3], interval: 0.04))
        settings.unknownKeys["future"] = .string("kept")
        let reloaded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(reloaded == settings)

        let old = #"{"schemaVersion":1,"devices":{"046d:c52b":{"name":"Mouse","enabled":true}},"future":1}"#
        let decoded = try SettingsCodec.decodeValidated(Data(old.utf8))
        #expect(decoded.devices["046d:c52b"]?.clickDebounce == nil)
        #expect(decoded.unknownKeys["future"] == .number(1))
        let written = String(decoding: try SettingsCodec.encode(DeviceSettings().encodedAlone()), as: UTF8.self)
        #expect(!written.contains("clickDebounce"))
    }

    @Test func limitsAreClampedAndReported() {
        var settings = WhiskerSettings()
        settings.devices["046d:c52b"] = DeviceSettings(clickDebounce: ClickDebounceSettings(buttons: [3, 0, 3, -1, 99], interval: 5))
        settings.devices["1234:5678"] = DeviceSettings(clickDebounce: ClickDebounceSettings(buttons: [0], interval: .nan))
        let result = settings.repairedWithIssues()
        #expect(result.settings.devices["046d:c52b"]?.clickDebounce == ClickDebounceSettings(buttons: [0, 3], interval: 0.10))
        #expect(result.settings.devices["1234:5678"]?.clickDebounce?.interval == ClickDebounceSettings.defaultInterval)
        #expect(result.issues.count == 3)
        #expect(WhiskerSettings().validate().isEmpty)
        var valid = WhiskerSettings()
        valid.devices["046d:c52b"] = DeviceSettings(clickDebounce: ClickDebounceSettings(buttons: [0, 3], interval: 0.05))
        #expect(valid.validate().isEmpty)
    }
}

private extension DeviceSettings {
    func encodedAlone() throws -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.devices["046d:c52b"] = self
        return settings
    }
}
