import Foundation
import Testing
@testable import WhiskerCore

@Suite("Button gestures")
struct ButtonGestureTests {
    private static let thumb = DeviceAttribution(id: "046d:b034", exact: true)
    private static let other = DeviceAttribution(id: "1234:5678", exact: true)
    private static let guess = DeviceAttribution(id: "046d:b034", exact: false)
    private static let app = "com.example.app"
    private static let elsewhere = "com.example.elsewhere"

    private static let upAction = Action.missionControl(.missionControl)
    private static let downAction = Action.missionControl(.showDesktop)
    private static let leftAction = Action.navigate(.back)
    private static let rightAction = Action.navigate(.forward)
    private static let tapAction = Action.media(.playPause)
    /// Every slot set, with a threshold of its own so the tests don't move with the default.
    private static let all = ButtonGestures(
        up: upAction, down: downAction, left: leftAction, right: rightAction, tap: tapAction, threshold: 100
    )

    private func compiled(_ gestures: ButtonGestures = all, button: Int = 3, configure: (inout WhiskerSettings) -> Void = { _ in }) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(button), action: .passthrough, gestures: gestures)]
        configure(&settings)
        return CompiledSettings(settings)
    }

    private func press(_ button: Int = 3, device: DeviceAttribution? = thumb, app: String? = app, modifiers: ModifierSet = []) -> InputEvent {
        InputEvent(.buttonDown(button), modifiers: modifiers, device: device, app: app)
    }

    private func release(_ button: Int = 3, device: DeviceAttribution? = thumb, app: String? = app) -> InputEvent {
        InputEvent(.buttonUp(button), device: device, app: app)
    }

    /// A drag of the held button carrying one event's movement.
    private func move(_ dx: Int, _ dy: Int, from source: DeviceAttribution? = thumb, app: String? = app, button: Int = 3) -> InputEvent {
        InputEvent(.buttonDragged(button), device: Self.thumb, app: app, motion: PointerMotion(dx: dx, dy: dy), motionDevice: source)
    }

    private func makeSession(_ gestures: ButtonGestures = all) -> GestureSession {
        GestureSession(button: 3, device: Self.thumb.id, app: Self.app, profile: Profile.defaultID, config: gestures)
    }

    private func drag(_ session: inout GestureSession, _ dx: Int, _ dy: Int, from source: DeviceAttribution? = thumb) {
        session.move(PointerMotion(dx: dx, dy: dy), from: source)
    }

    // MARK: Picking a direction

    @Test func theFirstMovementToReachTheThresholdPicksTheDominantAxis() throws {
        let cases: [(dx: Int, dy: Int, direction: GestureDirection)] = [
            (100, 0, .right), (-100, 0, .left), (0, 100, .down), (0, -100, .up),
            (130, 40, .right), (-40, -130, .up), (-200, 49, .left), (25, 200, .down),
        ]
        for (dx, dy, direction) in cases {
            var session = makeSession()
            drag(&session, dx, dy)
            #expect(session.state == .selected(direction))
            #expect(session.release(from: Self.thumb) == .perform(try #require(Self.all.action(for: direction))))
        }
    }

    @Test func theThresholdIsMeasuredOnNetMovementAndItselfCounts() {
        var session = makeSession()
        drag(&session, 99, 0)
        #expect(session.state == .undecided)
        drag(&session, 1, 0)
        #expect(session.state == .selected(.right))

        var steps = makeSession()
        for _ in 0..<24 { drag(&steps, 0, -4) }
        #expect(steps.state == .undecided)
        drag(&steps, 0, -4)
        #expect(steps.state == .selected(.up))
    }

    @Test func jitterAndReversalsThatGoNowhereNeverPickADirection() {
        var session = makeSession()
        for _ in 0..<20 {
            drag(&session, 80, 3)
            drag(&session, -80, -3)
        }
        #expect(session.state == .undecided)
        #expect(session.release(from: Self.thumb) == .perform(Self.tapAction))

        // Going back on oneself before the pick only counts the distance that is left.
        drag(&session, 70, 0)
        drag(&session, -150, 0)
        #expect(session.state == .undecided)
        drag(&session, -30, 0)
        #expect(session.state == .selected(.left))
    }

    @Test func thePickIsLatchedAndLaterMovementCannotChangeIt() {
        var session = makeSession()
        drag(&session, 0, -120)
        drag(&session, 0, 500)
        drag(&session, -500, 0)
        #expect(session.state == .selected(.up))
        #expect(session.release(from: Self.thumb) == .perform(Self.upAction))
    }

    @Test func theDominantAxisNeedsTwiceTheMovementOfTheOther() {
        let ratio = ButtonGestures.dominanceRatio
        var clear = makeSession()
        drag(&clear, 100, 100 / ratio)
        #expect(clear.state == .selected(.right))

        for (dx, dy) in [(100, 100 / ratio + 1), (100, 100), (-70, 110), (-100, -100)] {
            var diagonal = makeSession()
            drag(&diagonal, dx, dy)
            #expect(diagonal.state == .ambiguous)
            #expect(diagonal.release(from: Self.thumb) == .nothing)
        }
    }

    @Test func ambiguousMovementStaysAmbiguousWhateverFollows() {
        var session = makeSession()
        drag(&session, 100, 100)
        drag(&session, 0, -500)
        #expect(session.state == .ambiguous)
        #expect(session.release(from: Self.thumb) == .nothing)
    }

    @Test func aDirectionOrTapWithoutAnActionPerformsNothing() {
        var session = makeSession(ButtonGestures(left: Self.leftAction, threshold: 100))
        #expect(session.release(from: Self.thumb) == .nothing)
        drag(&session, 0, 150)
        #expect(session.state == .selected(.down))
        #expect(session.release(from: Self.thumb) == .nothing)
    }

    @Test func thresholdsOutsideTheRangeAreClamped() {
        let range = ButtonGestures.thresholdRange
        var low = makeSession(ButtonGestures(right: Self.rightAction, threshold: range.lowerBound - 15))
        drag(&low, range.lowerBound - 1, 0)
        #expect(low.state == .undecided)
        drag(&low, 1, 0)
        #expect(low.state == .selected(.right))

        var high = makeSession(ButtonGestures(right: Self.rightAction, threshold: range.upperBound * 10))
        drag(&high, range.upperBound - 1, 0)
        #expect(high.state == .undecided)
        drag(&high, 1, 0)
        #expect(high.state == .selected(.right))
    }

    @Test func actionsThatDoNotHappenOnceAreNeverPerformed() {
        // Validation drops these on load; this is the second line of defence.
        var session = makeSession(ButtonGestures(right: .click(button: 1, modifiers: []), tap: .holdToScroll(HoldScroll()), threshold: 100))
        #expect(session.release(from: Self.thumb) == .nothing)
        drag(&session, 150, 0)
        #expect(session.release(from: Self.thumb) == .nothing)
    }

    // MARK: Devices

    @Test func anotherMiceMovementIsNeverCounted() {
        var session = makeSession()
        drag(&session, 300, 0, from: Self.other)
        drag(&session, 0, 300, from: Self.other)
        #expect(session.state == .undecided)
        drag(&session, 0, 120)
        #expect(session.state == .selected(.down))
    }

    @Test func onlyThePressingDeviceCanCompleteTheGesture() {
        var session = makeSession()
        drag(&session, 150, 0)
        #expect(session.release(from: Self.other) == .nothing)
        #expect(session.release(from: Self.thumb) == .perform(Self.rightAction))
        // A release that can't be attributed is taken as the pressing device's: its movement was verified.
        #expect(session.release(from: nil) == .perform(Self.rightAction))
        #expect(session.release(from: Self.guess) == .perform(Self.rightAction))
    }

    @Test func movementThatCannotBeAttributedIsIgnoredAndWhenItKeepsComingTheAttemptIsCalledOff() {
        var session = makeSession()
        drag(&session, 300, 0, from: nil)
        drag(&session, 300, 0, from: Self.guess)
        #expect(session.state == .undecided)
        // One verified movement starts the count again.
        drag(&session, 5, 0)
        drag(&session, 300, 0, from: nil)
        drag(&session, 300, 0, from: nil)
        #expect(session.state == .undecided)
        drag(&session, 300, 0, from: nil)
        #expect(session.state == .cancelled)
        drag(&session, 0, 300)
        #expect(session.state == .cancelled)
        #expect(session.release(from: Self.thumb) == .nothing)
    }

    // MARK: Events

    @Test func theButtonIsSwallowedItsDragsMoveThePointerAndReleasePerformsTheDirectionOnce() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(press(), settings: settings) == .swallow)
        #expect(processor.isRecognisingGesture)
        #expect(processor.process(move(40, 5), settings: settings) == .dragAsMove)
        #expect(processor.process(move(40, -5), settings: settings) == .dragAsMove)
        #expect(processor.isRecognisingGesture)
        #expect(processor.process(move(40, 0), settings: settings) == .dragAsMove)
        #expect(!processor.isRecognisingGesture)
        #expect(processor.process(move(-300, 0), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .perform(Self.rightAction, .once))
        #expect(processor.process(release(), settings: settings) == .passThrough)
        #expect(processor.heldButtons.isEmpty)
    }

    @Test func eachDirectionAndTheTapPerformTheirOwnActionOnce() {
        var processor = EventProcessor()
        let settings = compiled()
        let cases: [(dx: Int, dy: Int, action: Action)] = [
            (0, -150, Self.upAction), (0, 150, Self.downAction), (-150, 0, Self.leftAction), (150, 0, Self.rightAction), (10, -5, Self.tapAction),
        ]
        for (dx, dy, action) in cases {
            #expect(processor.process(press(), settings: settings) == .swallow)
            #expect(processor.process(move(dx, dy), settings: settings) == .dragAsMove)
            #expect(processor.process(release(), settings: settings) == .perform(action, .once))
            #expect(processor.process(release(), settings: settings) == .passThrough)
        }
    }

    @Test func ambiguousOrUnsetGesturesPerformNothingButStayConsumed() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(move(150, 150), settings: settings)
        #expect(processor.process(release(), settings: settings) == .swallow)

        let sparse = compiled(ButtonGestures(left: Self.leftAction, threshold: 100))
        _ = processor.process(press(), settings: sparse)
        _ = processor.process(move(5, 5), settings: sparse)
        #expect(processor.process(release(), settings: sparse) == .swallow)
        _ = processor.process(press(), settings: sparse)
        _ = processor.process(move(0, 150), settings: sparse)
        #expect(processor.process(release(), settings: sparse) == .swallow)
    }

    @Test func aButtonWithoutAnyGestureActionKeepsItsOrdinaryBehaviour() {
        var processor = EventProcessor()
        let settings = compiled(ButtonGestures())
        #expect(processor.process(press(), settings: settings) == .passThrough)
        #expect(!processor.isRecognisingGesture)
        #expect(processor.process(move(150, 0), settings: settings) == .passThrough)
        #expect(processor.process(release(), settings: settings) == .passThrough)
    }

    @Test func aPressAfterAMissedReleaseStartsFresh() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(move(80, 0), settings: settings)
        #expect(processor.process(press(), settings: settings) == .swallow)
        // Carried over, the two movements would add up to a pick.
        _ = processor.process(move(80, 0), settings: settings)
        #expect(processor.isRecognisingGesture)
        #expect(processor.process(release(), settings: settings) == .perform(Self.tapAction, .once))
        #expect(processor.process(release(), settings: settings) == .passThrough)
    }

    @Test func movementIsOnlyReadWhileTheDirectionIsStillOpen() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(!processor.wantsMotion)
        _ = processor.process(press(), settings: settings)
        #expect(processor.wantsMotion)
        _ = processor.process(move(150, 0), settings: settings)
        #expect(!processor.wantsMotion)
        _ = processor.process(release(), settings: settings)

        _ = processor.process(press(), settings: settings)
        _ = processor.process(move(150, 150), settings: settings)
        #expect(!processor.wantsMotion)
        _ = processor.process(release(), settings: settings)
        #expect(!processor.wantsMotion)
    }

    @Test func movementFromAnotherMouseOrWithoutDataNeverCountsAndStaysPlainMovement() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(move(300, 0, from: Self.other), settings: settings) == .dragAsMove)
        #expect(processor.process(InputEvent(.buttonDragged(3), device: Self.thumb, app: Self.app), settings: settings) == .dragAsMove)
        #expect(processor.isRecognisingGesture)
        #expect(processor.process(release(), settings: settings) == .perform(Self.tapAction, .once))
    }

    @Test func aReleaseFromAnotherMouseCannotCompleteTheGesture() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(move(150, 0), settings: settings)
        #expect(processor.process(release(device: Self.other), settings: settings) == .swallow)
        #expect(!processor.isRecognisingGesture)
        #expect(processor.process(release(), settings: settings) == .swallow)
        #expect(processor.heldButtons.isEmpty)
    }

    @Test func movementThatKeepsLosingItsDeviceCallsOffTheGesture() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        for _ in 0..<GestureSession.attributionGrace {
            #expect(processor.process(move(150, 0, from: nil), settings: settings) == .dragAsMove)
        }
        #expect(!processor.isRecognisingGesture)
        #expect(processor.process(move(150, 0), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
    }

    @Test func withoutAnExactDeviceTheButtonKeepsItsOrdinaryBehaviour() {
        var processor = EventProcessor()
        let settings = compiled()
        let unknown: [DeviceAttribution?] = [nil, Self.guess]
        for device in unknown {
            #expect(processor.process(press(device: device), settings: settings) == .passThrough)
            #expect(!processor.isRecognisingGesture)
            #expect(processor.process(InputEvent(.buttonDragged(3), device: device, app: Self.app, motion: PointerMotion(dx: 150, dy: 0), motionDevice: device), settings: settings) == .passThrough)
            #expect(processor.process(release(device: device), settings: settings) == .passThrough)
        }
    }

    @Test func otherButtonsAndTheirDragsAreUntouchedDuringAGesture() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        for button in [0, 1, 2, 4] {
            #expect(processor.process(InputEvent(.buttonDown(button), device: Self.thumb, app: Self.app), settings: settings) == .passThrough)
            #expect(processor.process(move(150, 0, button: button), settings: settings) == .passThrough)
            #expect(processor.process(InputEvent(.buttonUp(button), device: Self.thumb, app: Self.app), settings: settings) == .passThrough)
        }
        #expect(processor.isRecognisingGesture)
        #expect(processor.process(release(), settings: settings) == .perform(Self.tapAction, .once))
    }

    @Test func primaryButtonGuardStillApplies() {
        var processor = EventProcessor()
        let primary = compiled(button: 0)
        #expect(processor.process(press(0), settings: primary) == .passThrough)
        #expect(processor.process(move(150, 0, button: 0), settings: primary) == .passThrough)
        #expect(processor.process(release(0), settings: primary) == .passThrough)
        #expect(!processor.isRecognisingGesture)

        let allowed = compiled(button: 0) { $0.general.allowPrimaryButtonRemap = true }
        #expect(processor.process(press(0), settings: allowed) == .swallow)
        #expect(processor.process(release(0), settings: allowed) == .perform(Self.tapAction, .once))

        // With a modifier held the primary button is not the way back, so it can carry gestures.
        let modified = compiled(button: 0) {
            $0.profiles[0].mappings = [Mapping(trigger: .button(0), modifiers: .command, action: .passthrough, gestures: Self.all)]
        }
        #expect(processor.process(press(0, modifiers: .command), settings: modified) == .swallow)
        #expect(processor.process(press(0), settings: modified) == .passThrough)
    }

    @Test func aGestureOnAPlainSecondaryButtonStandsInTheWayOfTheButtonSwap() {
        var processor = EventProcessor()
        // A mapping of the plain button says exactly what it does, so the swap stands aside for it.
        let settings = compiled(button: 1) {
            $0.general.allowPrimaryButtonRemap = true
            $0.devices[Self.thumb.id] = DeviceSettings(swapPrimarySecondary: true)
        }
        #expect(processor.process(press(1), settings: settings) == .swallow)
        #expect(processor.process(move(0, -150, button: 1), settings: settings) == .dragAsMove)
        #expect(processor.process(release(1), settings: settings) == .perform(Self.upAction, .once))
    }

    // MARK: One at a time

    @Test func aGestureAndAHoldNeverRunTogether() {
        var processor = EventProcessor()
        let settings = compiled {
            $0.profiles[0].mappings += [
                Mapping(trigger: .button(4), action: .holdToScroll(HoldScroll())),
                Mapping(trigger: .button(5), action: .passthrough, gestures: Self.all),
            ]
        }
        let anchor = PointerPoint(x: 400, y: 300)
        let holdPress = InputEvent(.buttonDown(4), device: Self.thumb, app: Self.app, location: anchor)

        // The gesture is first: the hold button and a second gesture button are swallowed and do nothing.
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(holdPress, settings: settings) == .swallow)
        #expect(!processor.isHolding)
        #expect(processor.process(move(5, 5, button: 4), settings: settings) == .dragAsMove)
        #expect(processor.process(press(5), settings: settings) == .swallow)
        #expect(processor.process(release(5), settings: settings) == .swallow)
        #expect(processor.process(release(4), settings: settings) == .swallow)
        _ = processor.process(move(150, 0), settings: settings)
        #expect(processor.process(release(), settings: settings) == .perform(Self.rightAction, .once))

        // The hold is first: the gesture button is swallowed and does nothing.
        #expect(processor.process(holdPress, settings: settings) == .swallow)
        #expect(processor.isHolding)
        #expect(processor.process(press(), settings: settings) == .swallow)
        #expect(!processor.isRecognisingGesture)
        #expect(processor.process(release(), settings: settings) == .swallow)
        #expect(processor.isHolding)
    }

    @Test func aGestureAndAnAutoScrollNeverRunTogether() {
        var processor = EventProcessor()
        let settings = compiled {
            $0.profiles[0].mappings += [Mapping(trigger: .button(4), action: .autoScroll(AutoScroll()))]
        }
        let autoPress = InputEvent(.buttonDown(4), device: Self.thumb, app: Self.app, location: PointerPoint(x: 400, y: 300))
        let autoRelease = InputEvent(.buttonUp(4), device: Self.thumb, app: Self.app)

        // The gesture is first: the auto-scroll button is swallowed and starts nothing, and the gesture still completes.
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(autoPress, settings: settings) == .swallow)
        #expect(processor.autoScrollSession == nil)
        #expect(processor.process(autoRelease, settings: settings) == .swallow)
        _ = processor.process(move(150, 0), settings: settings)
        #expect(processor.process(release(), settings: settings) == .perform(Self.rightAction, .once))

        // The auto-scroll is first: pressing the gesture button ends it, and the gesture starts as usual.
        #expect(processor.process(autoPress, settings: settings) == .swallow)
        #expect(processor.autoScrollSession != nil)
        #expect(processor.process(press(), settings: settings) == .swallow)
        #expect(processor.autoScrollSession == nil)
        #expect(processor.isRecognisingGesture)
        _ = processor.process(move(0, 150), settings: settings)
        #expect(processor.process(release(), settings: settings) == .perform(Self.downAction, .once))
        #expect(processor.process(autoRelease, settings: settings) == .swallow)

        // A hand-edited mapping that pairs gestures with Auto-scroll runs the gestures, never the auto-scroll.
        let paired = compiled {
            $0.profiles[0].mappings = [Mapping(trigger: .button(3), action: .autoScroll(AutoScroll()), gestures: Self.all)]
        }
        let pairedPress = InputEvent(.buttonDown(3), device: Self.thumb, app: Self.app, location: PointerPoint(x: 400, y: 300))
        #expect(processor.process(pairedPress, settings: paired) == .swallow)
        #expect(processor.autoScrollSession == nil)
        #expect(processor.isRecognisingGesture)
        _ = processor.process(move(-150, 0), settings: paired)
        #expect(processor.process(release(), settings: paired) == .perform(Self.leftAction, .once))
    }

    // MARK: Cancellation

    @Test func aGestureMappingNeverStartsASlowPointerHoldWhateverItsOwnActionIs() {
        var processor = EventProcessor()
        // The editor stores a gesture mapping as Pass Through; only a hand-edited file can pair gestures with this.
        let settings = compiled {
            $0.profiles[0].mappings = [Mapping(trigger: .button(3), action: .slowPointer(factor: 0.5), gestures: Self.all)]
        }
        #expect(processor.process(press(), settings: settings, slowPointerDevices: [Self.thumb.id]) == .swallow)
        #expect(processor.isRecognisingGesture)
        #expect(processor.slowPointerCommand.factors.isEmpty)
        _ = processor.process(move(150, 0), settings: settings)
        #expect(processor.process(release(), settings: settings, slowPointerDevices: [Self.thumb.id]) == .perform(Self.rightAction, .once))
        #expect(processor.slowPointerCommand.factors.isEmpty)
    }

    @Test func releaseAllCallsOffTheGestureAndTheLateReleaseStaysSwallowed() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(move(150, 0), settings: settings)
        #expect(processor.releaseAll().isEmpty)
        #expect(!processor.isRecognisingGesture)
        #expect(processor.process(move(0, 50), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
        #expect(processor.process(release(), settings: settings) == .passThrough)
    }

    @Test func standingAsideForAnAppCallsOffTheGestureToo() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        #expect(processor.releaseAllForBypass().isEmpty)
        #expect(!processor.isRecognisingGesture)
        #expect(processor.process(move(0, 50), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
        #expect(processor.process(release(), settings: settings) == .passThrough)
    }

    @Test func cancelCallsOffTheGestureButKeepsTheButtonSwallowedUntilItComesUp() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(move(150, 0), settings: settings)
        processor.cancelGesture()
        #expect(processor.process(move(0, 50), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
        // Nothing is kept for later: the next press starts afresh.
        #expect(processor.process(press(), settings: settings) == .swallow)
        _ = processor.process(move(0, -150), settings: settings)
        #expect(processor.process(release(), settings: settings) == .perform(Self.upAction, .once))
    }

    @Test func losingTheDeviceCallsOffTheGesture() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        processor.cancelGesture(unlessConnected: [Self.thumb.id, Self.other.id])
        #expect(processor.isRecognisingGesture)
        processor.cancelGesture(unlessConnected: [Self.other.id])
        #expect(!processor.isRecognisingGesture)
        #expect(processor.process(move(0, 150), settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
    }

    @Test func anAppChangeDisablingOrBypassingCallsOffTheGesture() {
        let settings = compiled()
        let off = compiled { $0.general.enabled = false }
        let bypassed = compiled { $0.general.bypassApps = [Self.app] }
        let changes: [(settings: CompiledSettings, app: String)] = [(settings, Self.elsewhere), (off, Self.app), (bypassed, Self.app)]
        for change in changes {
            // Noticed on the next drag…
            var dragged = EventProcessor()
            _ = dragged.process(press(), settings: settings)
            #expect(dragged.process(move(10, 0, app: change.app), settings: change.settings) == .dragAsMove)
            #expect(!dragged.isRecognisingGesture)
            #expect(dragged.process(move(150, 0), settings: settings) == .dragAsMove)
            #expect(dragged.process(release(), settings: settings) == .swallow)

            // …or at the release, even a gesture that had picked a direction.
            var released = EventProcessor()
            _ = released.process(press(), settings: settings)
            _ = released.process(move(150, 0), settings: settings)
            #expect(released.process(release(app: change.app), settings: change.settings) == .swallow)
            #expect(released.heldButtons.isEmpty)
            #expect(released.process(release(), settings: settings) == .passThrough)
        }
    }

    @Test func theGesturesAreFixedAtThePress() {
        var processor = EventProcessor()
        _ = processor.process(press(), settings: compiled())
        let edited = compiled(ButtonGestures(right: Self.leftAction, threshold: 400))
        _ = processor.process(move(150, 0), settings: edited)
        #expect(processor.process(release(), settings: edited) == .perform(Self.rightAction, .once))
    }

    // MARK: Settings

    @Test func profilesInheritAndOverrideGestures() {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .passthrough, gestures: Self.all)]
        settings.profiles.append(Profile(id: "app", name: "App", match: ProfileMatch(apps: [Self.app]), inherits: Profile.defaultID))
        #expect(settings.resolvedProfile(id: "app").mapping(.button(3), modifiers: [])?.gestures == Self.all)

        let override = ButtonGestures(right: Self.upAction, threshold: 100)
        settings.profiles[1].mappings = [Mapping(trigger: .button(3), action: .passthrough, gestures: override)]
        let compiled = CompiledSettings(settings)
        var processor = EventProcessor()
        _ = processor.process(press(), settings: compiled)
        _ = processor.process(move(150, 0), settings: compiled)
        #expect(processor.process(release(), settings: compiled) == .perform(Self.upAction, .once))
        _ = processor.process(press(app: Self.elsewhere), settings: compiled)
        _ = processor.process(move(150, 0, app: Self.elsewhere), settings: compiled)
        #expect(processor.process(release(app: Self.elsewhere), settings: compiled) == .perform(Self.rightAction, .once))

        #expect(compiled.needsMotion)
        #expect(!CompiledSettings(.default).needsMotion)
        var disabled = settings
        disabled.general.enabled = false
        #expect(!CompiledSettings(disabled).needsMotion)
    }

    @Test func gesturesRoundTripAndOldMappingsLoadAndSaveAsTheyWere() throws {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .passthrough, gestures: Self.all)]
        let decoded = try SettingsCodec.decode(SettingsCodec.encode(settings))
        #expect(decoded == settings)
        #expect(decoded.repairedWithIssues().issues.isEmpty)

        let old = Data(#"{"trigger":{"type":"button","button":3},"action":{"kind":"none"}}"#.utf8)
        let legacy = try JSONDecoder().decode(Mapping.self, from: old)
        #expect(legacy == Mapping(trigger: .button(3), action: .none))
        #expect(legacy.gestures == nil)
        #expect(!String(decoding: try JSONEncoder().encode(legacy), as: UTF8.self).contains("gestures"))

        func decode(_ json: String) throws -> ButtonGestures { try JSONDecoder().decode(ButtonGestures.self, from: Data(json.utf8)) }
        let sparse = try decode(#"{"left":{"kind":"navigate","direction":"back"}}"#)
        #expect(sparse == ButtonGestures(left: .navigate(.back)))
        #expect(try decode("{}").isEmpty)
    }

    @Test func filesFromBeforeGesturesLoadAsTheyWereAndKeepTheirUnknownKeys() throws {
        let old = """
        {"schemaVersion":1,"future":{"x":[1,true,null]},"profiles":[{"id":"default","mappings":[
        {"trigger":{"type":"button","button":4},"action":{"kind":"navigate","direction":"forward"}}]}]}
        """
        var settings = try SettingsCodec.decodeValidated(Data(old.utf8))
        #expect(settings.defaultProfile.mappings == [Mapping(trigger: .button(4), action: .navigate(.forward))])

        settings.profiles[0].mappings.append(Mapping(trigger: .button(3), action: .passthrough, gestures: Self.all))
        let reloaded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(reloaded == settings)
        #expect(reloaded.defaultProfile.mappings[1].gestures == Self.all)
        #expect(reloaded.unknownKeys["future"] == .object(["x": .array([.number(1), .bool(true), .null])]))
    }

    @Test func repairClampsTheThresholdAndDropsWhatCannotBeAGestureAction() {
        var settings = WhiskerSettings()
        let bad = ButtonGestures(
            up: .click(button: 1, modifiers: []), down: Self.downAction, left: .scroll(direction: .down, lines: 0),
            right: .holdToScroll(HoldScroll()), tap: .passthrough, threshold: 5
        )
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .passthrough, gestures: bad)]
        let (repaired, issues) = settings.repairedWithIssues()
        let path = "profiles[0].mappings[0].gestures"
        #expect(issues.map(\.path) == ["\(path).threshold", "\(path).up", "\(path).left", "\(path).right", "\(path).tap"])
        #expect(repaired.defaultProfile.mappings[0].gestures == ButtonGestures(down: Self.downAction, threshold: ButtonGestures.thresholdRange.lowerBound))
    }

    @Test func gesturesOnAWheelDirectionAreDroppedAndThePrimaryButtonGuardCoversThem() {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .wheel(.left), action: .none, gestures: Self.all)]
        let (repaired, issues) = settings.repairedWithIssues()
        #expect(issues.map(\.path) == ["profiles[0].mappings[0].gestures"])
        #expect(repaired.defaultProfile.mappings == [Mapping(trigger: .wheel(.left), action: .none)])

        let bare = Mapping(trigger: .button(0), action: .passthrough, gestures: Self.all)
        #expect(WhiskerSettings.problem(with: bare, allowPrimary: false) != nil)
        #expect(WhiskerSettings.problem(with: bare, allowPrimary: true) == nil)
        #expect(WhiskerSettings.problem(with: Mapping(trigger: .button(0), modifiers: .command, action: .passthrough, gestures: Self.all), allowPrimary: false) == nil)
        #expect(WhiskerSettings.problem(with: Mapping(trigger: .button(0), action: .passthrough), allowPrimary: false) == nil)
    }

    @Test func onlyActionsThatHappenOnceCanBeGestureActions() {
        let allowed: [Action] = [
            .doubleClick(modifiers: []), .tripleClick(modifiers: .shift),
            .shortcut(KeyShortcut(keyCode: 0x11, modifiers: .command), repeatWhileHeld: false),
            .scroll(direction: .down, lines: 5), .media(.playPause), .media(.volumeUp), .navigate(.back),
            .missionControl(.missionControl), .space(.left), .appSwitch(.next), .open(url: "https://example.com"),
        ]
        let others: [Action] = [
            .passthrough, .none, .click(button: 1, modifiers: []),
            .shortcut(KeyShortcut(keyCode: 0x7E), repeatWhileHeld: true),
            .shortcutSequence([SequenceStep(shortcut: KeyShortcut(keyCode: 0x00, modifiers: .command))]),
            .holdToScroll(HoldScroll()), .autoScroll(AutoScroll()), .slowPointer(factor: 0.5), .clickLock,
            .pointerPreset(deviceID: "046d:b034", presetID: "fast"),
        ]
        // Every kind of action has to be placed on one side or the other.
        #expect(Set((allowed + others).map(\.kind)).count == ActionKind.allCases.count)
        for action in allowed {
            #expect(action.allowedInGestures)
            #expect(WhiskerSettings.problem(withGestureAction: action) == nil)
        }
        for action in others {
            #expect(!action.allowedInGestures)
            #expect(WhiskerSettings.problem(withGestureAction: action) != nil)
        }
        #expect(WhiskerSettings.problem(withGestureAction: .slowPointer(factor: 0.5)) == "Slow pointer while held can't be a gesture action.")
        #expect(WhiskerSettings.problem(withGestureAction: .autoScroll(AutoScroll())) == "Auto-scroll (Experimental) can't be a gesture action.")
        #expect(WhiskerSettings.problem(withGestureAction: .clickLock) == "Click Lock (Experimental) can't be a gesture action.")
    }
}
