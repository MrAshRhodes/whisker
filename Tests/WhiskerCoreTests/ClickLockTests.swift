import Foundation
import Testing
@testable import WhiskerCore

@Suite("Click Lock")
struct ClickLockTests {
    private static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)
    private static let other = DeviceAttribution(id: "1234:5678", exact: true)
    private static let app = "com.example.app"
    private static let lock = Mapping(trigger: .button(5), action: .clickLock)
    private static let secondLock = Mapping(trigger: .button(6), action: .clickLock)

    private func compiled(
        _ mappings: [Mapping] = [lock], optIn: Bool = true, configure: (inout WhiskerSettings) -> Void = { _ in }
    ) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.general.experimentalClickLock = optIn
        settings.profiles[0].mappings += mappings
        configure(&settings)
        return CompiledSettings(settings)
    }

    private func event(
        _ kind: InputKind, _ modifiers: ModifierSet = [], device: DeviceAttribution? = mouse, app: String? = app
    ) -> InputEvent {
        InputEvent(kind, modifiers: modifiers, device: device, app: app)
    }

    /// A processor whose Click Lock was begun by button 5 and whose trigger has already come up.
    private func locked(_ settings: CompiledSettings, device: DeviceAttribution? = mouse) -> EventProcessor {
        var processor = EventProcessor()
        _ = processor.process(event(.buttonDown(5), device: device), settings: settings)
        _ = processor.process(event(.buttonUp(5), device: device), settings: settings)
        return processor
    }

    // MARK: Press and release

    @Test func twoAssignedPressesMakeOneHoldAndOneRelease() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
        #expect(processor.isClickLockActive)
        #expect(processor.clickLockOwner?.trigger == 5)
        #expect(processor.clickLockOwner?.target == 0)
        // Moving with the trigger still down is movement of the held button, and letting go of it ends nothing.
        #expect(processor.process(event(.buttonDragged(5)), settings: settings) == .dragAs(button: 0, modifiers: []))
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)
        #expect(processor.isClickLockActive)

        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .up))
        #expect(!processor.isClickLockActive)
        #expect(processor.lastClickLockEnd == .assignedPress)
        #expect(processor.process(event(.buttonDragged(5)), settings: settings) == .dragAsMove)
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)

        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
    }

    @Test func aLostTriggerReleaseDoesNotStopTheNextPressFromEndingTheLock() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .up))
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
    }

    @Test func anyAssignedTriggerOnAnyMouseEndsTheLock() {
        var processor = locked(compiled([Self.lock, Self.secondLock]))
        let settings = compiled([Self.lock, Self.secondLock])
        #expect(processor.process(event(.buttonDown(6), device: Self.other), settings: settings) == .perform(.clickLock, .up))
        #expect(!processor.isClickLockActive)
        #expect(processor.process(event(.buttonUp(6), device: Self.other), settings: settings) == .swallow)
    }

    @Test func aClickMappedToThePrimaryButtonLetsGoInsteadOfPressingTwice() {
        let mappings = [
            Self.lock,
            Mapping(trigger: .button(3), action: .click(button: 0, modifiers: [])),
            Mapping(trigger: .button(4), action: .doubleClick(modifiers: [])),
        ]
        let settings = compiled(mappings)
        for button in [3, 4] {
            var processor = locked(settings)
            #expect(processor.process(event(.buttonDown(button)), settings: settings) == .perform(.clickLock, .up))
            #expect(!processor.isClickLockActive)
            #expect(processor.lastClickLockEnd == .mappedPrimaryClick)
            #expect(processor.process(event(.buttonUp(button)), settings: settings) == .swallow)
        }
        var idle = EventProcessor()
        #expect(idle.process(event(.buttonDown(3)), settings: settings) == .perform(.click(button: 0, modifiers: []), .down))
    }

    // MARK: Primary button

    @Test func aPrimaryPressFromAnyMouseEndsTheLockOnceThenPassesThroughUnchanged() {
        let onThePrimary = compiled([Self.lock, Mapping(trigger: .button(0), action: .none)]) { $0.general.allowPrimaryButtonRemap = true }
        let disabledMouse = compiled { $0.devices[Self.other.id] = DeviceSettings(enabled: false) }
        for settings in [compiled(), onThePrimary, disabledMouse] {
            var processor = locked(settings)
            #expect(processor.process(event(.buttonDown(0), device: Self.other), settings: settings) == .performThenPassThrough(.clickLock, .up))
            #expect(!processor.isClickLockActive)
            #expect(processor.lastClickLockEnd == .physicalPrimaryPress)
            #expect(processor.process(event(.buttonDragged(0), device: Self.other), settings: settings) == .passThrough)
            #expect(processor.process(event(.buttonUp(0), device: Self.other), settings: settings) == .passThrough)
            // A later press is an ordinary one again, so the user's own primary mapping applies as it would without a lock.
            var idle = EventProcessor()
            let ordinary = idle.process(event(.buttonDown(0), device: Self.other), settings: settings)
            #expect(processor.process(event(.buttonDown(0), device: Self.other), settings: settings) == ordinary)
        }
    }

    @Test func aPrimaryPressIsLeftAloneWhenThereIsNoLock() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(event(.buttonDown(0)), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .passThrough)
        let cancelled = processor.cancelClickLock(.physicalPrimaryPress)
        #expect(!cancelled)
    }

    @Test func aWheelMappedToAPrimaryClickLetsGoInsteadOfPressingTwice() {
        let settings = compiled([
            Self.lock,
            Mapping(trigger: .wheel(.up), action: .click(button: 0, modifiers: [])),
            Mapping(trigger: .wheel(.left), action: .doubleClick(modifiers: []), continuousInput: ContinuousWheelInput(distance: 80)),
        ])
        let notch = InputEvent(.scroll(ScrollSample(vertical: .lines(1))), timestamp: 1, device: Self.mouse, app: Self.app)
        let nextNotch = InputEvent(.scroll(ScrollSample(vertical: .lines(1))), timestamp: 2, device: Self.mouse, app: Self.app)
        var processor = locked(settings)
        #expect(processor.process(notch, settings: settings) == .perform(.clickLock, .up))
        #expect(processor.lastClickLockEnd == .mappedPrimaryClick)
        #expect(processor.process(nextNotch, settings: settings) == .perform(.click(button: 0, modifiers: []), .once))

        let swipe = InputEvent(
            .scroll(ScrollSample(horizontal: ScrollAxis(lines: 0, fixed: 0, points: 120), isContinuous: true)), device: Self.mouse, app: Self.app
        )
        var baseline = EventProcessor()
        guard case let .performWithScroll(action, _, remaining) = baseline.process(swipe, settings: settings), action.clicksPrimaryButton else {
            Issue.record("the swipe should have fired its mapping")
            return
        }
        var swiping = locked(settings)
        #expect(swiping.process(swipe, settings: settings) == .performWithScroll(.clickLock, .up, remaining: remaining))
        #expect(!swiping.isClickLockActive)
    }

    // MARK: Swapped buttons

    private func swapped() -> CompiledSettings {
        compiled { settings in
            settings.general.allowPrimaryButtonRemap = true
            settings.devices[Self.mouse.id] = DeviceSettings(swapPrimarySecondary: true)
        }
    }

    @Test func onASwappedMouseTheButtonActingAsPrimaryLetsGoInsteadOfPressingTwice() {
        let settings = swapped()
        var processor = locked(settings)
        #expect(processor.process(event(.buttonDown(1)), settings: settings) == .perform(.clickLock, .up))
        #expect(!processor.isClickLockActive)
        #expect(processor.lastClickLockEnd == .mappedPrimaryClick)
        #expect(processor.process(event(.buttonDragged(1)), settings: settings) == .dragAsMove)
        #expect(processor.process(event(.buttonUp(1)), settings: settings) == .swallow)
        // With the lock gone the swap works as it always does.
        let click = Action.click(button: 0, modifiers: [])
        #expect(processor.process(event(.buttonDown(1)), settings: settings) == .perform(click, .down))
        #expect(processor.process(event(.buttonUp(1)), settings: settings) == .perform(click, .up))
    }

    @Test func onASwappedMouseTheFirstButtonStillEndsTheLockAndGoesThroughUnchanged() {
        let settings = swapped()
        var processor = locked(settings)
        #expect(processor.process(event(.buttonDown(0)), settings: settings) == .performThenPassThrough(.clickLock, .up))
        #expect(processor.lastClickLockEnd == .physicalPrimaryPress)
        #expect(processor.process(event(.buttonDragged(0)), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .passThrough)
        #expect(processor.releaseAll().isEmpty)
    }

    @Test func startingIsRefusedWhileASwappedPressIsDown() {
        let settings = swapped()
        for button in [0, 1] {
            var processor = EventProcessor()
            _ = processor.process(event(.buttonDown(button)), settings: settings)
            #expect(processor.process(event(.buttonDown(5)), settings: settings) == .swallow)
            #expect(!processor.isClickLockActive)
            #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)
            // The swapped press still ends with its one release.
            let released = processor.process(event(.buttonUp(button)), settings: settings)
            #expect(released == .perform(.click(button: 1 - button, modifiers: []), .up))
            #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
        }
    }

    // MARK: Ownership conflicts

    @Test func startingIsRefusedWhileAnotherButtonIsDownAndItsPressAndReleaseAreIgnored() {
        let settings = compiled([
            Self.lock,
            Mapping(trigger: .button(2), action: .click(button: 1, modifiers: [])),
            Mapping(trigger: .button(7), action: .holdToScroll(HoldScroll())),
        ])
        let holdPress = InputEvent(.buttonDown(7), device: Self.mouse, app: Self.app, location: PointerPoint(x: 10, y: 10))
        let busy: [(String, (inout EventProcessor) -> Void)] = [
            ("a button that went through", { _ = $0.process(self.event(.buttonDown(1)), settings: settings) }),
            ("the primary button", { _ = $0.process(self.event(.buttonDown(0)), settings: settings) }),
            ("a held click", { _ = $0.process(self.event(.buttonDown(2)), settings: settings) }),
            ("a hold to scroll", { _ = $0.process(holdPress, settings: settings) }),
            ("a button left over from standing aside", { processor in
                _ = processor.process(self.event(.buttonDown(2)), settings: settings)
                _ = processor.releaseAllForBypass()
            }),
        ]
        for (reason, makeBusy) in busy {
            var processor = EventProcessor()
            makeBusy(&processor)
            #expect(processor.process(event(.buttonDown(5)), settings: settings) == .swallow, "\(reason)")
            #expect(!processor.isClickLockActive, "\(reason)")
            #expect(processor.process(event(.buttonDragged(5)), settings: settings) == .dragAsMove, "\(reason)")
            #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow, "\(reason)")
        }
    }

    @Test func startingWorksAgainOnceTheOtherButtonIsUp() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(event(.buttonDown(1)), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .swallow)
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)
        #expect(processor.process(event(.buttonUp(1)), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
    }

    @Test func aPressTheTapHeldBackCannotStartALockButCanEndOne() {
        var processor = EventProcessor()
        let settings = compiled()
        #expect(processor.process(event(.buttonDown(5)), settings: settings, startsClickLock: false) == .swallow)
        #expect(!processor.isClickLockActive)
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)

        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
        #expect(processor.process(event(.buttonDown(5)), settings: settings, startsClickLock: false) == .perform(.clickLock, .up))
        #expect(!processor.isClickLockActive)
    }

    // MARK: Slowing the pointer

    @Test func aPrimaryPressStillEndsTheLockWhenThePrimaryButtonSlowsThePointer() {
        let settings = compiled([Self.lock, Mapping(trigger: .button(0), action: .slowPointer(factor: 0.5))]) {
            $0.general.allowPrimaryButtonRemap = true
        }
        let slowable: Set<String> = [Self.mouse.id]
        var processor = locked(settings)
        #expect(processor.process(event(.buttonDown(0)), settings: settings, slowPointerDevices: slowable) == .performThenPassThrough(.clickLock, .up))
        #expect(!processor.isClickLockActive)
        #expect(processor.slowPointerCommand.factors.isEmpty)
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .passThrough)
        // With the lock gone the same press slows the pointer, as mapped.
        #expect(processor.process(event(.buttonDown(0)), settings: settings, slowPointerDevices: slowable) == .swallow)
        #expect(processor.slowPointerCommand.factors == [Self.mouse.id: 0.5])
    }

    @Test func movementWhileSlowingAndLockedIsStillADragOfThePrimaryButton() {
        let settings = compiled([Self.lock, Mapping(trigger: .button(3), action: .slowPointer(factor: 0.5))])
        var processor = locked(settings)
        #expect(processor.process(event(.buttonDown(3)), settings: settings, slowPointerDevices: [Self.mouse.id]) == .swallow)
        #expect(processor.process(event(.buttonDragged(3)), settings: settings) == .dragAs(button: 0, modifiers: []))
        #expect(processor.process(event(.buttonUp(3)), settings: settings) == .swallow)
        #expect(processor.isClickLockActive)
        #expect(processor.slowPointerCommand.factors.isEmpty)
    }

    @Test func aSlowPointerPressThatWentThroughKeepsALockFromStartingUntilItIsReleased() {
        let settings = compiled([Self.lock, Mapping(trigger: .button(3), action: .slowPointer(factor: 0.5))])
        var processor = EventProcessor()
        // No mouse can be slowed here, so the press reaches the app like any other and is down until released.
        #expect(processor.process(event(.buttonDown(3)), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .swallow)
        #expect(!processor.isClickLockActive)
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)
        #expect(processor.process(event(.buttonUp(3)), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
    }

    // MARK: Auto-scroll

    @Test func aPressThatStartsALockEndsARunningAutoScrollFirst() {
        let settings = compiled([Self.lock, Mapping(trigger: .button(3), action: .autoScroll(AutoScroll()))])
        var processor = EventProcessor()
        let start = InputEvent(.buttonDown(3), device: Self.mouse, app: Self.app, location: PointerPoint(x: 400, y: 300))
        #expect(processor.process(start, settings: settings) == .swallow)
        #expect(processor.autoScrollSession != nil)
        #expect(processor.process(event(.buttonUp(3)), settings: settings) == .swallow)
        // Any press ends an auto-scroll, and this one then starts the lock as it would have anyway.
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
        #expect(processor.autoScrollSession == nil)
        #expect(processor.isClickLockActive)
    }

    @Test func anAutoScrollCannotStartWhileALockIsHeldUntilItIsReleased() {
        let settings = compiled([Self.lock, Mapping(trigger: .button(3), action: .autoScroll(AutoScroll()))])
        let start = InputEvent(.buttonDown(3), device: Self.mouse, app: Self.app, location: PointerPoint(x: 400, y: 300))
        var processor = locked(settings)
        #expect(processor.process(start, settings: settings) == .swallow)
        #expect(processor.autoScrollSession == nil)
        #expect(processor.process(event(.buttonUp(3)), settings: settings) == .swallow)
        #expect(processor.isClickLockActive)

        #expect(processor.process(event(.buttonDown(0)), settings: settings) == .performThenPassThrough(.clickLock, .up))
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .passThrough)
        #expect(processor.process(start, settings: settings) == .swallow)
        #expect(processor.autoScrollSession != nil)
    }

    // MARK: Gestures

    private static let swipeRight = Action.navigate(.forward)
    private static let gestures = ButtonGestures(right: swipeRight, threshold: 100)
    private static let gestureButton = Mapping(trigger: .button(3), action: .passthrough, gestures: gestures)

    /// A drag of a held button carrying one event's movement.
    private func drag(_ dx: Int, _ dy: Int, button: Int = 3) -> InputEvent {
        InputEvent(.buttonDragged(button), device: Self.mouse, app: Self.app, motion: PointerMotion(dx: dx, dy: dy), motionDevice: Self.mouse)
    }

    @Test func aGestureButtonPressedWhileLockedIsSwallowedAndNeverStartsAGesture() {
        let settings = compiled([Self.lock, Self.gestureButton])
        var processor = locked(settings)
        #expect(processor.process(event(.buttonDown(3)), settings: settings) == .swallow)
        #expect(!processor.isRecognisingGesture)
        // Its movement is still a drag of the locked primary button, and moving far enough performs nothing.
        #expect(processor.process(drag(150, 0), settings: settings) == .dragAs(button: 0, modifiers: []))
        #expect(processor.process(event(.buttonUp(3)), settings: settings) == .swallow)
        #expect(processor.isClickLockActive)

        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .up))
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)
        // With the lock gone the same button recognises a gesture again.
        #expect(processor.process(event(.buttonDown(3)), settings: settings) == .swallow)
        #expect(processor.isRecognisingGesture)
        _ = processor.process(drag(150, 0), settings: settings)
        #expect(processor.process(event(.buttonUp(3)), settings: settings) == .perform(Self.swipeRight, .once))
    }

    @Test func aLockTriggerPressedDuringAGestureIsRefusedAndTheGestureStillCompletes() {
        let settings = compiled([Self.lock, Self.gestureButton])
        var processor = EventProcessor()
        #expect(processor.process(event(.buttonDown(3)), settings: settings) == .swallow)
        #expect(processor.isRecognisingGesture)
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .swallow)
        #expect(!processor.isClickLockActive)
        #expect(processor.process(drag(150, 0), settings: settings) == .dragAsMove)
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)
        #expect(processor.process(event(.buttonUp(3)), settings: settings) == .perform(Self.swipeRight, .once))
        #expect(!processor.isClickLockActive)
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
    }

    @Test func aMappingThatCarriesGesturesNeverStartsALockWhateverItsOwnActionIs() {
        // The editor stores a gesture mapping as Pass Through; only a hand-edited file can pair gestures with this.
        let settings = compiled([Mapping(trigger: .button(5), action: .clickLock, gestures: Self.gestures)])
        #expect(!settings.needsClickLock)
        var processor = EventProcessor()
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .swallow)
        #expect(processor.isRecognisingGesture)
        #expect(!processor.isClickLockActive)
        _ = processor.process(drag(150, 0, button: 5), settings: settings)
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .perform(Self.swipeRight, .once))
        #expect(!processor.isClickLockActive)
    }

    // MARK: Cancellation

    @Test func cancellingAndReleasingNeverAskForASecondRelease() {
        let settings = compiled()
        var processor = locked(settings)
        let first = processor.cancelClickLock(.disabled)
        let second = processor.cancelClickLock(.disabled)
        let third = processor.cancelClickLock(.tapInterrupted)
        #expect(first && !second && !third)
        #expect(processor.releaseAll().isEmpty)
        #expect(processor.releaseAllForBypass().isEmpty)
        #expect(processor.lastClickLockEnd == .disabled)
        let stale = processor.releaseStaleClickLock(app: "com.example.other", settings: settings)
        #expect(!stale)

        var sleeping = locked(settings)
        let released = sleeping.releaseAll(because: .sleep)
        #expect(released.map(\.button) == [5])
        #expect(released.map(\.action) == [.clickLock])
        #expect(sleeping.lastClickLockEnd == .sleep)
        #expect(sleeping.releaseAll(because: .quit).isEmpty)
        let late = sleeping.cancelClickLock(.permissionLoss)
        #expect(!late)

        var standingAside = locked(settings)
        #expect(standingAside.releaseAllForBypass().map(\.action) == [.clickLock])
        #expect(standingAside.lastClickLockEnd == .applicationChanged)
    }

    @Test func workQueuedBehindACancelCannotBringTheLockBack() {
        let settings = compiled()
        var processor = EventProcessor()
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
        let cancelled = processor.cancelClickLock(.deviceDisconnected)
        #expect(cancelled)
        // The trigger is still physically down: its movement and release are ignored and nothing is held again.
        #expect(processor.process(event(.buttonDragged(5)), settings: settings) == .dragAsMove)
        #expect(processor.process(event(.buttonUp(5)), settings: settings) == .swallow)
        #expect(!processor.isClickLockActive)
        #expect(processor.process(event(.buttonDown(0)), settings: settings) == .passThrough)
    }

    @Test func releasingEverythingForgetsButtonsThatWentThrough() {
        let settings = compiled()
        var processor = EventProcessor()
        #expect(processor.process(event(.buttonDown(1)), settings: settings) == .passThrough)
        #expect(processor.releaseAll().isEmpty)
        #expect(processor.process(event(.buttonDown(5)), settings: settings) == .perform(.clickLock, .down))
    }

    @Test func aDisconnectEndsTheLockUnlessItsMouseIsStillThere() {
        let settings = compiled()
        var processor = locked(settings)
        let stillThere = processor.cancelClickLock(unlessConnected: [Self.mouse.id, Self.other.id])
        #expect(!stillThere)
        #expect(processor.isClickLockActive)
        let gone = processor.cancelClickLock(unlessConnected: [Self.other.id])
        #expect(gone)
        #expect(processor.lastClickLockEnd == .deviceDisconnected)
        let again = processor.cancelClickLock(unlessConnected: [])
        #expect(!again)
    }

    @Test(arguments: [nil, DeviceAttribution(id: "046d:c52b", exact: false)])
    func aLockTheTapCouldNotAttributeEndsOnAnyChangeOfMice(device: DeviceAttribution?) {
        var processor = locked(compiled(), device: device)
        let cancelled = processor.cancelClickLock(unlessConnected: [Self.mouse.id, Self.other.id])
        #expect(cancelled)
        #expect(!processor.isClickLockActive)
    }

    // MARK: Context changes

    @Test func theLockEndsWhenWhatItBeganUnderHasGone() throws {
        let begun = compiled()
        let appProfile = Profile(id: "app", name: "App", match: ProfileMatch(apps: [Self.app]), inherits: nil, mappings: [Self.lock])
        let cases: [(String, String?, CompiledSettings, ClickLockEnd?)] = [
            ("nothing changed", Self.app, begun, nil),
            ("the app in front changed", "com.example.other", begun, .applicationChanged),
            ("the app in front is bypassed", Self.app, compiled { $0.general.bypassApps = [Self.app] }, .applicationChanged),
            ("Whisker was turned off", Self.app, compiled { $0.general.enabled = false }, .disabled),
            ("the opt-in was turned off", Self.app, compiled(optIn: false), .disabled),
            ("the trigger lost its mapping", Self.app, compiled([]), .settingsChanged),
            ("the trigger now does something else", Self.app, compiled([Mapping(trigger: .button(5), action: .none)]), .settingsChanged),
            ("a profile began to apply", Self.app, compiled { $0.profiles.append(appProfile) }, .profileChanged),
        ]
        for (reason, app, settings, expected) in cases {
            var processor = locked(begun)
            let ended = processor.releaseStaleClickLock(app: app, settings: settings)
            #expect(ended == (expected != nil), "\(reason)")
            #expect(processor.isClickLockActive == (expected == nil), "\(reason)")
            if let expected { #expect(processor.lastClickLockEnd == expected, "\(reason)") }
            #expect(!processor.releaseStaleClickLock(app: app, settings: settings) || expected == nil, "\(reason)")
        }
    }

    // MARK: Inert

    @Test func clickLockDoesNothingUnlessSwitchedOnAndAssignedToAButton() {
        let cases: [(String, CompiledSettings, InputEvent)] = [
            ("the opt-in is off", compiled(optIn: false), event(.buttonDown(5))),
            ("Whisker is off", compiled { $0.general.enabled = false }, event(.buttonDown(5))),
            ("the app is bypassed", compiled { $0.general.bypassApps = [Self.app] }, event(.buttonDown(5))),
            ("the mouse is turned off", compiled { $0.devices[Self.mouse.id] = DeviceSettings(enabled: false) }, event(.buttonDown(5))),
            (
                "the trigger is the primary button",
                compiled([Mapping(trigger: .button(0), action: .clickLock)]) { $0.general.allowPrimaryButtonRemap = true },
                event(.buttonDown(0))
            ),
            (
                "the trigger is the primary button with a modifier",
                compiled([Mapping(trigger: .button(0), modifiers: .command, action: .clickLock)]),
                event(.buttonDown(0), .command)
            ),
        ]
        for (reason, settings, press) in cases {
            var processor = EventProcessor()
            #expect(processor.process(press, settings: settings) == .passThrough, "\(reason)")
            #expect(!processor.isClickLockActive, "\(reason)")
        }
    }

    @Test func aWheelMappedToClickLockScrollsAsItWould() {
        let notch = event(.scroll(ScrollSample(vertical: .lines(1))))
        let smooth = event(.scroll(ScrollSample(horizontal: ScrollAxis(lines: 0, fixed: 0, points: 120), isContinuous: true)))
        let settings = compiled([
            Mapping(trigger: .wheel(.up), action: .clickLock),
            Mapping(trigger: .wheel(.left), action: .clickLock, continuousInput: ContinuousWheelInput(distance: 80)),
        ])
        let unmapped = compiled([])
        for input in [notch, smooth] {
            var processor = EventProcessor()
            var baseline = EventProcessor()
            #expect(processor.process(input, settings: settings) == baseline.process(input, settings: unmapped))
            #expect(!processor.isClickLockActive)
        }
    }

    @Test func onlyAnOptedInButtonMappingPreparesTheApp() {
        #expect(compiled().needsClickLock)
        #expect(!compiled(optIn: false).needsClickLock)
        #expect(!compiled { $0.general.enabled = false }.needsClickLock)
        #expect(!compiled([]).needsClickLock)
        #expect(!compiled([Mapping(trigger: .button(0), action: .clickLock)]).needsClickLock)
        #expect(!compiled([Mapping(trigger: .wheel(.up), action: .clickLock)]).needsClickLock)
    }

    @Test func theLockReleaseCallsOffAClickGesture() {
        #expect(ClickInterruption.isCalledOffBy(.buttonDown(0), plan: .performThenPassThrough(.clickLock, .up)))
    }

    // MARK: Ownership record

    @Test func theLockIsOwnedByOneStartAndEndsOnce() throws {
        var lock = ClickLock()
        let began = lock.begin(device: Self.mouse, trigger: 5, app: Self.app, profile: "default")
        let started = try #require(began)
        #expect(started.target == 0)
        #expect(lock.begin(device: Self.other, trigger: 6, app: "com.example.other", profile: "other") == nil)
        #expect(lock.owner == started)
        #expect(lock.end(.menu) == started)
        #expect(lock.end(.menu) == nil)
        #expect(lock.end(.quit) == nil)
        #expect(lock.lastEnd == .menu)
        #expect(!lock.isActive)
    }

    @Test func workQueuedForAnEarlierLockCanTellItIsStale() throws {
        var lock = ClickLock()
        let beganFirst = lock.begin(device: nil, trigger: 5, app: nil, profile: "default")
        let first = try #require(beganFirst)
        #expect(lock.isCurrent(first.generation))
        lock.end(.assignedPress)
        #expect(!lock.isCurrent(first.generation))
        let beganSecond = lock.begin(device: nil, trigger: 5, app: nil, profile: "default")
        let second = try #require(beganSecond)
        #expect(second.generation != first.generation)
        #expect(!lock.isCurrent(first.generation))
        #expect(lock.isCurrent(second.generation))
    }

    // MARK: Settings

    @Test func clickLockCodesAsItsOwnKindAndIgnoresExtraKeys() throws {
        func decode(_ json: String) throws -> Action { try JSONDecoder().decode(Action.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"kind":"clickLock"}"#) == .clickLock)
        #expect(try decode(#"{"kind":"clickLock","modifiers":["shift"],"target":"secondary"}"#) == .clickLock)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Action.clickLock)) as? [String: String]
        #expect(written == ["kind": "clickLock"])
    }

    @Test func filesFromBeforeClickLockLoadAsTheyWereAndKeepTheirUnknownKeys() throws {
        let old = """
        {"schemaVersion":1,"general":{"enabled":true,"allowPrimaryButtonRemap":false},"future":{"x":[1,true,null]},"profiles":[{"id":"default","mappings":[
        {"trigger":{"type":"button","button":3},"action":{"kind":"navigate","direction":"back"}}]}]}
        """
        var settings = try SettingsCodec.decodeValidated(Data(old.utf8))
        #expect(!settings.general.experimentalClickLock)
        #expect(settings.defaultProfile.mappings == [Mapping(trigger: .button(3), action: .navigate(.back))])

        settings.general.experimentalClickLock = true
        settings.profiles[0].mappings.append(Self.lock)
        let reloaded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(reloaded == settings)
        #expect(reloaded.general.experimentalClickLock)
        #expect(reloaded.unknownKeys["future"] == .object(["x": .array([.number(1), .bool(true), .null])]))
    }

    @Test func clickLockNeedsAButtonThatIsNotThePrimary() {
        for allowPrimary in [false, true] {
            for modifiers in [ModifierSet(), .command] {
                let primary = Mapping(trigger: .button(0), modifiers: modifiers, action: .clickLock)
                let problem = WhiskerSettings.problem(with: primary, allowPrimary: allowPrimary)
                #expect(problem?.contains("primary button") == true)
            }
            let wheel = Mapping(trigger: .wheel(.up), action: .clickLock)
            #expect(WhiskerSettings.problem(with: wheel, allowPrimary: allowPrimary)?.contains("mouse button") == true)
            #expect(WhiskerSettings.problem(with: Self.lock, allowPrimary: allowPrimary) == nil)
            #expect(WhiskerSettings.problem(with: Mapping(trigger: .button(5), modifiers: .shift, action: .clickLock), allowPrimary: allowPrimary) == nil)
        }
        var settings = WhiskerSettings()
        settings.profiles[0].mappings.append(Mapping(trigger: .button(0), modifiers: .command, action: .clickLock))
        #expect(settings.validate().count == 1)
        #expect(settings.repairedWithIssues().settings.defaultProfile.mappings.allSatisfy { $0.action != .clickLock })
    }
}
