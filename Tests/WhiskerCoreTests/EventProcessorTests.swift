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

    private func event(_ kind: InputKind, _ modifiers: ModifierSet = [], at time: TimeInterval = 0, device: DeviceAttribution? = mouse) -> InputEvent {
        InputEvent(kind, modifiers: modifiers, timestamp: time, device: device, app: "com.example.app")
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
}
