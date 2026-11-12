import Foundation
import Testing
@testable import WhiskerCore

@Suite("Event processor")
struct EventProcessorTests {
    private static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)

    private func compiled(_ mappings: [Mapping] = [], scroll: ScrollSettings? = nil, configure: (inout WhiskerSettings) -> Void = { _ in }) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings += mappings
        settings.profiles[0].scroll = scroll
        configure(&settings)
        return CompiledSettings(settings)
    }

    private func event(_ kind: InputKind, _ modifiers: ModifierSet = [], at time: TimeInterval = 0, device: DeviceAttribution? = mouse, app: String? = "com.example.app") -> InputEvent {
        InputEvent(kind, modifiers: modifiers, timestamp: time, device: device, app: app)
    }

    private func notch(_ lines: Int, horizontal: Bool = false) -> InputKind {
        horizontal ? .scroll(ScrollSample(horizontal: .lines(lines))) : .scroll(ScrollSample(vertical: .lines(lines)))
    }

    // MARK: Buttons

    @Test func defaultSideButtonsNavigateOnceAndSwallowTheirRelease() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(event(.buttonDown(3)), settings: settings) == .perform(.navigate(.back), .once))
        #expect(processor.process(event(.buttonDragged(3)), settings: settings) == .dragAsMove)
        #expect(processor.process(event(.buttonUp(3)), settings: settings) == .swallow)
        #expect(processor.process(event(.buttonDown(1)), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonUp(1)), settings: settings) == .passThrough)
    }

    @Test func clicksFollowTheButtonIncludingDrags() {
        var processor = EventProcessor()
        let settings = compiled([Mapping(trigger: .button(2), action: .click(button: 0, modifiers: .command))])
        let click = Action.click(button: 0, modifiers: .command)
        #expect(processor.process(event(.buttonDown(2)), settings: settings) == .perform(click, .down))
        #expect(processor.process(event(.buttonDragged(2)), settings: settings) == .dragAs(button: 0, modifiers: .command))
        #expect(processor.process(event(.buttonUp(2)), settings: settings) == .perform(click, .up))
    }

    @Test func releaseUsesTheActionThatWasPressedEvenIfSettingsChange() {
        var processor = EventProcessor()
        let repeating = Action.shortcut(KeyShortcut(keyCode: 0x7E), repeatWhileHeld: true)
        #expect(processor.process(event(.buttonDown(4)), settings: compiled([Mapping(trigger: .button(4), action: repeating)])) == .perform(repeating, .down))
        #expect(processor.process(event(.buttonUp(4)), settings: compiled()) == .perform(repeating, .up))
    }

    @Test func exactModifiersWinThenFallBackToTheBareMapping() {
        var processor = EventProcessor()
        let settings = compiled([Mapping(trigger: .button(3), modifiers: .option, action: .space(.left))])
        #expect(processor.process(event(.buttonDown(3), .option), settings: settings) == .perform(.space(.left), .once))
        _ = processor.process(event(.buttonUp(3)), settings: settings)
        #expect(processor.process(event(.buttonDown(3), [.option, .shift]), settings: settings) == .perform(.navigate(.back), .once))
        _ = processor.process(event(.buttonUp(3)), settings: settings)
        #expect(processor.process(event(.buttonDown(3), [.option, .function]), settings: settings) == .perform(.space(.left), .once))
    }

    @Test func primaryButtonStaysSafeUnlessAllowed() {
        var processor = EventProcessor()
        let mapping = Mapping(trigger: .button(0), action: .none)
        #expect(processor.process(event(.buttonDown(0)), settings: compiled([mapping])) == .passThrough)
        let allowed = compiled([mapping]) { $0.general.allowPrimaryButtonRemap = true }
        #expect(processor.process(event(.buttonDown(0)), settings: allowed) == .swallow)
        #expect(processor.process(event(.buttonUp(0)), settings: allowed) == .swallow)
    }

    @Test func disabledAppOrDeviceLetsEverythingThrough() {
        var processor = EventProcessor()
        #expect(processor.process(event(.buttonDown(3)), settings: compiled { $0.general.enabled = false }) == .passThrough)
        let deviceOff = compiled { $0.devices[Self.mouse.id] = DeviceSettings(enabled: false) }
        #expect(processor.process(event(.buttonDown(3)), settings: deviceOff) == .passThrough)
        #expect(processor.process(event(.buttonUp(3)), settings: deviceOff) == .passThrough)
    }

    @Test func releaseAllFinishesHeldClicksOnly() {
        var processor = EventProcessor()
        let settings = compiled([Mapping(trigger: .button(2), action: .click(button: 1, modifiers: []))])
        _ = processor.process(event(.buttonDown(2)), settings: settings)
        _ = processor.process(event(.buttonDown(3)), settings: settings)
        let released = processor.releaseAll()
        #expect(released.map(\.button) == [2])
        #expect(released.map(\.action) == [.click(button: 1, modifiers: [])])
        #expect(processor.heldButtons.isEmpty)
        #expect(processor.process(event(.buttonUp(2)), settings: settings) == .passThrough)
    }

    // MARK: Wheel

    @Test func wheelMappingFiresOncePerBurst() {
        var processor = EventProcessor()
        let settings = compiled([Mapping(trigger: .wheel(.up), modifiers: .control, action: .space(.left))])
        #expect(processor.process(event(notch(1), .control, at: 0), settings: settings) == .perform(.space(.left), .once))
        #expect(processor.process(event(notch(1), .control, at: 0.1), settings: settings) == .swallow)
        #expect(processor.process(event(notch(1), .control, at: 0.2), settings: settings) == .swallow)
        #expect(processor.process(event(notch(1), .control, at: 0.5), settings: settings) == .perform(.space(.left), .once))
        // Wheel mappings need their modifiers exactly.
        #expect(processor.process(event(notch(1), at: 0.9), settings: settings) == .passThrough)
    }

    @Test func repeatPerNotchAndScrollActionsFireEveryNotch() {
        var processor = EventProcessor()
        let settings = compiled([
            Mapping(trigger: .wheel(.down), modifiers: .option, action: .media(.volumeDown), repeatPerNotch: true),
            Mapping(trigger: .wheel(.down), modifiers: .shift, action: .scroll(direction: .right, lines: 2)),
        ])
        for time in [0, 0.05, 0.1] {
            #expect(processor.process(event(notch(-1), .option, at: time), settings: settings) == .perform(.media(.volumeDown), .once))
            #expect(processor.process(event(notch(-1), .shift, at: time), settings: settings) == .perform(.scroll(direction: .right, lines: 2), .once))
        }
    }

    @Test func invertNeedsAKnownDevice() {
        var processor = EventProcessor()
        let settings = compiled { $0.devices[Self.mouse.id] = DeviceSettings(wheel: WheelSettings(invertVertical: true)) }
        let inverted = ScrollSample(vertical: .lines(-1))
        #expect(processor.process(event(notch(1)), settings: settings) == .scroll(inverted, removing: []))
        let smooth = InputKind.scroll(ScrollSample(vertical: ScrollAxis(lines: 0, fixed: 0.2, points: 2), isContinuous: true))
        let guessed = DeviceAttribution(id: Self.mouse.id, exact: false)
        #expect(processor.process(event(smooth, device: guessed), settings: settings) == .passThrough)
        #expect(processor.process(event(notch(1, horizontal: true)), settings: settings) == .passThrough)
        #expect(processor.process(event(notch(1), device: nil), settings: settings) == .passThrough)
    }

    @Test func horizontalModifierTurnsTheWheelSideways() {
        var processor = EventProcessor()
        let settings = compiled(scroll: ScrollSettings(horizontalModifier: .shift))
        #expect(processor.process(event(notch(-1), .shift), settings: settings) == .scroll(ScrollSample(horizontal: .lines(-1)), removing: .shift))
        #expect(processor.process(event(notch(-1)), settings: settings) == .passThrough)
    }

    @Test func linesPerNotchSetsDistanceAndAccelerates() {
        var processor = EventProcessor()
        let settings = compiled(scroll: ScrollSettings(linesPerNotch: 3, acceleration: 0.5))
        #expect(processor.process(event(notch(-1), at: 0), settings: settings) == .scroll(ScrollSample(vertical: .lines(-3)), removing: []))
        var last: EventPlan = .passThrough
        for i in 1...6 { last = processor.process(event(notch(-1), at: Double(i) * 0.02), settings: settings) }
        guard case let .scroll(sample, _) = last else { Issue.record("expected a scroll"); return }
        #expect(sample.vertical.lines < -3)
        #expect(sample.vertical.points == Double(sample.vertical.lines) * ScrollMath.pointsPerLine)
    }

    @Test func continuousScrollingIsLeftAloneByProfiles() {
        var processor = EventProcessor()
        let settings = compiled([Mapping(trigger: .wheel(.up), action: .none)], scroll: ScrollSettings(linesPerNotch: 5, horizontalModifier: .shift))
        let smooth = InputKind.scroll(ScrollSample(vertical: ScrollAxis(lines: 1, fixed: 1, points: 10), isContinuous: true))
        #expect(processor.process(event(smooth, .shift), settings: settings) == .passThrough)
    }

    // MARK: Application bypass

    private static let game = "com.example.game"
    private static let otherMouse = DeviceAttribution(id: "1234:abcd", exact: true)

    private func bypassing(_ apps: [String] = [game], configure: (inout WhiskerSettings) -> Void = { _ in }) -> CompiledSettings {
        compiled { settings in
            configure(&settings)
            settings.general.bypassApps = apps
        }
    }

    @Test func bypassBeatsInheritedAppAndPerDeviceMappings() {
        let gameProfile = Profile(name: "Game", match: ProfileMatch(apps: [Self.game]), mappings: [Mapping(trigger: .button(5), action: .none)])
        let mouseInGame = Profile(name: "Mouse in game", match: ProfileMatch(devices: [Self.mouse.id], apps: [Self.game]), mappings: [Mapping(trigger: .button(6), action: .space(.left))])
        let profiles = { (settings: inout WhiskerSettings) in settings.profiles += [gameProfile, mouseInGame] }
        let scenarios: [(device: DeviceAttribution, button: Int, whenActive: EventPlan)] = [
            (Self.otherMouse, 3, .perform(.navigate(.back), .once)),
            (Self.otherMouse, 5, .swallow),
            (Self.mouse, 6, .perform(.space(.left), .once)),
        ]
        for scenario in scenarios {
            let down = event(.buttonDown(scenario.button), device: scenario.device, app: Self.game)
            var active = EventProcessor()
            #expect(active.process(down, settings: compiled(configure: profiles)) == scenario.whenActive)
            var bypassed = EventProcessor()
            #expect(bypassed.process(down, settings: bypassing(configure: profiles)) == .passThrough)
            #expect(bypassed.process(event(.buttonUp(scenario.button), device: scenario.device, app: Self.game), settings: bypassing(configure: profiles)) == .passThrough)
            #expect(bypassed.heldButtons.isEmpty)
        }
    }

    @Test func bypassLeavesTheWheelToTheSystem() {
        let setup = { (settings: inout WhiskerSettings) in
            settings.devices[Self.mouse.id] = DeviceSettings(wheel: WheelSettings(invertVertical: true))
            settings.profiles[0].scroll = ScrollSettings(
                linesPerNotch: 3, acceleration: 0.5, horizontalModifier: .shift,
                modifierScaling: ModifierScaling(modifiers: .option, multiplier: 3)
            )
            settings.profiles[0].mappings.append(Mapping(trigger: .wheel(.up), modifiers: .control, action: .space(.left)))
        }
        let inputs: [(kind: InputKind, modifiers: ModifierSet)] = [
            (notch(1), []),
            (notch(-1), .shift),
            (notch(1), .control),
            (notch(1), .option),
            (notch(1, horizontal: true), []),
        ]
        for input in inputs {
            let scroll = event(input.kind, input.modifiers, app: Self.game)
            var active = EventProcessor()
            #expect(active.process(scroll, settings: compiled(configure: setup)) != .passThrough)
            var bypassed = EventProcessor()
            #expect(bypassed.process(scroll, settings: bypassing(configure: setup)) == .passThrough)
        }
    }

    @Test func bypassOnlyCoversTheListedApps() {
        var processor = EventProcessor()
        let settings = bypassing()
        #expect(processor.process(event(.buttonDown(3), app: Self.game), settings: settings) == .passThrough)
        _ = processor.process(event(.buttonUp(3), app: Self.game), settings: settings)
        #expect(processor.process(event(.buttonDown(3), app: "com.example.app"), settings: settings) == .perform(.navigate(.back), .once))
        _ = processor.process(event(.buttonUp(3), app: "com.example.app"), settings: settings)
        // Without an app identity nothing matches the list.
        #expect(processor.process(event(.buttonDown(3), app: nil), settings: settings) == .perform(.navigate(.back), .once))
        // A listed app that isn't in front changes nothing.
        let unlisted = compiled()
        #expect(processor.process(event(.buttonDown(3), app: Self.game), settings: unlisted) == .perform(.navigate(.back), .once))
    }

    @Test func bypassNeverTurnsWhiskerOn() {
        let settings = bypassing {
            $0.general.enabled = false
            $0.devices[Self.mouse.id] = DeviceSettings(wheel: WheelSettings(invertVertical: true))
        }
        var processor = EventProcessor()
        for app in [Self.game, "com.example.app"] {
            #expect(processor.process(event(.buttonDown(3), app: app), settings: settings) == .passThrough)
            #expect(processor.process(event(notch(1), app: app), settings: settings) == .passThrough)
        }
    }

    @Test func bypassKeepsThePrimaryButtonSafeguard() {
        var processor = EventProcessor()
        let mapping = Mapping(trigger: .button(0), action: .none)
        let guarded = compiled([mapping]) { $0.general.bypassApps = [Self.game] }
        #expect(processor.process(event(.buttonDown(0)), settings: guarded) == .passThrough)
        #expect(processor.process(event(.buttonDown(0), app: Self.game), settings: guarded) == .passThrough)
        let allowed = compiled([mapping]) { $0.general.allowPrimaryButtonRemap = true; $0.general.bypassApps = [Self.game] }
        #expect(processor.process(event(.buttonDown(0)), settings: allowed) == .swallow)
        _ = processor.process(event(.buttonUp(0)), settings: allowed)
        #expect(processor.process(event(.buttonDown(0), app: Self.game), settings: allowed) == .passThrough)
    }

    @Test func aButtonHeldBeforeBypassStillEndsWithItsOwnRelease() {
        var processor = EventProcessor()
        let click = Action.click(button: 0, modifiers: [])
        let mapping = Mapping(trigger: .button(2), action: click)
        #expect(processor.process(event(.buttonDown(2)), settings: compiled([mapping])) == .perform(click, .down))
        let bypassed = bypassing { $0.profiles[0].mappings.append(mapping) }
        #expect(processor.process(event(.buttonDragged(2), app: Self.game), settings: bypassed) == .dragAs(button: 0, modifiers: []))
        #expect(processor.process(event(.buttonUp(2), app: Self.game), settings: bypassed) == .perform(click, .up))
        #expect(processor.process(event(.buttonUp(2), app: Self.game), settings: bypassed) == .passThrough)
    }

    @Test func standingAsideReleasesHeldActionsOnceAndKeepsTheAppFromSeeingTheRest() {
        var processor = EventProcessor()
        let click = Action.click(button: 1, modifiers: [])
        let settings = compiled([Mapping(trigger: .button(2), action: click)])
        let bypassed = bypassing { $0.profiles[0].mappings.append(Mapping(trigger: .button(2), action: click)) }
        _ = processor.process(event(.buttonDown(2)), settings: settings)
        _ = processor.process(event(.buttonDown(3)), settings: settings)

        let released = processor.releaseAllForBypass()
        #expect(released.map(\.button) == [2])
        #expect(released.map(\.action) == [click])
        #expect(processor.releaseAllForBypass().isEmpty)
        #expect(processor.heldButtons.isEmpty)

        // Still physically down: movement continues, but the app sees no drag, and no release without a press.
        #expect(processor.process(event(.buttonDragged(2), app: Self.game), settings: bypassed) == .dragAsMove)
        #expect(processor.process(event(.buttonDragged(3), app: Self.game), settings: bypassed) == .dragAsMove)
        #expect(processor.process(event(.buttonUp(2), app: Self.game), settings: bypassed) == .swallow)
        #expect(processor.process(event(.buttonUp(3), app: Self.game), settings: bypassed) == .swallow)
        // Each is swallowed once; the next press and release belong to the app.
        #expect(processor.process(event(.buttonDragged(2), app: Self.game), settings: bypassed) == .passThrough)
        #expect(processor.process(event(.buttonUp(2), app: Self.game), settings: bypassed) == .passThrough)
        #expect(processor.process(event(.buttonDown(3), app: Self.game), settings: bypassed) == .passThrough)
        #expect(processor.process(event(.buttonUp(3), app: Self.game), settings: bypassed) == .passThrough)
    }

    @Test func aNewPressEndsTheWaitForAnOrphanedRelease() {
        var processor = EventProcessor()
        _ = processor.process(event(.buttonDown(3)), settings: compiled())
        _ = processor.releaseAllForBypass()
        // The release never arrived (say the tap was off); the next press starts afresh.
        let bypassed = bypassing()
        #expect(processor.process(event(.buttonDown(3), app: Self.game), settings: bypassed) == .passThrough)
        #expect(processor.process(event(.buttonUp(3), app: Self.game), settings: bypassed) == .passThrough)
    }

    // MARK: Scroll speed while holding

    private func scaled(
        _ multiplier: Double,
        holding modifiers: ModifierSet = .option,
        axes: ScalingAxes = .both,
        linesPerNotch: Int? = nil,
        acceleration: Double = 0,
        sideways: ModifierSet = [],
        mappings: [Mapping] = [],
        configure: (inout WhiskerSettings) -> Void = { _ in }
    ) -> CompiledSettings {
        let scaling = ModifierScaling(modifiers: modifiers, multiplier: multiplier, axes: axes)
        let scroll = ScrollSettings(linesPerNotch: linesPerNotch, acceleration: acceleration, horizontalModifier: sideways, modifierScaling: scaling)
        return compiled(mappings, scroll: scroll, configure: configure)
    }

    /// What a plan scrolls up and down by, nil when the plan isn't a scroll.
    private func vertical(_ plan: EventPlan) -> ScrollAxis? {
        if case let .scroll(sample, _) = plan { return sample.vertical }
        return nil
    }

    /// Turns the wheel one notch at each of `times`, returning what each notch scrolled by.
    private func turn(_ processor: inout EventProcessor, _ settings: CompiledSettings, lines: Int = 1, holding modifiers: ModifierSet = .option, at times: [TimeInterval]) -> [ScrollAxis?] {
        times.map { vertical(processor.process(event(notch(lines), modifiers, at: $0), settings: settings)) }
    }

    private func ticks(_ count: Int, from start: TimeInterval = 0) -> [TimeInterval] {
        (0..<count).map { start + Double($0) * 0.1 }
    }

    @Test func heldModifierScalesTheWheelAndRemovesOnlyThatModifier() {
        var processor = EventProcessor()
        let settings = scaled(2)
        #expect(processor.process(event(notch(-1), .option), settings: settings) == .scroll(ScrollSample(vertical: .lines(-2)), removing: .option))
        // The function flag doesn't count towards the combination and is left alone.
        #expect(processor.process(event(notch(3), [.option, .function]), settings: settings) == .scroll(ScrollSample(vertical: .lines(6)), removing: .option))
        #expect(processor.process(event(notch(-1)), settings: settings) == .passThrough)
        #expect(processor.process(event(notch(-1), .shift), settings: settings) == .passThrough)

        let everything: ModifierSet = [.option, .shift, .command, .function]
        #expect(processor.process(event(notch(1), everything), settings: settings) == .scroll(ScrollSample(vertical: .lines(2)), removing: .option))
        let combination = scaled(2, holding: [.option, .shift])
        #expect(processor.process(event(notch(1), everything), settings: combination) == .scroll(ScrollSample(vertical: .lines(2)), removing: [.option, .shift]))
        #expect(processor.process(event(notch(1), .option), settings: combination) == .passThrough)
    }

    @Test func axesChooseWhichDirectionsAreScaled() {
        let diagonal = InputKind.scroll(ScrollSample(vertical: .lines(-1), horizontal: .lines(2)))
        let cases: [(ScalingAxes, ScrollSample)] = [
            (.both, ScrollSample(vertical: .lines(-2), horizontal: .lines(4))),
            (.vertical, ScrollSample(vertical: .lines(-2), horizontal: .lines(2))),
            (.horizontal, ScrollSample(vertical: .lines(-1), horizontal: .lines(4))),
        ]
        for (axes, expected) in cases {
            var processor = EventProcessor()
            #expect(processor.process(event(diagonal, .option), settings: scaled(2, axes: axes)) == .scroll(expected, removing: .option))
        }

        var processor = EventProcessor()
        let triple = scaled(3)
        for count in [1, -1, 2, -2] {
            #expect(processor.process(event(notch(count), .option), settings: triple) == .scroll(ScrollSample(vertical: .lines(count * 3)), removing: .option))
            #expect(processor.process(event(notch(count, horizontal: true), .option), settings: triple) == .scroll(ScrollSample(horizontal: .lines(count * 3)), removing: .option))
        }
        // A notch that only moves the other way isn't touched, so the modifier still reaches the app.
        #expect(processor.process(event(notch(1), .option), settings: scaled(2, axes: .horizontal)) == .passThrough)
        #expect(processor.process(event(notch(1, horizontal: true), .option), settings: scaled(2, axes: .vertical)) == .passThrough)
    }

    @Test func scalingComesAfterDistanceAndAcceleration() {
        var plain = EventProcessor()
        var slowed = EventProcessor()
        let settings = scaled(0.5, linesPerNotch: 4, acceleration: 1)
        var farthest = 0
        for i in 0..<8 {
            let time = Double(i) * 0.03
            guard case let .scroll(expected, _) = plain.process(event(notch(-1), at: time), settings: settings),
                  case let .scroll(actual, removing) = slowed.process(event(notch(-1), .option, at: time), settings: settings)
            else { Issue.record("expected both to scroll"); return }
            #expect(actual.vertical.fixed == expected.vertical.fixed * 0.5)
            #expect(removing == .option)
            farthest = min(farthest, expected.vertical.lines)
        }
        #expect(farthest < -4)
    }

    @Test func partsOfALineCarryOverToTheNextNotch() {
        var rising = EventProcessor()
        let up = turn(&rising, scaled(0.25), at: ticks(4)).compactMap { $0 }
        #expect(up.map(\.lines) == [0, 0, 0, 1])
        #expect(up.map(\.points) == [2, 3, 2, 3])
        #expect(up.map(\.fixed) == [0.25, 0.25, 0.25, 0.25])

        var falling = EventProcessor()
        let down = turn(&falling, scaled(0.5), lines: -1, at: ticks(4)).compactMap { $0 }
        #expect(down.map(\.lines) == [0, -1, 0, -1])
        #expect(down.map(\.points) == [-5, -5, -5, -5])

        // Over many notches the whole units add up to what the multiplier asks for. 0.3 × 40 is exactly 12 lines,
        // which repeated addition only reaches once its rounding error is dealt with.
        let totals: [(multiplier: Double, notches: Int, lines: Int, points: Double)] = [
            (0.25, 37, 9, 92), (0.3, 40, 12, 120), (0.75, 37, 27, 277), (1.5, 37, 55, 555), (2.5, 37, 92, 925), (8, 37, 296, 2960),
        ]
        for total in totals {
            var processor = EventProcessor()
            let axes = turn(&processor, scaled(total.multiplier), lines: -1, at: ticks(total.notches)).compactMap { $0 }
            #expect(axes.count == total.notches)
            #expect(axes.reduce(0) { $0 + $1.lines } == -total.lines)
            #expect(axes.reduce(0) { $0 + $1.points } == -total.points)
        }
    }

    @Test func leftoverIsDroppedWhenTheWheelReversesRestsOrTheModifierIsLetGo() {
        let settings = scaled(0.25)

        var reversing = EventProcessor()
        _ = turn(&reversing, settings, at: ticks(3))
        // Three quarters of a line up must not count towards going down.
        #expect(turn(&reversing, settings, lines: -1, at: ticks(4, from: 0.3)).map { $0?.lines } == [0, 0, 0, -1])

        var released = EventProcessor()
        _ = turn(&released, settings, at: ticks(3))
        #expect(released.process(event(notch(1), at: 0.3), settings: settings) == .passThrough)
        #expect(turn(&released, settings, at: [0.4]).map { $0?.lines } == [0])

        for (rest, expected) in [(0.5, 1), (ScrollMath.remainderMemory + 0.5, 0)] {
            var resting = EventProcessor()
            _ = turn(&resting, settings, at: ticks(3))
            #expect(turn(&resting, settings, at: [0.2 + rest]).map { $0?.lines } == [expected])
        }
    }

    @Test func leftoverStaysWithOneDeviceAndProfileAndIsClearedByReleaseAll() {
        let settings = scaled(0.25) { $0.profiles.append(Profile(id: "other", name: "Other", match: ProfileMatch(apps: ["com.example.other"]))) }
        let otherMouse = DeviceAttribution(id: "046d:b034", exact: true)

        var devices = EventProcessor()
        _ = turn(&devices, settings, at: ticks(3))
        #expect(vertical(devices.process(event(notch(1), .option, at: 0.3, device: otherMouse), settings: settings))?.lines == 0)
        #expect(vertical(devices.process(event(notch(1), .option, at: 0.4, device: nil), settings: settings))?.lines == 0)
        #expect(vertical(devices.process(event(notch(1), .option, at: 0.5), settings: settings))?.lines == 1)

        // Another profile has the same scaling by inheritance, but it's a different place to be scrolling.
        var profiles = EventProcessor()
        _ = turn(&profiles, settings, at: ticks(3))
        let inOtherApp = InputEvent(notch(1), modifiers: .option, timestamp: 0.3, device: Self.mouse, app: "com.example.other")
        #expect(vertical(profiles.process(inOtherApp, settings: settings))?.lines == 0)

        var reset = EventProcessor()
        _ = turn(&reset, settings, at: ticks(3))
        _ = reset.releaseAll()
        #expect(turn(&reset, settings, at: [0.3]).map { $0?.lines } == [0])
    }

    @Test func wheelMappingsWinAndButtonsAreUntouched() {
        var processor = EventProcessor()
        let settings = scaled(2, mappings: [Mapping(trigger: .wheel(.up), modifiers: .option, action: .space(.left))])
        #expect(processor.process(event(notch(1), .option), settings: settings) == .perform(.space(.left), .once))
        #expect(processor.process(event(notch(-1), .option), settings: settings) == .scroll(ScrollSample(vertical: .lines(-2)), removing: .option))
        // Wheel mappings need their modifiers exactly, so with another one held too the wheel is scaled.
        #expect(processor.process(event(notch(1), [.option, .shift]), settings: settings) == .scroll(ScrollSample(vertical: .lines(2)), removing: .option))

        #expect(processor.process(event(.buttonDown(3), .option), settings: settings) == .perform(.navigate(.back), .once))
        #expect(processor.process(event(.buttonUp(3), .option), settings: settings) == .swallow)
        #expect(processor.process(event(.buttonDown(1), .option), settings: settings) == .passThrough)
    }

    @Test func scalingFollowsTheDirectionAfterTheSidewaysModifier() {
        var processor = EventProcessor()
        let held: ModifierSet = [.shift, .option]
        let leftRight = scaled(2, axes: .horizontal, sideways: .shift)
        #expect(processor.process(event(notch(-1), held), settings: leftRight) == .scroll(ScrollSample(horizontal: .lines(-2)), removing: [.shift, .option]))
        #expect(processor.process(event(notch(-1), .shift), settings: leftRight) == .scroll(ScrollSample(horizontal: .lines(-1)), removing: .shift))
        #expect(processor.process(event(notch(-1), .option), settings: leftRight) == .passThrough)

        // Nothing is left to scale up and down once the wheel goes sideways, so ⌥ stays for the app.
        let upDown = scaled(2, axes: .vertical, sideways: .shift)
        #expect(processor.process(event(notch(-1), held), settings: upDown) == .scroll(ScrollSample(horizontal: .lines(-1)), removing: .shift))
        #expect(processor.process(event(notch(-1), .option), settings: upDown) == .scroll(ScrollSample(vertical: .lines(-2)), removing: .option))
    }

    @Test func smoothScrollingAndDisabledDevicesAreLeftAlone() {
        var processor = EventProcessor()
        let smooth = InputKind.scroll(ScrollSample(vertical: ScrollAxis(lines: 1, fixed: 1.5, points: 15), isContinuous: true))
        #expect(processor.process(event(smooth, .option), settings: scaled(2)) == .passThrough)
        let deviceOff = scaled(2) { $0.devices[Self.mouse.id] = DeviceSettings(enabled: false) }
        #expect(processor.process(event(notch(1), .option), settings: deviceOff) == .passThrough)
    }

    @Test func scalingThatCantBeUsedIsIgnored() {
        var processor = EventProcessor()
        let unusable = [
            ModifierScaling(modifiers: [], multiplier: 2),
            ModifierScaling(modifiers: .function, multiplier: 2),
            ModifierScaling(modifiers: .option, multiplier: 0),
            ModifierScaling(modifiers: .option, multiplier: -2),
            ModifierScaling(modifiers: .option, multiplier: .nan),
            ModifierScaling(modifiers: .option, multiplier: .infinity),
        ]
        for scaling in unusable {
            let settings = compiled(scroll: ScrollSettings(modifierScaling: scaling))
            #expect(processor.process(event(notch(1), [.option, .function]), settings: settings) == .passThrough)
            #expect(processor.process(event(notch(1)), settings: settings) == .passThrough)
        }

        // The sideways modifier keeps working when the speed would take the same keys.
        let clash = compiled(scroll: ScrollSettings(horizontalModifier: .option, modifierScaling: ModifierScaling(modifiers: [.option, .function], multiplier: 3)))
        #expect(processor.process(event(notch(1), .option), settings: clash) == .scroll(ScrollSample(horizontal: .lines(1)), removing: .option))
    }

    @Test func theMultiplierStaysInsideItsRange() {
        var processor = EventProcessor()
        #expect(vertical(processor.process(event(notch(1), .option), settings: scaled(0.01)))?.fixed == ScrollMath.multiplierRange.lowerBound)
        #expect(vertical(processor.process(event(notch(1), .option), settings: scaled(100)))?.fixed == ScrollMath.multiplierRange.upperBound)
        // No change at all, so the event isn't rewritten and the modifier keeps working in the app.
        #expect(processor.process(event(notch(1), .option), settings: scaled(1)) == .passThrough)
    }

    @Test func aNotchThatScalesToNothingIsSwallowed() {
        var processor = EventProcessor()
        let settings = scaled(0.25)
        let linesOnly = InputKind.scroll(ScrollSample(vertical: ScrollAxis(lines: 1)))
        let plans = ticks(4).map { processor.process(event(linesOnly, .option, at: $0), settings: settings) }
        #expect(plans == [.swallow, .swallow, .swallow, .scroll(ScrollSample(vertical: ScrollAxis(lines: 1)), removing: .option)])
    }
}
