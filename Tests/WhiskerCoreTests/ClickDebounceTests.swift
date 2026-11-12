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

    @Test func theIntervalEdgesAreExact() {
        // Binary fractions keep the arithmetic exact: a gap or a hold of exactly the interval is not within it.
        let s = settings(interval: 0.0625)
        func clicked() -> ClickDebouncer {
            var d = ClickDebouncer()
            firstClick(&d, s, press: 1.5, release: 2.0)
            return d
        }
        var gap = clicked()
        #expect(gap.process(down(2.0625, count: 2), settings: s).decision == proceed(2))
        var inside = clicked()
        #expect(inside.process(down(2.0625.nextDown, count: 2), settings: s).decision == .drop)

        let held = down(2.03125, count: 2)
        var hold = clicked()
        #expect(hold.process(held, settings: s).decision == .drop)
        #expect(hold.nextDeadline == 2.09375)
        #expect(hold.process(up(2.09375, count: 2), settings: s) == ClickDebounceOutcome(flushed: [FlushedPress(event: held, clickCount: 2)], decision: proceed(2)))
        var short = clicked()
        _ = short.process(held, settings: s)
        #expect(short.process(up(2.09375.nextDown, count: 2), settings: s).decision == .drop)
        var expiry = clicked()
        _ = expiry.process(held, settings: s)
        #expect(expiry.expire(now: 2.09375.nextDown).isEmpty)
        #expect(expiry.expire(now: 2.09375).map(\.event) == [held])
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

    @Test func aReleaseFromAnotherMouseNeverEndsAHeldPress() {
        // Only the first mouse is filtered, so the other mouse's press goes through without the filter tracking it.
        let s = settings { $0.devices[Self.other.id]?.clickDebounce = nil }
        var d = ClickDebouncer()
        firstClick(&d, s)
        #expect(d.process(down(1.01, device: Self.other), settings: s).decision == proceed())
        let held = down(1.03, count: 2)
        #expect(d.process(held, settings: s).decision == .drop)
        // Its exactly attributed release is not the held press's release, so it passes and the held press is let through first.
        let release = d.process(up(1.035, device: Self.other), settings: s)
        #expect(release.decision == proceed())
        #expect(release.flushed.map(\.event) == [held])
        #expect(d.process(up(1.06, count: 2), settings: s).decision == proceed(2))
    }

    @Test func aDragFromAnotherMouseNeverTurnsIntoTheHeldPressesDrag() {
        let s = settings { $0.devices[Self.other.id]?.clickDebounce = nil }
        var d = ClickDebouncer()
        firstClick(&d, s)
        _ = d.process(down(1.01, device: Self.other), settings: s)
        let held = down(1.03, count: 2)
        _ = d.process(held, settings: s)
        let outcome = d.process(drag(1.035, device: Self.other), settings: s)
        #expect(outcome.decision == proceed())
        #expect(outcome.flushed.map(\.event) == [held])
    }

    @Test func aReleaseThatCouldBelongToEitherMouseIsNeverGuessed() {
        let s = settings()
        var d = ClickDebouncer()
        _ = d.process(down(1.0, device: Self.other), settings: s)
        _ = d.process(up(1.01, device: Self.other), settings: s)
        // One mouse has its press through and the other's repeat is held back; the release can't be told apart.
        #expect(d.process(down(1.02), settings: s).decision == proceed())
        let held = down(1.03, device: Self.other, count: 2)
        #expect(d.process(held, settings: s).decision == .drop)
        let release = d.process(up(1.04, device: nil), settings: s)
        #expect(release.decision == proceed())
        #expect(release.flushed.map(\.event) == [held])
        #expect(!d.hasPending)
        #expect(d.process(up(1.05, device: nil, count: 2), settings: s).decision == proceed(2))
    }

    // MARK: Pairing guarantees

    @Test func everyDeliveredPressGetsItsReleaseAndNoDroppedPressDoes() {
        var d = ClickDebouncer()
        let s = settings()
        var delivered = 0, released = 0
        var t = 1.0
        var rng = SeededGenerator(state: 9)
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

    @Test func interleavedMiceAndButtonsNeverLeaveAPressOrReleaseUnpaired() {
        struct Key: Hashable, Comparable {
            var device: String
            var button: Int
            static func < (a: Key, b: Key) -> Bool { (a.device, a.button) < (b.device, b.button) }
        }
        let s = settings(buttons: [0, 3])
        let mice = [Self.mouse, Self.other]
        var filtered = 0
        for seed in UInt64(1)...25 {
            var rng = SeededGenerator(state: seed)
            var d = ClickDebouncer()
            d.startTest(device: Self.mouse.id, settings: s)
            // Buttons down under the finger, down as the app sees them, and held back by the filter.
            var physical = Set<Key>(), app = Set<Key>(), held = Set<Key>()
            // Presses of the mouse under test since its counts last started at zero, less those discarded.
            var presses: [Int: Int] = [:]
            var t = 1.0

            func deliver(_ flushed: [FlushedPress], by time: TimeInterval) {
                for press in flushed {
                    guard case .buttonDown(let button) = press.event.kind, let id = press.event.device?.id else {
                        Issue.record("seed \(seed): flushed \(press.event.kind)")
                        continue
                    }
                    let key = Key(device: id, button: button)
                    let wasHeld = held.remove(key) != nil
                    let wasUp = app.insert(key).inserted
                    #expect(wasHeld, "seed \(seed): \(key) flushed without being held")
                    #expect(wasUp, "seed \(seed): \(key) pressed twice")
                    #expect(press.event.timestamp <= time && press.clickCount >= 1, "seed \(seed)")
                }
            }

            func handle(_ event: InputEvent) {
                let outcome = d.process(event, settings: s)
                deliver(outcome.flushed, by: event.timestamp)
                guard let id = event.device?.id else { return }
                switch (event.kind, outcome.decision) {
                case (.buttonDown(let button), .proceed(let count)):
                    let wasUp = app.insert(Key(device: id, button: button)).inserted
                    #expect(wasUp, "seed \(seed): pressed twice")
                    #expect(count >= 1)
                case (.buttonDown(let button), .drop):
                    held.insert(Key(device: id, button: button))
                case (.buttonUp(let button), .proceed):
                    let wasDown = app.remove(Key(device: id, button: button)) != nil
                    #expect(wasDown, "seed \(seed): a release without its press")
                case (.buttonUp(let button), .drop):
                    held.remove(Key(device: id, button: button))
                    #expect(!app.contains(Key(device: id, button: button)), "seed \(seed): a delivered press lost its release")
                case (.buttonDragged(let button), .proceed):
                    #expect(app.contains(Key(device: id, button: button)), "seed \(seed): a drag without its press")
                case (.buttonDragged(let button), .moveOnly):
                    #expect(!app.contains(Key(device: id, button: button)), "seed \(seed)")
                case (.scroll, .proceed):
                    break
                default:
                    Issue.record("seed \(seed): \(event.kind) became \(outcome.decision)")
                }
            }

            for _ in 0..<400 {
                t += Double.random(in: 0.001...0.08, using: &rng)
                let roll = Double.random(in: 0..<1, using: &rng)
                if roll < 0.7 {
                    let mouse = mice.randomElement(using: &rng)!
                    let button = [0, 3, 4].randomElement(using: &rng)!
                    let key = Key(device: mouse.id, button: button)
                    if !physical.contains(key) {
                        physical.insert(key)
                        if mouse == Self.mouse { presses[button, default: 0] += 1 }
                        handle(down(t, button, device: mouse, count: Int64.random(in: 1...3, using: &rng)))
                    } else if Bool.random(using: &rng) {
                        handle(drag(t, button, device: mouse))
                    } else {
                        physical.remove(key)
                        handle(up(t, button, device: mouse))
                    }
                } else if roll < 0.8 {
                    handle(InputEvent(.scroll(ScrollSample(vertical: .lines(1))), timestamp: t, device: mice.randomElement(using: &rng)!))
                } else if roll < 0.95 {
                    deliver(d.expire(now: t), by: t)
                } else if roll < 0.98 {
                    d.settingsChanged(from: s, to: s)
                    for key in held where key.device == Self.mouse.id { presses[key.button, default: 0] -= 1 }
                    held.removeAll()
                } else {
                    d.reset()
                    held.removeAll()
                    presses.removeAll()
                }
                #expect(d.hasPending == !held.isEmpty, "seed \(seed)")
            }
            t += 0.2
            for key in physical.sorted() { handle(up(t, key.button, device: key.device == Self.mouse.id ? Self.mouse : Self.other)) }
            deliver(d.expire(now: t + 1), by: t + 1)
            #expect(app.isEmpty && held.isEmpty && !d.hasPending && d.nextDeadline == nil, "seed \(seed)")
            for button in [0, 3] {
                let counts = d.test?[button] ?? ClickFilterTally.Counts()
                #expect(counts.accepted + counts.filtered == presses[button, default: 0], "seed \(seed), button \(button)")
                filtered += counts.filtered
            }
            #expect(d.test?[4] == nil)
        }
        // The runs did make the filter drop pairs.
        #expect(filtered > 0)
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

    @Test func aDiscardedPressStillPutsTheCountOfTheNextOneRight() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        _ = d.process(down(1.03, count: 2), settings: s)
        d.reset()
        #expect(d.process(up(1.04, count: 2), settings: s).decision == .drop)
        // The system counted the discarded press; the app saw one click before this one.
        #expect(d.process(down(1.3, count: 3), settings: s).decision == proceed(2))
        #expect(d.process(up(1.31, count: 3), settings: s).decision == proceed(2))
    }

    @Test func whileEventsPassThroughOnlyTheReleaseOfADiscardedPressIsDropped() {
        var d = ClickDebouncer()
        let s = settings()
        firstClick(&d, s)
        _ = d.process(down(1.03, count: 2), settings: s)
        d.reset()
        #expect(d.dropsOrphanedRelease(up(1.04, 3)) == false)
        #expect(d.dropsOrphanedRelease(up(1.04, device: Self.other)) == false)
        #expect(d.dropsOrphanedRelease(down(1.04)) == false)
        #expect(d.dropsOrphanedRelease(up(1.04, count: 2)) == true)
        #expect(d.dropsOrphanedRelease(up(1.05, count: 2)) == false)

        var delivered = ClickDebouncer()
        _ = delivered.process(down(2), settings: s)
        #expect(delivered.dropsOrphanedRelease(up(2.1)) == false)
        #expect(delivered.process(up(2.1), settings: s).decision == proceed())
    }

    // MARK: Counts

    @Test func aPressTheFilterDoesNotApplyToStillHasItsCountPutRight() {
        // With the primary button protected, only a press with a modifier is filtered.
        let s = settings(allowPrimary: false)
        var d = ClickDebouncer()
        #expect(d.process(down(1.0, modifiers: .command), settings: s).decision == proceed())
        _ = d.process(up(1.01), settings: s)
        #expect(d.process(down(1.03, count: 2, modifiers: .command), settings: s).decision == .drop)
        #expect(d.process(up(1.04, count: 2), settings: s).decision == .drop)
        // The modifier is let go, so the next press isn't filtered, but the app has only seen one click of the run.
        #expect(d.process(down(1.3, count: 3), settings: s).decision == proceed(2))
        #expect(d.process(drag(1.31), settings: s).decision == proceed(2))
        #expect(d.process(up(1.32, count: 3), settings: s).decision == proceed(2))
        #expect(d.process(down(1.5, count: 4), settings: s).decision == proceed(3))
        _ = d.process(up(1.51, count: 4), settings: s)
        // A new run of clicks starts again at one, and nothing is put right after that.
        #expect(d.process(down(3, count: 1), settings: s).decision == proceed(1))
        _ = d.process(up(3.01), settings: s)
        #expect(d.process(down(3.3, count: 2), settings: s).decision == proceed(2))
    }

    @Test func switchingTheFilterOffAfterADropStillPutsTheCountRight() {
        let s = settings()
        let off = settings { $0.devices[Self.mouse.id]?.clickDebounce = nil }
        var d = ClickDebouncer()
        firstClick(&d, s)
        _ = d.process(down(1.04, count: 2), settings: s)
        _ = d.process(up(1.05, count: 2), settings: s)
        d.settingsChanged(from: s, to: off)
        #expect(d.process(down(1.3, count: 3), settings: off).decision == proceed(2))
        #expect(d.process(up(1.31, count: 3), settings: off).decision == proceed(2))
    }

    // MARK: Local test

    @Test func theLocalTestCountsWhatHappenedToEachFilteredButtonOfItsMouse() {
        let s = settings(buttons: [0, 3])
        var d = ClickDebouncer()
        d.startTest(device: Self.mouse.id, settings: s)
        #expect(d.test == ClickFilterTally(device: Self.mouse.id, buttons: [0, 3]))
        #expect(d.test?.isEmpty == true)
        firstClick(&d, s)
        _ = d.process(down(1.03, count: 2), settings: s)
        _ = d.process(up(1.04, count: 2), settings: s)
        // Held back, then let through.
        _ = d.process(down(1.05, count: 3), settings: s)
        #expect(d.expire(now: 1.2).count == 1)
        _ = d.process(up(1.25, count: 3), settings: s)
        // Other buttons, other mice and sources not known exactly are not counted.
        let inexact = DeviceAttribution(id: Self.mouse.id, exact: false)
        for event in [down(2, 4), up(2.01, 4), down(2.1, device: Self.other), up(2.11, device: Self.other), down(2.2, device: inexact), up(2.21, device: nil)] {
            _ = d.process(event, settings: s)
        }
        #expect(d.test?[0] == ClickFilterTally.Counts(accepted: 2, filtered: 1))
        #expect(d.test?[3] == ClickFilterTally.Counts())
        #expect(d.test?[4] == nil)
        #expect(d.test?.isEmpty == false)
    }

    @Test func theLocalTestNeedsTheFilterOnAndStartsAgainFromZero() {
        let s = settings(buttons: [3])
        var d = ClickDebouncer()
        d.startTest(device: "05ac:0304", settings: s)
        #expect(d.test == nil)
        d.startTest(device: Self.mouse.id, settings: s)
        firstClick(&d, s, button: 3)
        #expect(d.test?[3]?.accepted == 1)
        d.clearTest()
        #expect(d.test == ClickFilterTally(device: Self.mouse.id, buttons: [3]))
        firstClick(&d, s, press: 2, release: 2.01, button: 3)
        d.reset()
        #expect(d.test == ClickFilterTally(device: Self.mouse.id, buttons: [3]))
        d.stopTest()
        #expect(d.test == nil)
    }

    @Test func onlySettingsThatDecideTheFilterRestartTheLocalTest() {
        let s = settings(buttons: [3])
        func running() -> ClickDebouncer {
            var d = ClickDebouncer()
            d.startTest(device: Self.mouse.id, settings: s)
            firstClick(&d, s, button: 3)
            return d
        }
        let unrelated = [
            settings(buttons: [3]) { $0.devices[Self.other.id]?.clickDebounce = nil },
            settings(buttons: [3]) { $0.devices[Self.mouse.id]?.wheel.invertVertical = true },
            settings(buttons: [3]) { $0.profiles[0].mappings = [] },
        ]
        for new in unrelated {
            var d = running()
            d.settingsChanged(from: s, to: new)
            #expect(d.test?[3] == ClickFilterTally.Counts(accepted: 1))
        }
        let relevant = [
            settings(buttons: [3], interval: 0.08),
            settings(buttons: [0, 3]),
            settings(buttons: [3], allowPrimary: false),
            settings(buttons: [3]) { $0.general.bypassApps = ["com.example.game"] },
            settings(buttons: [3]) { $0.devices[Self.mouse.id]?.enabled = false },
        ]
        for new in relevant {
            var d = running()
            d.settingsChanged(from: s, to: new)
            #expect(d.test?.isEmpty == true)
            #expect(d.test?.buttons.keys.sorted() == new.settings.devices[Self.mouse.id]?.clickDebounce?.buttons)
        }
        for new in [settings(buttons: []), settings { $0.devices[Self.mouse.id]?.clickDebounce = nil }] {
            var d = running()
            d.settingsChanged(from: s, to: new)
            #expect(d.test == nil)
        }
    }

    @Test func losingTheMouseEndsItsLocalTest() {
        var d = ClickDebouncer()
        d.startTest(device: Self.mouse.id, settings: settings())
        d.devicesChanged(connected: [Self.mouse.id, Self.other.id])
        #expect(d.test != nil)
        d.devicesChanged(connected: [Self.other.id])
        #expect(d.test == nil)
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

/// SplitMix64: random enough to mix events up, and the same every run, so a failing seed can be replayed.
private struct SeededGenerator: RandomNumberGenerator {
    var state: UInt64

    mutating func next() -> UInt64 {
        state &+= 0x9E37_79B9_7F4A_7C15
        var z = state
        z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
        z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
        return z ^ (z >> 31)
    }
}
