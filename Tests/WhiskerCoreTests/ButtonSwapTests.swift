import Foundation
import Testing
@testable import WhiskerCore

@Suite("Button swap")
struct ButtonSwapTests {
    private static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)
    private static let other = DeviceAttribution(id: "1234:abcd", exact: true)
    private static let app = "com.example.app"
    private static let editor = "com.example.editor"

    private let leftClick = Action.click(button: 0, modifiers: [])
    private let rightClick = Action.click(button: 1, modifiers: [])

    /// Settings with the swap on for `mouse` and the primary button allowed to be remapped, which the swap needs.
    private func swapping(_ configure: (inout WhiskerSettings) -> Void = { _ in }) -> CompiledSettings {
        CompiledSettings(swappingSettings(configure))
    }

    private func swappingSettings(_ configure: (inout WhiskerSettings) -> Void = { _ in }) -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.general.allowPrimaryButtonRemap = true
        settings.devices[Self.mouse.id] = DeviceSettings(swapPrimarySecondary: true)
        configure(&settings)
        return settings
    }

    private func event(_ kind: InputKind, _ modifiers: ModifierSet = [], device: DeviceAttribution? = mouse, app: String? = app) -> InputEvent {
        InputEvent(kind, modifiers: modifiers, timestamp: 0, device: device, app: app)
    }

    // MARK: Pressing

    @Test func aSwappedMouseDeliversTheOtherButtonForTheWholeClickAndDrag() {
        var processor = EventProcessor()
        let settings = swapping()
        #expect(processor.process(event(.buttonDown(0)), settings: settings) == .perform(rightClick, .down))
        #expect(processor.process(event(.buttonDragged(0)), settings: settings) == .dragAs(button: 1, modifiers: []))
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .perform(rightClick, .up))
        #expect(processor.process(event(.buttonDown(1)), settings: settings) == .perform(leftClick, .down))
        #expect(processor.process(event(.buttonDragged(1)), settings: settings) == .dragAs(button: 0, modifiers: []))
        #expect(processor.process(event(.buttonUp(1)), settings: settings) == .perform(leftClick, .up))
        // The release was its own, so nothing is left over to catch the next one.
        #expect(processor.process(event(.buttonUp(1)), settings: settings) == .passThrough)
    }

    @Test func otherButtonsAndModifiedClicksAreLeftAlone() {
        var processor = EventProcessor()
        let settings = swapping()
        #expect(processor.process(event(.buttonDown(2)), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonUp(2)), settings: settings) == .passThrough)
        for modifiers: ModifierSet in [.command, .shift, .option, .control, [.control, .shift]] {
            for button in [0, 1] {
                #expect(processor.process(event(.buttonDown(button), modifiers), settings: settings) == .passThrough)
                #expect(processor.process(event(.buttonUp(button)), settings: settings) == .passThrough)
            }
        }
        // Some keyboards set the Function key on arrow keys; it is no modifier for a click.
        #expect(processor.process(event(.buttonDown(0), .function), settings: settings) == .perform(rightClick, .down))
    }

    @Test func theSwapNeedsAnExactAttributionToAMouseThatIsSetToSwap() {
        var processor = EventProcessor()
        let settings = swapping()
        let guessed = DeviceAttribution(id: Self.mouse.id, exact: false)
        let trackpad = DeviceAttribution(id: Self.mouse.id, exact: true, isExcluded: true)
        for device in [guessed, trackpad, Self.other, nil] {
            #expect(processor.process(event(.buttonDown(0), device: device), settings: settings) == .passThrough)
            #expect(processor.process(event(.buttonUp(0), device: device), settings: settings) == .passThrough)
        }
    }

    @Test func nothingIsSwappedWhileWhiskerTheMouseOrTheAppStandsAside() {
        var processor = EventProcessor()
        let standingAside = [
            swapping { $0.general.enabled = false },
            swapping { $0.devices[Self.mouse.id]?.enabled = false },
            swapping { $0.general.bypassApps = [Self.app] },
        ]
        for settings in standingAside {
            #expect(processor.process(event(.buttonDown(0)), settings: settings) == .passThrough)
            #expect(processor.process(event(.buttonUp(0)), settings: settings) == .passThrough)
        }
    }

    @Test func theSwapNeverTurnsOnPrimaryButtonRemappingItself() {
        var processor = EventProcessor()
        let notAllowed = swapping { $0.general.allowPrimaryButtonRemap = false }
        #expect(processor.process(event(.buttonDown(0)), settings: notAllowed) == .passThrough)
        #expect(processor.process(event(.buttonUp(0)), settings: notAllowed) == .passThrough)
        #expect(processor.process(event(.buttonDown(1)), settings: notAllowed) == .passThrough)
        #expect(processor.process(event(.buttonUp(1)), settings: notAllowed) == .passThrough)
    }

    // MARK: Mappings in the way

    @Test func aMappingOnThePlainPrimaryOrSecondaryButtonKeepsTheWholeSwapOut() {
        let secondary = Mapping(trigger: .button(1), action: .space(.left))
        let scenes: [(name: String, configure: (inout WhiskerSettings) -> Void, primary: EventPlan, secondary: EventPlan)] = [
            ("the default profile maps the secondary button", { $0.profiles[0].mappings.append(secondary) }, .passThrough, .perform(.space(.left), .once)),
            ("an explicit Pass Through counts as a mapping", { $0.profiles[0].mappings.append(Mapping(trigger: .button(0), action: .passthrough)) }, .passThrough, .passThrough),
            (
                "a profile for the mouse maps the primary button",
                { $0.profiles.append(Profile(name: "Mouse", match: ProfileMatch(devices: [Self.mouse.id]), mappings: [Mapping(trigger: .button(0), action: .click(button: 2, modifiers: []))])) },
                .perform(.click(button: 2, modifiers: []), .down), .passThrough
            ),
        ]
        for scene in scenes {
            var pressingPrimary = EventProcessor()
            #expect(pressingPrimary.process(event(.buttonDown(0)), settings: swapping(scene.configure)) == scene.primary, "\(scene.name): primary")
            var pressingSecondary = EventProcessor()
            #expect(pressingSecondary.process(event(.buttonDown(1)), settings: swapping(scene.configure)) == scene.secondary, "\(scene.name): secondary")
        }
    }

    @Test func aProfileForOneAppKeepsTheSwapOutOfThatAppOnly() {
        var processor = EventProcessor()
        let settings = swapping {
            $0.profiles.append(Profile(name: "Editor", match: ProfileMatch(apps: [Self.editor]), mappings: [Mapping(trigger: .button(1), action: .space(.right))]))
        }
        #expect(processor.process(event(.buttonDown(0), app: Self.editor), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonDown(1), app: Self.editor), settings: settings) == .perform(.space(.right), .once))
        #expect(processor.process(event(.buttonDown(0), app: Self.app), settings: settings) == .perform(rightClick, .down))
        // What an app's profile inherits counts too.
        let inheriting = swapping {
            $0.profiles[0].mappings.append(Mapping(trigger: .button(1), action: .space(.left)))
            $0.profiles.append(Profile(name: "Editor", match: ProfileMatch(apps: [Self.editor])))
        }
        var inherited = EventProcessor()
        #expect(inherited.process(event(.buttonDown(0), app: Self.editor), settings: inheriting) == .passThrough)
    }

    @Test func aMappingOnAModifiedClickDoesNotKeepTheSwapOut() {
        var processor = EventProcessor()
        let settings = swapping { $0.profiles[0].mappings.append(Mapping(trigger: .button(0), modifiers: .command, action: .space(.left))) }
        #expect(processor.process(event(.buttonDown(0)), settings: settings) == .perform(rightClick, .down))
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .perform(rightClick, .up))
        #expect(processor.process(event(.buttonDown(0), .command), settings: settings) == .perform(.space(.left), .once))
    }

    // MARK: A press keeps its own outcome

    @Test func aReleaseFollowsItsPressWhateverTheSettingsSayByThen() {
        var processor = EventProcessor()
        let on = swapping()
        let off = swapping { $0.devices[Self.mouse.id]?.swapPrimarySecondary = false }
        let notAllowed = swapping { $0.general.allowPrimaryButtonRemap = false }
        let aside = swapping { $0.general.bypassApps = [Self.app] }

        #expect(processor.process(event(.buttonDown(0)), settings: on) == .perform(rightClick, .down))
        #expect(processor.process(event(.buttonDragged(0)), settings: off) == .dragAs(button: 1, modifiers: []))
        #expect(processor.process(event(.buttonUp(0)), settings: off) == .perform(rightClick, .up))

        #expect(processor.process(event(.buttonDown(1)), settings: on) == .perform(leftClick, .down))
        #expect(processor.process(event(.buttonUp(1)), settings: notAllowed) == .perform(leftClick, .up))

        #expect(processor.process(event(.buttonDown(0)), settings: on) == .perform(rightClick, .down))
        #expect(processor.process(event(.buttonUp(0)), settings: aside) == .perform(rightClick, .up))

        // A press that was not swapped is not released as the other button when the swap comes on under it.
        #expect(processor.process(event(.buttonDown(0)), settings: off) == .passThrough)
        #expect(processor.process(event(.buttonDragged(0)), settings: on) == .passThrough)
        #expect(processor.process(event(.buttonUp(0)), settings: on) == .passThrough)
    }

    @Test func aPressThatLostItsReleaseIsReplacedByTheNextOne() {
        var processor = EventProcessor()
        let settings = swapping()
        _ = processor.process(event(.buttonDown(0)), settings: settings)
        #expect(processor.process(event(.buttonDown(0)), settings: settings) == .perform(rightClick, .down))
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .perform(rightClick, .up))
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .passThrough)
    }

    @Test func twoMiceHoldingTheSameButtonEachGetTheirOwnRelease() {
        var processor = EventProcessor()
        let settings = swapping { $0.devices[Self.other.id] = DeviceSettings(swapPrimarySecondary: true) }
        let unswapped = DeviceAttribution(id: "9999:0001", exact: true)
        #expect(processor.process(event(.buttonDown(0), device: Self.mouse), settings: settings) == .perform(rightClick, .down))
        #expect(processor.process(event(.buttonDown(0), device: Self.other), settings: settings) == .perform(rightClick, .down))
        #expect(processor.process(event(.buttonDown(0), device: unswapped), settings: settings) == .passThrough)
        // The mouse that was not swapped keeps its own release.
        #expect(processor.process(event(.buttonUp(0), device: unswapped), settings: settings) == .passThrough)
        #expect(processor.process(event(.buttonUp(0), device: Self.other), settings: settings) == .perform(rightClick, .up))
        // A release that isn't attributed ends the press that is left, and each press ends only once.
        #expect(processor.process(event(.buttonUp(0), device: nil), settings: settings) == .perform(rightClick, .up))
        #expect(processor.process(event(.buttonUp(0), device: nil), settings: settings) == .passThrough)
    }

    @Test(arguments: [false, true])
    func mappedAndSwappedPressesOfTheSameButtonKeepTheirOwnDragsAndReleases(delayedRelease: Bool) {
        for action in [Action.none, .click(button: 2, modifiers: .command)] {
            for swappedFirst in [false, true] {
                for swappedReleasedFirst in [false, true] {
                    var processor = EventProcessor()
                    let settings = swapping {
                        $0.profiles.append(Profile(
                            name: "Other", match: ProfileMatch(devices: [Self.other.id]),
                            mappings: [Mapping(trigger: .button(0), action: action)]
                        ))
                    }
                    for device in swappedFirst ? [Self.mouse, Self.other] : [Self.other, Self.mouse] {
                        let expected: EventPlan = device == Self.mouse ? .perform(rightClick, .down)
                            : action == .none ? .swallow : .perform(action, .down)
                        #expect(processor.process(event(.buttonDown(0), device: device), settings: settings) == expected)
                    }
                    #expect(processor.process(event(.buttonDragged(0), device: Self.mouse), settings: settings) == .dragAs(button: 1, modifiers: []))
                    let mappedDrag: EventPlan = action == .none ? .dragAsMove : .dragAs(button: 2, modifiers: .command)
                    #expect(processor.process(event(.buttonDragged(0), device: Self.other), settings: settings) == mappedDrag)
                    let first = swappedReleasedFirst ? Self.mouse : Self.other
                    let firstPlan: EventPlan = swappedReleasedFirst ? .perform(rightClick, .up)
                        : action == .none ? .swallow : .perform(action, .up)
                    #expect(processor.process(event(.buttonUp(0), device: first), settings: settings) == firstPlan)
                    // A delayed tail falls back only once the other mouse has released.
                    let lastPlan: EventPlan = swappedReleasedFirst
                        ? (action == .none ? .swallow : .perform(action, .up)) : .perform(rightClick, .up)
                    let lastDevice = delayedRelease ? nil : (swappedReleasedFirst ? Self.other : Self.mouse)
                    let lastDrag: EventPlan = swappedReleasedFirst ? mappedDrag : .dragAs(button: 1, modifiers: [])
                    #expect(processor.process(event(.buttonDragged(0), device: lastDevice), settings: settings) == lastDrag)
                    #expect(processor.process(event(.buttonUp(0), device: lastDevice), settings: settings) == lastPlan)
                    #expect(processor.heldButtons.isEmpty)
                    #expect(processor.releaseAll().isEmpty)
                }
            }
        }
    }

    @Test func anUnrelatedExactOrAmbiguousTailCannotConsumeAnOverlappingMappedOrSwappedPress() {
        var processor = EventProcessor()
        let settings = swapping {
            $0.profiles.append(Profile(
                name: "Other", match: ProfileMatch(devices: [Self.other.id]),
                mappings: [Mapping(trigger: .button(0), action: .none)]
            ))
        }
        _ = processor.process(event(.buttonDown(0), device: Self.mouse), settings: settings)
        _ = processor.process(event(.buttonDown(0), device: Self.other), settings: settings)
        for device in [nil, DeviceAttribution(id: Self.mouse.id, exact: false), DeviceAttribution(id: "unrelated", exact: true)] {
            #expect(processor.process(event(.buttonDragged(0), device: device), settings: settings) == .passThrough)
            #expect(processor.process(event(.buttonUp(0), device: device), settings: settings) == .passThrough)
        }
        #expect(processor.process(event(.buttonUp(0), device: Self.mouse), settings: settings) == .perform(rightClick, .up))
        #expect(processor.process(event(.buttonUp(0), device: Self.other), settings: settings) == .swallow)
        #expect(processor.releaseAll().isEmpty)
    }

    // MARK: Cleanup

    @Test func standingDownFinishesASwappedPressAndSwallowsItsRealRelease() {
        var processor = EventProcessor()
        let settings = swapping()
        _ = processor.process(event(.buttonDown(0)), settings: settings)
        let released = processor.releaseAll()
        #expect(released.map(\.button) == [0])
        #expect(released.map(\.action) == [rightClick])
        #expect(processor.process(event(.buttonDragged(0)), settings: settings) == .dragAsMove)
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .swallow)
        #expect(processor.process(event(.buttonUp(0)), settings: settings) == .passThrough)
        #expect(processor.releaseAll().isEmpty)
    }

    @Test func standingAsideForAnAppFinishesASwappedPressAndKeepsItSwallowed() {
        var processor = EventProcessor()
        let settings = swapping()
        _ = processor.process(event(.buttonDown(1)), settings: settings)
        _ = processor.process(event(.buttonDown(3)), settings: settings)
        let released = processor.releaseAllForBypass()
        #expect(released.map(\.button) == [1])
        #expect(released.map(\.action) == [leftClick])
        #expect(processor.process(event(.buttonDragged(1)), settings: settings) == .dragAsMove)
        #expect(processor.process(event(.buttonUp(1)), settings: settings) == .swallow)
        #expect(processor.process(event(.buttonUp(1)), settings: settings) == .passThrough)
    }

    @Test func aMouseThatGoesAwayHasItsSwappedPressesReleasedAndNothingElse() {
        var processor = EventProcessor()
        let settings = swapping { $0.devices[Self.other.id] = DeviceSettings(swapPrimarySecondary: true) }
        _ = processor.process(event(.buttonDown(0), device: Self.mouse), settings: settings)
        _ = processor.process(event(.buttonDown(1), device: Self.other), settings: settings)
        let released = processor.releaseSwaps(unlessConnected: [Self.mouse.id])
        #expect(released.map(\.button) == [1])
        #expect(released.map(\.action) == [leftClick])
        #expect(processor.releaseSwaps(unlessConnected: [Self.mouse.id]).isEmpty)
        #expect(processor.process(event(.buttonUp(0), device: Self.mouse), settings: settings) == .perform(rightClick, .up))
    }

    // MARK: What the settings window says

    private func status(_ configure: (inout WhiskerSettings) -> Void = { _ in }, canIdentifyPresses: Bool = true) -> ButtonSwapStatus {
        ButtonSwap.status(for: Self.mouse.id, in: swappingSettings(configure), canIdentifyPresses: canIdentifyPresses)
    }

    @Test func statusSaysWhetherTheSwapIsWorking() {
        #expect(status().phase == .active)
        #expect(status { $0.devices[Self.mouse.id]?.swapPrimarySecondary = false }.phase == .off)
        #expect(status { $0.general.enabled = false }.phase == .inactive(.whiskerOff))
        #expect(status { $0.devices[Self.mouse.id]?.enabled = false }.phase == .inactive(.mouseOff))
        #expect(status { $0.general.allowPrimaryButtonRemap = false }.phase == .inactive(.primaryRemapNotAllowed))
        #expect(status(canIdentifyPresses: false).phase == .inactive(.cannotIdentifyPresses))
        #expect(ButtonSwap.status(for: Self.other.id, in: swappingSettings(), canIdentifyPresses: true).phase == .off)
    }

    @Test func statusNamesTheProfilesThatMapThePlainButtons() {
        let editor = Profile(name: "Editor", match: ProfileMatch(apps: [Self.editor]), mappings: [Mapping(trigger: .button(1), action: .space(.left))])
        #expect(status { $0.profiles.append(editor) } == ButtonSwapStatus(phase: .active, mappedBy: ["Editor"]))

        let elsewhere = Profile(name: "Other mouse", match: ProfileMatch(devices: [Self.other.id]), mappings: [Mapping(trigger: .button(0), action: .none)])
        #expect(status { $0.profiles.append(elsewhere) } == ButtonSwapStatus(phase: .active, mappedBy: []))

        // Every profile that applies to the mouse maps one of the buttons, so there is nowhere left to swap.
        let everywhere = status {
            $0.profiles[0].mappings.append(Mapping(trigger: .button(0), action: .passthrough))
            $0.profiles.append(editor)
        }
        #expect(everywhere == ButtonSwapStatus(phase: .inactive(.buttonsMappedEverywhere), mappedBy: [WhiskerSettings().defaultProfile.name, "Editor"]))
    }

    // MARK: Attribution and settings

    @Test func attributionTellsWhenAReportCameFromAnExcludedDevice() {
        var attributor = DeviceAttributor(connected: ["mouse"])
        attributor.excluded = ["trackpad"]
        attributor.record(deviceID: "trackpad", kind: .button(0), at: 1)
        #expect(attributor.attribute(kind: .button(0), at: 1.01) == DeviceAttribution(id: "trackpad", exact: true, isExcluded: true))
        attributor.record(deviceID: "mouse", kind: .button(0), at: 2)
        #expect(attributor.attribute(kind: .button(0), at: 2.01) == DeviceAttribution(id: "mouse", exact: true))
        #expect(attributor.attribute(kind: .button(1), at: 2.01) == DeviceAttribution(id: "mouse", exact: false))
    }

    @Test func theSwapRoundTripsAndOlderFilesDecodeWithoutIt() throws {
        var settings = WhiskerSettings()
        settings.devices["046d:c52b"] = DeviceSettings(name: "Mouse", swapPrimarySecondary: true)
        settings.unknownKeys["future"] = .string("kept")
        let reloaded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(reloaded == settings)
        #expect(reloaded.devices["046d:c52b"]?.swapPrimarySecondary == true)

        let old = #"{"schemaVersion":2,"devices":{"046d:c52b":{"name":"Mouse","enabled":true}},"profiles":[{"id":"default"}],"future":1}"#
        let loaded = try SettingsCodec.decodeValidated(Data(old.utf8))
        #expect(loaded.devices["046d:c52b"]?.swapPrimarySecondary == false)
        #expect(loaded.unknownKeys["future"] == .number(1))
        let rewritten = String(decoding: try SettingsCodec.encode(loaded), as: UTF8.self)
        #expect(!rewritten.contains("swapPrimarySecondary"))
    }
}
