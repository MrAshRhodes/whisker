import Testing
@testable import WhiskerCore

@Suite("Action menu")
struct ActionMenuTests {
    @Test func choicesRoundTripWithoutLosingActionFamilies() {
        let choices = ActionMenu.choices
        #expect(Set(choices.map(\.kind)) == Set(ActionKind.allCases))
        #expect(Set(choices).count == choices.count)
        for choice in choices {
            #expect(ActionChoice(choice.defaultAction) == choice)
        }
        for button in 0...2 {
            let choice = ActionChoice(.click(button: button, modifiers: .command))
            #expect(choices.contains(choice))
            #expect(choice.defaultAction == .click(button: button, modifiers: []))
        }
        #expect(ActionChoice(.click(button: 31, modifiers: .option)) == .otherButtonClick)
    }

    @Test func gestureChoicesExcludeHeldActionsAndEmptySections() {
        let sections = ActionMenu.sections { $0.defaultAction.allowedInGestures }
        #expect(sections.allSatisfy { !$0.choices.isEmpty })
        let choices = sections.flatMap(\.choices)
        #expect(!choices.contains(.click(button: 2)))
        #expect(!choices.contains(.family(.holdToScroll)))
        #expect(choices.contains(.navigate(.forward)))
        #expect(choices.contains(.missionControl(.showDesktop)))
    }

    @Test(arguments: [
        Action.clickLock, .slowPointer(factor: 0.5), .holdToScroll(HoldScroll()), .autoScroll(AutoScroll()),
    ])
    func wheelChoiceRestrictionsMatchMappingValidation(action: Action) throws {
        for direction in WheelDirection.allCases {
            let trigger = Trigger.wheel(direction)
            let problem = try #require(WhiskerSettings.problem(with: action, triggeredBy: trigger))
            #expect(WhiskerSettings.problem(with: Mapping(trigger: trigger, action: action), allowPrimary: true) == problem)
            let offered = ActionMenu.sections {
                WhiskerSettings.problem(with: $0.defaultAction, triggeredBy: trigger) == nil
            }.flatMap(\.choices)
            #expect(!offered.contains(ActionChoice(action)))
            #expect(offered.contains(.click(button: 2)))
        }
        #expect(WhiskerSettings.problem(with: action, triggeredBy: .button(3)) == nil)
    }

    @Test func primaryClickLockIsNotOfferedEvenWithPrimaryRemappingEnabled() {
        let trigger = Trigger.button(0)
        #expect(WhiskerSettings.problem(with: .clickLock, triggeredBy: trigger) != nil)
        #expect(WhiskerSettings.problem(with: Mapping(trigger: trigger, action: .clickLock), allowPrimary: true) != nil)
    }

    @Test func enablingGesturesKeepsAnEligibleActionAsTapAndDisablingKeepsEdits() {
        var mapping = Mapping(trigger: .button(3), action: .navigate(.back))
        mapping.setGesturesEnabled(true)
        #expect(mapping.gestures?.tap == .navigate(.back))
        mapping.gestures?.tap = .missionControl(.showDesktop)
        mapping.setGesturesEnabled(true)
        #expect(mapping.gestures?.tap == .missionControl(.showDesktop))
        mapping.setGesturesEnabled(false)
        #expect(mapping.gestures == nil)
        #expect(mapping.action == .missionControl(.showDesktop))
    }

    @Test func togglingGesturesDoesNotLoseAnIneligibleClick() {
        let click = Action.click(button: 2, modifiers: .command)
        var mapping = Mapping(trigger: .button(3), action: click)
        mapping.setGesturesEnabled(true)
        #expect(mapping.gestures != nil)
        #expect(mapping.gestures?.tap == nil)
        mapping.setGesturesEnabled(false)
        #expect(mapping.action == click)
    }

    @Test func wheelCannotEnableGestures() {
        var mapping = Mapping(trigger: .wheel(.down), action: .navigate(.forward))
        mapping.setGesturesEnabled(true)
        #expect(mapping.gestures == nil)
        #expect(mapping.action == .navigate(.forward))
    }
}
