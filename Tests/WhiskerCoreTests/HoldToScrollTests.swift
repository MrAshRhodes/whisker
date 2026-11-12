import Foundation
import Testing
@testable import WhiskerCore

@Suite("Hold to scroll")
struct HoldToScrollTests {
    private static let ball = DeviceAttribution(id: "046d:c52b", exact: true)
    private static let other = DeviceAttribution(id: "1234:5678", exact: true)
    private static let anchor = PointerPoint(x: 400, y: 300)
    private static let app = "com.example.app"

    private func compiled(_ config: HoldScroll = HoldScroll(), button: Int = 3, configure: (inout WhiskerSettings) -> Void = { _ in }) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(button), action: .holdToScroll(config))]
        configure(&settings)
        return CompiledSettings(settings)
    }

    private func press(_ button: Int = 3, device: DeviceAttribution? = ball, app: String? = app) -> InputEvent {
        InputEvent(.buttonDown(button), device: device, app: app, location: Self.anchor)
    }

    private func release(_ button: Int = 3) -> InputEvent {
        InputEvent(.buttonUp(button), device: Self.ball, app: Self.app)
    }

    /// A drag of the held button; the pointer is one event's movement away from the anchor, as it is when it
    /// has been put back after every event.
    private func move(_ dx: Int, _ dy: Int, from source: DeviceAttribution? = ball, app: String? = app, at location: PointerPoint? = nil, button: Int = 3) -> InputEvent {
        InputEvent(
            .buttonDragged(button), device: Self.ball, app: app,
            location: location ?? PointerPoint(x: Self.anchor.x + Double(dx), y: Self.anchor.y + Double(dy)),
            motion: PointerMotion(dx: dx, dy: dy), motionDevice: source
        )
    }

    private func scrolled(_ vertical: Int, _ horizontal: Int = 0) -> EventPlan {
        .holdScroll(ScrollPixels(vertical: vertical, horizontal: horizontal), anchor: Self.anchor)
    }

    // MARK: Accumulator

    @Test func accumulatorKeepsFractionsOnBothAxes() {
        var scroller = DisplacementScroller(HoldScroll(axes: .free, sensitivity: 0.4))
        var vertical = 0, horizontal = 0
        for _ in 0..<5 {
            let pixels = scroller.add(PointerMotion(dx: -1, dy: 1))
            vertical += pixels.vertical
            horizontal += pixels.horizontal
        }
        #expect(vertical == 2)
        #expect(horizontal == -2)
    }

    @Test func accumulatorFollowsTheBallAndHonoursReverse() {
        var natural = DisplacementScroller(HoldScroll(axes: .free))
        #expect(natural.add(PointerMotion(dx: 3, dy: 5)) == ScrollPixels(vertical: 5, horizontal: 3))
        var reversed = DisplacementScroller(HoldScroll(axes: .free, invertVertical: true, invertHorizontal: true))
        #expect(reversed.add(PointerMotion(dx: 3, dy: 5)) == ScrollPixels(vertical: -5, horizontal: -3))
        var oneAxis = DisplacementScroller(HoldScroll(axes: .free, invertVertical: true))
        #expect(oneAxis.add(PointerMotion(dx: 3, dy: 5)) == ScrollPixels(vertical: -5, horizontal: 3))
    }

    @Test func lockedOutAxesProduceNothingAndStoreNothing() {
        var vertical = DisplacementScroller(HoldScroll(axes: .vertical, sensitivity: 0.5))
        #expect(vertical.add(PointerMotion(dx: 9, dy: 1)) == ScrollPixels())
        #expect(vertical.add(PointerMotion(dx: 9, dy: 1)) == ScrollPixels(vertical: 1))
        var horizontal = DisplacementScroller(HoldScroll(axes: .horizontal))
        #expect(horizontal.add(PointerMotion(dx: -4, dy: 9)) == ScrollPixels(horizontal: -4))
    }

    @Test func reversingDirectionCancelsTheResidueInsteadOfJumping() {
        var scroller = DisplacementScroller(HoldScroll(axes: .vertical, sensitivity: 0.5))
        #expect(scroller.add(PointerMotion(dx: 0, dy: 1)).vertical == 0)
        #expect(scroller.add(PointerMotion(dx: 0, dy: -1)).vertical == 0)
        #expect(scroller.add(PointerMotion(dx: 0, dy: 2)).vertical == 1)
    }

    // MARK: State machine

    @Test func holdScrollsOnlyWhileTheButtonIsHeldAndRestoresMovementOnRelease() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(press(), settings: settings) == .swallow)
        #expect(processor.isHolding)
        #expect(processor.holdStatus == .scrolling)
        #expect(processor.process(move(2, 5), settings: settings) == scrolled(5))
        #expect(processor.process(move(-1, -3), settings: settings) == scrolled(-3))
        #expect(processor.process(release(), settings: settings) == .swallow)
        #expect(!processor.isHolding)
        #expect(processor.holdStatus == .idle)
        // Plain movement afterwards is not the processor's business.
        #expect(processor.process(InputEvent(.buttonDragged(3), device: Self.ball, app: Self.app), settings: settings) == .passThrough)
    }

    @Test func horizontalAndFreeModesUseTheirAxes() {
        var processor = EventProcessor()
        let horizontal = compiled(HoldScroll(axes: .horizontal))
        _ = processor.process(press(), settings: horizontal)
        #expect(processor.process(move(4, 7), settings: horizontal) == scrolled(0, 4))
        _ = processor.process(release(), settings: horizontal)
        let free = compiled(HoldScroll(axes: .free))
        _ = processor.process(press(), settings: free)
        #expect(processor.process(move(4, -7), settings: free) == scrolled(-7, 4))
    }

    @Test func repeatedPressesStartFreshWithoutCarryOver() {
        var processor = EventProcessor()
        let settings = compiled(HoldScroll(sensitivity: 0.5))
        for _ in 0..<3 {
            _ = processor.process(press(), settings: settings)
            #expect(processor.process(move(0, 1), settings: settings) == scrolled(0))
            _ = processor.process(release(), settings: settings)
        }
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(0, 1), settings: settings) == scrolled(0))
    }

    @Test func pressAfterAMissedReleaseStartsAgain() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(0, 2), settings: settings) == scrolled(2))
    }

    @Test func primaryButtonGuardStillApplies() {
        var processor = EventProcessor()
        let primary = compiled(button: 0)
        #expect(processor.process(press(0), settings: primary) == .passThrough)
        #expect(!processor.isHolding)
        let allowed = compiled(button: 0) { $0.general.allowPrimaryButtonRemap = true }
        #expect(processor.process(press(0), settings: allowed) == .swallow)
        #expect(processor.process(move(0, 2, button: 0), settings: allowed) == scrolled(2))
    }

    @Test func unrelatedButtonsAndDragsAreUntouched() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(InputEvent(.buttonDown(1), device: Self.ball, app: Self.app), settings: settings) == .passThrough)
        #expect(processor.process(InputEvent(.buttonDragged(1), device: Self.ball, app: Self.app), settings: settings) == .passThrough)
        #expect(processor.process(InputEvent(.buttonUp(1), device: Self.ball, app: Self.app), settings: settings) == .passThrough)
        #expect(processor.isHolding)
    }

    // MARK: Attribution

    @Test func aSecondMouseMovesNormallyAndNeverScrolls() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(3, 3, from: Self.other), settings: settings) == .dragAsMove)
        #expect(processor.process(move(3, 3, from: Self.other), settings: settings) == .dragAsMove)
        #expect(processor.process(move(3, 3, from: Self.other), settings: settings) == .dragAsMove)
        #expect(processor.holdStatus == .scrolling)
        #expect(processor.process(move(0, 4), settings: settings) == scrolled(4))
    }

    @Test func ambiguousOrInferredMovementPassesThroughAndEventuallyFallsBack() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(0, 4, from: nil), settings: settings) == .dragAsMove)
        // One good event resets the count; a guess that isn't exact is never accepted.
        #expect(processor.process(move(0, 4), settings: settings) == scrolled(4))
        #expect(processor.process(move(0, 4, from: DeviceAttribution(id: Self.ball.id, exact: false)), settings: settings) == .dragAsMove)
        #expect(processor.process(move(0, 4, from: nil), settings: settings) == .dragAsMove)
        #expect(processor.holdStatus == .scrolling)
        #expect(processor.process(move(0, 4, from: nil), settings: settings) == .dragAsMove)
        #expect(processor.holdStatus == .fellBack(.attributionLost))
        // Latched: even clean movement stays ordinary until the next press.
        #expect(processor.process(move(0, 4), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
        #expect(processor.holdStatus == .fellBack(.attributionLost))
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(0, 4), settings: settings) == scrolled(4))
    }

    @Test func movementWithoutDataIsOrdinary() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(InputEvent(.buttonDragged(3), device: Self.ball, app: Self.app), settings: settings) == .dragAsMove)
    }

    @Test func pressWithoutExactDeviceOrPositionKeepsTheButtonNormal() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(press(device: nil), settings: settings) == .passThrough)
        #expect(processor.holdStatus == .unavailable)
        #expect(processor.process(press(device: DeviceAttribution(id: Self.ball.id, exact: false)), settings: settings) == .passThrough)
        let noPosition = InputEvent(.buttonDown(3), device: Self.ball, app: Self.app)
        #expect(processor.process(noPosition, settings: settings) == .passThrough)
        #expect(!processor.isHolding)
        #expect(processor.process(release(), settings: settings) == .passThrough)
        _ = processor.process(press(), settings: settings)
        #expect(processor.holdStatus == .scrolling)
    }

    @Test func aSecondHoldButtonDoesNotStealTheFirst() {
        var processor = EventProcessor()
        let settings = compiled { $0.profiles[0].mappings.append(Mapping(trigger: .button(4), action: .holdToScroll(HoldScroll(axes: .horizontal)))) }
        _ = processor.process(press(3), settings: settings)
        #expect(processor.process(press(4), settings: settings) == .swallow)
        #expect(processor.process(move(1, 2), settings: settings) == scrolled(2))
        #expect(processor.process(release(4), settings: settings) == .swallow)
        #expect(processor.isHolding)
    }

    // MARK: Safety net

    @Test func driftFromTheAnchorFallsBackToOrdinaryMovement() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(0, 4), settings: settings) == scrolled(4))
        let drifted = move(0, 4, at: PointerPoint(x: Self.anchor.x + 80, y: Self.anchor.y + 80))
        #expect(processor.process(drifted, settings: settings) == .dragAsMove)
        #expect(processor.holdStatus == .fellBack(.pointerDrifted))
        #expect(processor.process(move(0, 4), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
    }

    @Test func movementAtAScreenEdgeIsNotDrift() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(0, 40, at: Self.anchor), settings: settings) == scrolled(40))
    }

    // MARK: Cancellation

    @Test func cancelEndsTheHoldButKeepsTheButtonSwallowed() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        processor.cancelHold()
        #expect(!processor.isHolding)
        #expect(processor.process(move(0, 4), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
        // And the next press works normally.
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(0, 4), settings: settings) == scrolled(4))
    }

    @Test func releaseAllEndsTheHoldAndTheLateReleaseStaysSwallowed() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.releaseAll().isEmpty)
        #expect(!processor.isHolding)
        #expect(processor.process(move(0, 4), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
        #expect(processor.process(release(), settings: settings) == .passThrough)
    }

    @Test func losingTheDeviceEndsTheHold() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        processor.cancelHold(unlessConnected: [Self.ball.id, Self.other.id])
        #expect(processor.isHolding)
        processor.cancelHold(unlessConnected: [Self.other.id])
        #expect(!processor.isHolding)
        #expect(processor.process(move(0, 4), settings: settings) == .dragAsMove)
    }

    @Test func changingAppDisablingOrBypassingEndsTheHold() {
        let settings = compiled()
        var processor = EventProcessor()
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(0, 4, app: "com.example.other"), settings: settings) == .dragAsMove)
        #expect(!processor.isHolding)

        _ = processor.process(release(), settings: settings)
        _ = processor.process(press(), settings: settings)
        let off = compiled { $0.general.enabled = false }
        #expect(processor.process(move(0, 4), settings: off) == .dragAsMove)
        #expect(!processor.isHolding)

        _ = processor.process(release(), settings: settings)
        _ = processor.process(press(), settings: settings)
        let bypassed = compiled { $0.general.bypassApps = [Self.app] }
        #expect(processor.process(move(0, 4), settings: bypassed) == .dragAsMove)
        #expect(!processor.isHolding)
    }

    @Test func settingsAreSnapshottedAtThePress() {
        var processor = EventProcessor()
        _ = processor.process(press(), settings: compiled(HoldScroll(sensitivity: 1)))
        #expect(processor.process(move(0, 4), settings: compiled(HoldScroll(sensitivity: 3))) == scrolled(4))
    }

    // MARK: Automatic axis lock

    private static let lock = AxisLockSelector.selectionThreshold

    @Test func selectorPicksTheDominantAxisInEverySign() {
        let n = Self.lock
        for (dx, dy, state, out) in [
            (1, n, AxisLockSelector.State.vertical, PointerMotion(dx: 0, dy: n)),
            (-1, -n, .vertical, PointerMotion(dx: 0, dy: -n)),
            (n, 1, .horizontal, PointerMotion(dx: n, dy: 0)),
            (-n, -1, .horizontal, PointerMotion(dx: -n, dy: 0)),
        ] {
            var selector = AxisLockSelector()
            #expect(selector.filter(PointerMotion(dx: dx, dy: dy)) == out)
            #expect(selector.state == state)
        }
    }

    @Test func jitterBelowTheThresholdStaysUndecidedAndSmallMovesAccumulate() {
        var selector = AxisLockSelector()
        #expect(selector.filter(PointerMotion(dx: 2, dy: -1)) == PointerMotion(dx: 0, dy: 0))
        #expect(selector.filter(PointerMotion(dx: -2, dy: 1)) == PointerMotion(dx: 0, dy: 0))
        #expect(selector.state == .undecided)
        var slow = AxisLockSelector()
        var total = PointerMotion(dx: 0, dy: 0)
        for _ in 0..<Self.lock {
            let out = slow.filter(PointerMotion(dx: 0, dy: 1))
            total.dy += out.dy
        }
        #expect(slow.state == .vertical)
        #expect(total.dy == Self.lock)
    }

    @Test func balancedDiagonalSelectsVertical() {
        var selector = AxisLockSelector()
        #expect(selector.filter(PointerMotion(dx: Self.lock, dy: -Self.lock)) == PointerMotion(dx: 0, dy: -Self.lock))
        #expect(selector.state == .vertical)
    }

    @Test func lockHoldsThroughReversalsAndDiscardsThePerpendicular() {
        var selector = AxisLockSelector()
        _ = selector.filter(PointerMotion(dx: 3, dy: Self.lock))
        #expect(selector.filter(PointerMotion(dx: 50, dy: -4)) == PointerMotion(dx: 0, dy: -4))
        #expect(selector.filter(PointerMotion(dx: -50, dy: 0)) == PointerMotion(dx: 0, dy: 0))
        #expect(selector.filter(PointerMotion(dx: 0, dy: 6)) == PointerMotion(dx: 0, dy: 6))
    }

    @Test func automaticScrollingSelectsBeforeSensitivityAndKeepsInitialMovementOnce() {
        var scroller = DisplacementScroller(HoldScroll(axes: .automatic, sensitivity: 0.5, invertHorizontal: true))
        #expect(scroller.add(PointerMotion(dx: -3, dy: 1)) == ScrollPixels())
        // Selection uses raw counts: the same movement at any sensitivity picks the same axis.
        #expect(scroller.add(PointerMotion(dx: -Self.lock, dy: 2)) == ScrollPixels(vertical: 0, horizontal: (3 + Self.lock) / 2))
        #expect(scroller.add(PointerMotion(dx: 0, dy: 40)) == ScrollPixels())
    }

    @Test func automaticHoldStartsUndecidedEachTimeAndNothingLeaksAcrossHolds() {
        var processor = EventProcessor()
        let settings = compiled(HoldScroll(axes: .automatic))
        let n = Self.lock
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(2, 3), settings: settings) == scrolled(0))
        #expect(processor.process(move(1, n), settings: settings) == scrolled(n + 3))
        #expect(processor.process(move(9, -2), settings: settings) == scrolled(-2))
        _ = processor.process(release(), settings: settings)
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(n, 1), settings: settings) == scrolled(0, n))
    }

    @Test func interruptionsEndAnAutomaticHoldAndTheNextOneIsFresh() {
        let settings = compiled(HoldScroll(axes: .automatic))
        let n = Self.lock
        var processor = EventProcessor()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(move(0, n), settings: settings)
        _ = processor.process(InputEvent(.buttonDragged(3), device: Self.ball, app: "other.app", location: Self.anchor, motion: PointerMotion(dx: 1, dy: 0), motionDevice: Self.ball), settings: settings)
        _ = processor.process(release(), settings: settings)
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(n, 0), settings: settings) == scrolled(0, n))
    }

    @Test func freeAndFixedModesAreUnchangedByTheLock() {
        var free = DisplacementScroller(HoldScroll(axes: .free))
        #expect(free.add(PointerMotion(dx: 1, dy: 1)) == ScrollPixels(vertical: 1, horizontal: 1))
        var fixed = DisplacementScroller(HoldScroll(axes: .horizontal))
        #expect(fixed.add(PointerMotion(dx: 1, dy: 50)) == ScrollPixels(horizontal: 1))
    }

    @Test func automaticAxesRoundTripInheritAndOldFilesDecodeUnchanged() throws {
        let config = HoldScroll(axes: .automatic, sensitivity: 2)
        let decoded = try SettingsCodec.decode(SettingsCodec.encode(compiled(config).settings))
        #expect(decoded.profiles[0].mappings == [Mapping(trigger: .button(3), action: .holdToScroll(config))])
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Action.holdToScroll(config))) as? [String: Any]
        #expect(json?["axes"] as? String == "automatic")
        for old in ["vertical", "horizontal", "free"] {
            let action = try JSONDecoder().decode(Action.self, from: Data(#"{"kind":"holdToScroll","axes":"\#(old)"}"#.utf8))
            #expect(action == .holdToScroll(HoldScroll(axes: HoldScrollAxes(rawValue: old)!)))
        }
        #expect(try JSONDecoder().decode(Action.self, from: Data(#"{"kind":"holdToScroll"}"#.utf8)) == .holdToScroll(HoldScroll()))
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .holdToScroll(config))]
        settings.profiles.append(Profile(id: "app", name: "App", match: ProfileMatch(apps: [Self.app]), inherits: Profile.defaultID))
        #expect(settings.resolvedProfile(id: "app").mapping(.button(3), modifiers: [])?.action == .holdToScroll(config))
    }

    // MARK: Settings

    @Test func settingsRoundTripAndOldFilesDecodeUnchanged() throws {
        let config = HoldScroll(axes: .free, sensitivity: 2.5, invertVertical: true, invertHorizontal: true)
        let settings = compiled(config).settings
        let decoded = try SettingsCodec.decode(SettingsCodec.encode(settings))
        #expect(decoded.profiles[0].mappings == [Mapping(trigger: .button(3), action: .holdToScroll(config))])

        let minimal = try JSONDecoder().decode(Action.self, from: Data(#"{"kind":"holdToScroll"}"#.utf8))
        #expect(minimal == .holdToScroll(HoldScroll()))
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Action.holdToScroll(config))) as? [String: Any]
        #expect(json?["kind"] as? String == "holdToScroll")
        #expect(json?["axes"] as? String == "free")
    }

    @Test func invalidSensitivityIsReportedAndDropped() {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .holdToScroll(HoldScroll(sensitivity: 50)))]
        let result = settings.repairedWithIssues()
        #expect(result.issues.contains { $0.message.contains("sensitivity") })
        #expect(result.settings.profiles[0].mappings.isEmpty)
    }

    @Test func profilesInheritAndOverrideTheHold() {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .holdToScroll(HoldScroll(axes: .free)))]
        settings.profiles.append(Profile(id: "app", name: "App", match: ProfileMatch(apps: [Self.app]), inherits: Profile.defaultID))
        #expect(settings.resolvedProfile(id: "app").mapping(.button(3), modifiers: [])?.action == .holdToScroll(HoldScroll(axes: .free)))
        settings.profiles[1].mappings = [Mapping(trigger: .button(3), action: .holdToScroll(HoldScroll(axes: .vertical)))]
        var processor = EventProcessor()
        let compiled = CompiledSettings(settings)
        _ = processor.process(press(), settings: compiled)
        #expect(processor.process(move(4, 6), settings: compiled) == scrolled(6))
        #expect(compiled.needsMotion)
        #expect(!CompiledSettings(.default).needsMotion)
        var disabled = settings
        disabled.general.enabled = false
        #expect(!CompiledSettings(disabled).needsMotion)
    }

    // MARK: Device attribution of movement

    @Test func motionIsAttributedOnlyToAOneAndOnlyReportingDevice() {
        var attributor = DeviceAttributor(connected: ["a", "b"])
        #expect(attributor.attributeMotion(at: 1) == nil)
        attributor.recordMotion(deviceID: "a", at: 1)
        #expect(attributor.attributeMotion(at: 1.01) == DeviceAttribution(id: "a", exact: true))
        #expect(attributor.attributeMotion(at: 1.2) == nil)
        attributor.recordMotion(deviceID: "b", at: 1.005)
        #expect(attributor.attributeMotion(at: 1.01) == nil)
    }

    @Test func aSoleMouseIsNotGuessedForUnreportedMotion() {
        let attributor = DeviceAttributor(connected: ["a"])
        #expect(attributor.attributeMotion(at: 1) == nil)
        #expect(attributor.attribute(kind: .wheel, at: 1) == DeviceAttribution(id: "a", exact: false))
    }

    @Test func excludedTrackpadMotionIsNeverBorrowedAndVetoesTheMouse() {
        var attributor = DeviceAttributor(connected: ["mouse"])
        attributor.excluded = ["trackpad"]
        attributor.recordMotion(deviceID: "trackpad", at: 1)
        #expect(attributor.attributeMotion(at: 1.01) == nil)
        attributor.recordMotion(deviceID: "mouse", at: 1.005)
        #expect(attributor.attributeMotion(at: 1.01) == nil)
        attributor.recordMotion(deviceID: "mouse", at: 2)
        #expect(attributor.attributeMotion(at: 2.01) == DeviceAttribution(id: "mouse", exact: true))
    }
}
