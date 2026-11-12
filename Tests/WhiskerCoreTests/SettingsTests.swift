import Foundation
import Testing
@testable import WhiskerCore

@Suite("Settings model")
struct SettingsTests {
    // MARK: Modifiers and shortcuts

    @Test func modifiersRoundTripThroughEventFlags() {
        let set: ModifierSet = [.command, .shift]
        #expect(set.eventFlags == ModifierSet.EventFlag.command | ModifierSet.EventFlag.shift)
        #expect(ModifierSet(eventFlags: set.eventFlags | 0x100) == set)
        #expect(ModifierSet([.control, .option, .shift, .command]).symbols == "⌃⌥⇧⌘")
    }

    @Test func modifiersCodeAsNamesAndRejectUnknownOnes() throws {
        let data = try JSONEncoder().encode(ModifierSet([.command, .control]))
        #expect(String(decoding: data, as: UTF8.self) == #"["control","command"]"#)
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(ModifierSet.self, from: Data(#"["hyper"]"#.utf8)) }
    }

    @Test(arguments: [
        ("cmd+shift+t", UInt16(0x11), ModifierSet([.command, .shift])),
        ("⌘⇧T", UInt16(0x11), ModifierSet([.command, .shift])),
        ("control-left", UInt16(0x7B), ModifierSet.control),
        ("F11", UInt16(0x67), ModifierSet()),
    ])
    func shortcutsParse(text: String, keyCode: UInt16, modifiers: ModifierSet) throws {
        let shortcut = try #require(KeyShortcut(parsing: text))
        #expect(shortcut.keyCode == keyCode)
        #expect(shortcut.modifiers == modifiers)
    }

    @Test func nonsenseShortcutsDoNotParse() {
        #expect(KeyShortcut(parsing: "") == nil)
        #expect(KeyShortcut(parsing: "hyper+t") == nil)
        #expect(KeyShortcut(parsing: "cmd+nosuchkey") == nil)
    }

    // MARK: Coding

    @Test func everyActionRoundTrips() throws {
        let actions: [Action] = [
            .passthrough, .none, .click(button: 2, modifiers: [.command]), .doubleClick(modifiers: []), .tripleClick(modifiers: [.shift]),
            .shortcut(KeyShortcut(keyCode: 0x11, modifiers: .command), repeatWhileHeld: true),
            .scroll(direction: .left, lines: 4), .media(.volumeUp), .navigate(.forward),
            .missionControl(.appWindows), .space(.right), .appSwitch(.previous), .open(url: "https://example.com"),
        ]
        for action in actions {
            let data = try JSONEncoder().encode(action)
            #expect(try JSONDecoder().decode(Action.self, from: data) == action)
        }
        #expect(Set(actions.map(\.kind)).count == ActionKind.allCases.count)
    }

    @Test func triggersRoundTripAndRejectUnknownTypes() throws {
        for trigger in [Trigger.button(5), .wheel(.down)] {
            #expect(try JSONDecoder().decode(Trigger.self, from: JSONEncoder().encode(trigger)) == trigger)
        }
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Trigger.self, from: Data(#"{"type":"pedal"}"#.utf8)) }
    }

    @Test func settingsRoundTripKeepingUnknownKeys() throws {
        var settings = WhiskerSettings()
        settings.general.bypassApps = ["com.example.game"]
        settings.devices["046d:c52b"] = DeviceSettings(name: "Mouse", pointer: PointerSettings(speed: 1.5), wheel: WheelSettings(invertVertical: true))
        settings.profiles.append(Profile(id: "safari", name: "Safari", match: ProfileMatch(apps: ["com.apple.Safari"]), inherits: nil, scroll: ScrollSettings(linesPerNotch: 5)))
        settings.unknownKeys["future"] = .object(["x": .array([.number(1), .bool(true), .null])])
        let data = try SettingsCodec.encode(settings)
        let decoded = try SettingsCodec.decode(data)
        #expect(decoded == settings)
        #expect(decoded.profile(id: "safari")?.inherits == nil)
    }

    @Test func tripleClickCodesAsItsOwnKindAndModifiersAreOptional() throws {
        func decode(_ json: String) throws -> Action { try JSONDecoder().decode(Action.self, from: Data(json.utf8)) }
        #expect(try decode(#"{"kind":"tripleClick"}"#) == .tripleClick(modifiers: []))
        #expect(try decode(#"{"kind":"tripleClick","modifiers":["command","shift"]}"#) == .tripleClick(modifiers: [.command, .shift]))
        #expect(try decode(#"{"kind":"doubleClick"}"#) == .doubleClick(modifiers: []))

        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Action.tripleClick(modifiers: .shift))) as? [String: Any]
        #expect(written?["kind"] as? String == "tripleClick")
        #expect(written?["modifiers"] as? [String] == ["shift"])
    }

    @Test func filesFromBeforeTripleClickLoadAsTheyWereAndKeepTheirUnknownKeys() throws {
        let old = """
        {"schemaVersion":1,"general":{"enabled":true},"future":{"x":[1,true,null]},"profiles":[{"id":"default","mappings":[
        {"trigger":{"type":"button","button":3},"action":{"kind":"doubleClick","modifiers":["shift"]}},
        {"trigger":{"type":"button","button":4},"action":{"kind":"navigate","direction":"forward"}}]}]}
        """
        var settings = try SettingsCodec.decodeValidated(Data(old.utf8))
        #expect(settings.schemaVersion == WhiskerSettings.currentSchemaVersion)
        #expect(settings.defaultProfile.mappings == [
            Mapping(trigger: .button(3), action: .doubleClick(modifiers: .shift)),
            Mapping(trigger: .button(4), action: .navigate(.forward)),
        ])

        settings.profiles[0].mappings.append(Mapping(trigger: .button(5), action: .tripleClick(modifiers: .shift)))
        let reloaded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(reloaded == settings)
        #expect(reloaded.unknownKeys["future"] == .object(["x": .array([.number(1), .bool(true), .null])]))
    }

    @Test func scrollSpeedModifierRoundTripsAndOlderFilesDecodeWithoutIt() throws {
        var settings = WhiskerSettings()
        settings.profiles[0].scroll = ScrollSettings(
            linesPerNotch: 3, acceleration: 0.5, horizontalModifier: .shift,
            modifierScaling: ModifierScaling(modifiers: [.option, .control], multiplier: 0.5, axes: .horizontal)
        )
        settings.unknownKeys["future"] = .string("kept")
        let decoded = try SettingsCodec.decode(SettingsCodec.encode(settings))
        #expect(decoded == settings)
        #expect(decoded.validate().isEmpty)

        let shape = Data(#"{"modifierScaling":{"modifiers":["option"],"multiplier":0.5,"axes":"horizontal"}}"#.utf8)
        #expect(try JSONDecoder().decode(ScrollSettings.self, from: shape).modifierScaling == ModifierScaling(modifiers: .option, multiplier: 0.5, axes: .horizontal))
        let sparse = Data(#"{"modifierScaling":{"modifiers":["option"]}}"#.utf8)
        #expect(try JSONDecoder().decode(ScrollSettings.self, from: sparse).modifierScaling == ModifierScaling(modifiers: .option, multiplier: 2, axes: .both))
        let unknownAxes = #"{"profiles":[{"id":"default","scroll":{"modifierScaling":{"modifiers":["option"],"axes":"diagonal"}}}]}"#
        #expect(throws: SettingsCodec.Failure.self) { try SettingsCodec.decode(Data(unknownAxes.utf8)) }

        // A file from before the setting existed reads as it always did and doesn't gain the key.
        let old = #"{"schemaVersion":1,"profiles":[{"id":"default","scroll":{"linesPerNotch":3,"acceleration":0.5,"horizontalModifier":["shift"]}}],"future":{"x":1}}"#
        let upgraded = try SettingsCodec.decode(Data(old.utf8))
        #expect(upgraded.defaultProfile.scroll == ScrollSettings(linesPerNotch: 3, acceleration: 0.5, horizontalModifier: .shift))
        let rewritten = String(decoding: try SettingsCodec.encode(upgraded), as: UTF8.self)
        #expect(!rewritten.contains("modifierScaling"))
        #expect(rewritten.contains("future"))
    }

    @Test func missingInheritsMeansDefaultAndExplicitNullMeansNone() throws {
        let json = #"{"schemaVersion":1,"profiles":[{"id":"default"},{"id":"a"},{"id":"b","inherits":null}]}"#
        let settings = try SettingsCodec.decode(Data(json.utf8))
        #expect(settings.profile(id: "a")?.inherits == "default")
        #expect(settings.profile(id: "b")?.inherits == nil)
    }

    @Test func unversionedFilesUpgrade() throws {
        let settings = try SettingsCodec.decode(Data(#"{"general":{"enabled":false}}"#.utf8))
        #expect(settings.schemaVersion == 1)
        #expect(settings.general.enabled == false)
        #expect(settings.profiles == [.makeDefault()])
    }

    @Test func filesWithoutABypassListDecodeAsBefore() throws {
        let json = #"{"schemaVersion":1,"general":{"enabled":false,"showMenuBarIcon":false,"allowPrimaryButtonRemap":true},"future":1}"#
        let settings = try SettingsCodec.decode(Data(json.utf8))
        #expect(settings.general == GeneralSettings(enabled: false, showMenuBarIcon: false, allowPrimaryButtonRemap: true))
        #expect(settings.general.bypassApps.isEmpty)
        #expect(settings.schemaVersion == 1)
        #expect(settings.unknownKeys["future"] == .number(1))
    }

    @Test func newerAndUnreadableFilesAreRefused() {
        #expect(throws: SettingsCodec.Failure.newerSchema(9)) { try SettingsCodec.decode(Data(#"{"schemaVersion":9}"#.utf8)) }
        #expect(throws: SettingsCodec.Failure.self) { try SettingsCodec.decode(Data("[1,2]".utf8)) }
        #expect(throws: SettingsCodec.Failure.self) { try SettingsCodec.decode(Data(#"{"profiles":[{"name":"no id"}]}"#.utf8)) }
    }

    // MARK: Validation

    @Test func defaultSettingsAreValid() {
        #expect(WhiskerSettings().validate().isEmpty)
    }

    @Test func openPathsSurviveRepair() throws {
        var settings = WhiskerSettings()
        let paths = ["/Applications/Safari.app", "~/Documents", "https://example.com"]
        settings.profiles[0].mappings = paths.enumerated().map { index, path in
            Mapping(trigger: .button(3 + index), action: .open(url: path))
        }
        #expect(settings.validate().isEmpty)
        let reloaded = try SettingsCodec.decodeRepairing(SettingsCodec.encode(settings)).settings
        #expect(reloaded.profiles[0].mappings == settings.profiles[0].mappings)
        #expect(Action.openURL(for: "~/Documents")?.path == NSString("~/Documents").expandingTildeInPath)
        #expect(Action.openURL(for: "/Applications/Safari.app")?.isFileURL == true)
        #expect(Action.openURL(for: "no scheme") == nil)
    }

    @Test func repairFixesEveryKindOfProblem() {
        var settings = WhiskerSettings(schemaVersion: 1, profiles: [])
        settings.devices["not-a-device"] = DeviceSettings()
        settings.devices["046d:c52b"] = DeviceSettings(pointer: PointerSettings(speed: 50, acceleration: .nan))
        settings.profiles = [
            Profile(id: "a", name: "A", inherits: "b", scroll: ScrollSettings(linesPerNotch: 99, acceleration: 7), mappings: [
                Mapping(trigger: .button(0), action: .none),
                Mapping(trigger: .button(3), action: .navigate(.back)),
                Mapping(trigger: .button(3), action: .navigate(.forward)),
                Mapping(trigger: .button(4), action: .open(url: "no scheme")),
            ]),
            Profile(id: "b", name: "B", inherits: "a"),
            Profile(id: "b", name: "Duplicate"),
            Profile(id: "c", name: "C", inherits: "missing"),
        ]
        let (repaired, issues) = settings.repairedWithIssues()
        #expect(!issues.isEmpty)
        #expect(repaired.validate().isEmpty)
        #expect(repaired.profiles.first?.isDefault == true)
        #expect(repaired.devices["not-a-device"] == nil)
        #expect(repaired.devices["046d:c52b"]?.pointer == PointerSettings(speed: 5, acceleration: 0))
        let a = repaired.profile(id: "a")
        #expect(a?.mappings == [Mapping(trigger: .button(3), action: .navigate(.back))])
        #expect(a?.scroll == ScrollSettings(linesPerNotch: 20, acceleration: 1))
        #expect(repaired.profiles.filter { $0.id == "b" }.count == 1)
        #expect(repaired.profile(id: "c")?.inherits == "default")
        for profile in repaired.profiles {
            #expect(!WhiskerSettings.inheritanceLoops(from: profile.id, in: repaired.profiles))
        }
    }

    @Test func scrollSpeedModifierIsClampedOrDroppedWhenItCantBeUsed() {
        func repair(_ scaling: ModifierScaling, sideways: ModifierSet = []) -> (settings: WhiskerSettings, issues: [ValidationIssue]) {
            var settings = WhiskerSettings()
            settings.profiles[0].scroll = ScrollSettings(horizontalModifier: sideways, modifierScaling: scaling)
            return settings.repairedWithIssues()
        }

        let usable = ModifierScaling(modifiers: .option, multiplier: 0.5, axes: .vertical)
        let untouched = repair(usable, sideways: .shift)
        #expect(untouched.issues.isEmpty)
        #expect(untouched.settings.defaultProfile.scroll?.modifierScaling == usable)

        let unusable: [(ModifierScaling, ModifierSet)] = [
            (ModifierScaling(modifiers: []), []),
            (ModifierScaling(modifiers: .function), []),
            (ModifierScaling(modifiers: .shift), .shift),
            (ModifierScaling(modifiers: [.shift, .function]), .shift),
            (ModifierScaling(modifiers: .option, multiplier: 0), []),
            (ModifierScaling(modifiers: .option, multiplier: -1), []),
            (ModifierScaling(modifiers: .option, multiplier: .nan), []),
            (ModifierScaling(modifiers: .option, multiplier: .infinity), []),
        ]
        for (scaling, sideways) in unusable {
            let result = repair(scaling, sideways: sideways)
            #expect(result.issues.map(\.path) == ["profiles[0].scroll.modifierScaling"])
            #expect(result.settings.defaultProfile.scroll?.modifierScaling == nil)
            #expect(result.settings.validate().isEmpty)
        }

        for (multiplier, clamped) in [(0.01, 0.25), (100, 8)] {
            let result = repair(ModifierScaling(modifiers: .option, multiplier: multiplier))
            #expect(result.issues.map(\.path) == ["profiles[0].scroll.modifierScaling.multiplier"])
            #expect(result.settings.defaultProfile.scroll?.modifierScaling?.multiplier == clamped)
        }
    }

    @Test(arguments: [Action.navigate(.back), .tripleClick(modifiers: [])])
    func primaryButtonNeedsModifierUnlessAllowed(action: Action) {
        let bare = Mapping(trigger: .button(0), action: action)
        #expect(WhiskerSettings.problem(with: bare, allowPrimary: false) != nil)
        #expect(WhiskerSettings.problem(with: bare, allowPrimary: true) == nil)
        #expect(WhiskerSettings.problem(with: Mapping(trigger: .button(0), modifiers: .command, action: action), allowPrimary: false) == nil)
    }

    @Test func importsMustAlreadyBeValid() throws {
        let json = #"{"schemaVersion":1,"profiles":[{"id":"default","mappings":[{"trigger":{"type":"button","button":0},"action":{"kind":"none"}}]}]}"#
        #expect(throws: SettingsCodec.Failure.self) { try SettingsCodec.decodeValidated(Data(json.utf8)) }
        #expect(try SettingsCodec.decodeRepairing(Data(json.utf8)).settings.defaultProfile.mappings.isEmpty)
    }

    @Test func repairTidiesTheBypassList() throws {
        var settings = WhiskerSettings()
        settings.general.bypassApps = [" com.example.game ", "", "*", "com.example.game", "com.example.launcher"]
        let (repaired, issues) = settings.repairedWithIssues()
        #expect(repaired.general.bypassApps == ["com.example.game", "com.example.launcher"])
        #expect(issues.map(\.path) == (0...3).map { "general.bypassApps[\($0)]" })
        #expect(repaired.validate().isEmpty)

        settings.general.bypassApps = ["com.example.game"]
        #expect(settings.validate().isEmpty)
        let json = #"{"schemaVersion":1,"general":{"bypassApps":["*"]}}"#
        #expect(throws: SettingsCodec.Failure.self) { try SettingsCodec.decodeValidated(Data(json.utf8)) }
        #expect(try SettingsCodec.decodeRepairing(Data(json.utf8)).settings.general.bypassApps.isEmpty)
    }

    // MARK: Profile resolution

    private func layered() -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.profiles += [
            Profile(id: "dev", name: "Device", match: ProfileMatch(devices: ["046d:c52b"]), mappings: [Mapping(trigger: .button(3), action: .media(.playPause))]),
            Profile(id: "app", name: "App", match: ProfileMatch(apps: ["com.example.app"]), scroll: ScrollSettings(linesPerNotch: 6), mappings: [Mapping(trigger: .button(2), action: .none)]),
            Profile(id: "both", name: "Both", match: ProfileMatch(devices: ["046d:c52b"], apps: ["com.example.app"]), inherits: "app", mappings: [Mapping(trigger: .button(4), action: .space(.left))]),
        ]
        return settings
    }

    @Test func mostSpecificProfileWins() {
        let settings = layered()
        #expect(settings.matchingProfile(device: "046d:c52b", app: "com.example.app").id == "both")
        #expect(settings.matchingProfile(device: "1234:5678", app: "com.example.app").id == "app")
        #expect(settings.matchingProfile(device: "046d:c52b", app: "com.other").id == "dev")
        #expect(settings.matchingProfile(device: nil, app: nil).id == "default")
    }

    @Test func inheritanceMergesParentsUnderChildren() {
        let resolved = layered().resolvedProfile(device: "046d:c52b", app: "com.example.app")
        #expect(resolved.profileID == "both")
        #expect(resolved.mapping(.button(3), modifiers: []) == Mapping(trigger: .button(3), action: .navigate(.back)))
        #expect(resolved.mapping(.button(4), modifiers: [])?.action == .space(.left))
        #expect(resolved.mapping(.button(2), modifiers: [])?.action == Action.none)
        #expect(resolved.mappings[MappingKey(.button(4))]?.inherited == false)
        #expect(resolved.mappings[MappingKey(.button(3))]?.sourceProfileID == "default")
        #expect(resolved.scroll.linesPerNotch == 6)
        #expect(resolved.sortedMappings.map(\.mapping.trigger) == [.button(2), .button(3), .button(4)])
    }

    @Test func scrollSpeedModifierIsInheritedWithTheScrollSettings() {
        var settings = WhiskerSettings()
        let scaling = ModifierScaling(modifiers: .option, multiplier: 0.5)
        settings.profiles[0].scroll = ScrollSettings(modifierScaling: scaling)
        settings.profiles += [
            Profile(id: "child", name: "Child", match: ProfileMatch(apps: ["com.example.child"])),
            Profile(id: "own", name: "Own", match: ProfileMatch(apps: ["com.example.own"]), scroll: ScrollSettings(linesPerNotch: 5)),
        ]
        #expect(settings.resolvedProfile(device: nil, app: "com.example.child").scroll.modifierScaling == scaling)
        // A profile's own scroll settings replace the parent's as a whole, scaling included.
        #expect(settings.resolvedProfile(device: nil, app: "com.example.own").scroll.modifierScaling == nil)
    }

    @Test func profileWithoutParentStartsEmpty() {
        var settings = WhiskerSettings()
        settings.profiles.append(Profile(id: "bare", name: "Bare", match: ProfileMatch(apps: ["x"]), inherits: nil))
        #expect(settings.resolvedProfile(device: nil, app: "x").mappings.isEmpty)
    }

    // MARK: Devices and apps

    @Test func deviceIdentifiersRoundTrip() {
        let identity = DeviceIdentity(vendorID: 0x046D, productID: 0xC52B, serial: " ABC ")
        #expect(identity.id == "046d:c52b:ABC")
        #expect(DeviceIdentity(id: identity.id) == identity)
        #expect(DeviceIdentity(id: "046d:c52b")?.serial == nil)
        #expect(DeviceIdentity(id: "46d:c52b") == nil)
        #expect(DeviceIdentity(id: "zzzz:c52b") == nil)
        #expect(DeviceIdentity(id: "046d:c52b:") == nil)
    }

    @Test func trackpadsAndTouchMiceAreExcluded() {
        #expect(DeviceIdentity.isExcluded(transport: "FIFO", product: nil, vendorID: 0))
        #expect(DeviceIdentity.isExcluded(transport: "Bluetooth", product: "Magic Trackpad", vendorID: 0x05AC))
        #expect(DeviceIdentity.isExcluded(transport: "Bluetooth", product: "Magic Mouse", vendorID: 0x05AC))
        #expect(!DeviceIdentity.isExcluded(transport: "USB", product: "USB Receiver", vendorID: 0x046D))
        #expect(DeviceIdentity.excludedKind(transport: "Bluetooth", product: "Magic Mouse", vendorID: 0x05AC) == .touchMouse)
        #expect(DeviceIdentity.excludedKind(transport: "Bluetooth", product: "Magic Trackpad", vendorID: 0x05AC) == .trackpad)
        #expect(DeviceIdentity.excludedKind(transport: "FIFO", product: "Apple Internal Keyboard / Trackpad", vendorID: 0x05AC) == .trackpad)
        #expect(!ExcludedDeviceKind.touchMouse.listLabel.localizedCaseInsensitiveContains("trackpad"))
    }

    @Test func pointerSettingsOnlyApplyWhileWhiskerAndTheDeviceAreOn() {
        let custom = PointerSettings(speed: 2)
        var settings = WhiskerSettings()
        settings.devices["046d:c52b"] = DeviceSettings(name: "Mouse", pointer: custom)
        #expect(settings.activePointer(for: "046d:c52b") == custom)
        #expect(settings.activePointer(for: "1234:5678") == nil)

        settings.general.enabled = false
        #expect(settings.activePointer(for: "046d:c52b") == nil)

        settings.general.enabled = true
        settings.devices["046d:c52b"]?.enabled = false
        #expect(settings.activePointer(for: "046d:c52b") == nil)
    }

    @Test func missionControlAndLaunchpadOpenTheirAppWhenTheShortcutIsOff() {
        let off = SymbolicHotKeyTable(entries: Dictionary(uniqueKeysWithValues: SystemShortcutID.allCases.map { ($0.rawValue, SystemShortcutStatus.disabled) }))
        #expect(Action.missionControl(.missionControl).systemShortcutPlan(off) == .openApp(["Mission Control"]))
        #expect(Action.missionControl(.launchpad).systemShortcutPlan(off) == .openApp(["Launchpad", "Apps"]))
        #expect(Action.missionControl(.showDesktop).systemShortcutPlan(off) == .unavailable(.showDesktop))
        #expect(Action.space(.left).systemShortcutPlan(off) == .unavailable(.moveLeftSpace))
        #expect(Action.none.systemShortcutPlan(off) == nil)

        let shortcut = KeyShortcut(keyCode: 0x7E, modifiers: .control)
        let on = SymbolicHotKeyTable(entries: [SystemShortcutID.missionControl.rawValue: .available(shortcut)])
        #expect(Action.missionControl(.missionControl).systemShortcutPlan(on) == .post(shortcut))
    }

    @Test func attributorPrefersRecentReportsThenTheOnlyMouse() {
        var attributor = DeviceAttributor(connected: ["a"])
        #expect(attributor.attribute(kind: .button(3), at: 1) == DeviceAttribution(id: "a", exact: false))
        attributor.connected = ["a", "b"]
        #expect(attributor.attribute(kind: .button(3), at: 1) == nil)
        attributor.record(deviceID: "b", kind: .button(3), at: 1.0)
        #expect(attributor.attribute(kind: .button(3), at: 1.01) == DeviceAttribution(id: "b", exact: true))
        #expect(attributor.attribute(kind: .wheel, at: 1.01) == nil)
        #expect(attributor.attribute(kind: .button(3), at: 1.5) == nil)
    }

    @Test func appHistoryIsMostRecentFirst() {
        var history = AppSwitchHistory()
        for app in ["a", "b", "c", "b"] { history.activated(app) }
        #expect(history.bundleIDs == ["b", "c", "a"])
        #expect(history.target(.next) == "c")
        #expect(history.target(.previous) == "a")
        #expect(history.target(.next, running: ["a", "b"]) == "a")
        history.terminated("c")
        #expect(history.bundleIDs == ["b", "a"])
    }

    // MARK: Application bypass

    @Test func bypassListEditsStayTidy() {
        var general = GeneralSettings()
        general.setBypassed(" com.example.game ", true)
        general.setBypassed("com.example.game", true)
        for ignored in ["", "   ", ProfileMatch.any] { general.setBypassed(ignored, true) }
        general.setBypassed("com.example.launcher", true)
        #expect(general.bypassApps == ["com.example.game", "com.example.launcher"])
        general.setBypassed("com.example.game", false)
        general.setBypassed("com.not.listed", false)
        #expect(general.bypassApps == ["com.example.launcher"])
        #expect(general.enabled)
    }

    @Test func bypassOnlyNamesListedApps() {
        let settings = WhiskerSettings(general: GeneralSettings(bypassApps: ["com.example.game"]))
        let compiled = CompiledSettings(settings)
        for (app, bypassed) in [("com.example.game", true), ("com.example.app", false), ("com.example.GAME", false), (nil, false)] as [(String?, Bool)] {
            #expect(settings.isBypassed(app: app) == bypassed)
            #expect(compiled.isBypassed(app: app) == bypassed)
        }
    }

    @Test func anUnidentifiableFrontAppKeepsTheCurrentBypassState() {
        let settings = WhiskerSettings(general: GeneralSettings(bypassApps: ["com.example.game"]))
        var front = FrontmostApp()
        front.activated(nil)
        #expect(front.bundleID == nil)
        #expect(!settings.isBypassed(app: front.bundleID))

        front.activated("com.example.game")
        front.activated(nil)
        front.activated("")
        #expect(front.bundleID == "com.example.game")
        #expect(settings.isBypassed(app: front.bundleID))

        front.activated("com.example.app")
        front.activated(nil)
        #expect(front.bundleID == "com.example.app")
        #expect(!settings.isBypassed(app: front.bundleID))
    }

    @Test func symbolicHotKeysParse() {
        let table = SymbolicHotKeyTable(dictionary: [
            "32": ["enabled": NSNumber(value: 1), "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: 0x7E), NSNumber(value: 0x0004_0000)]]],
            "79": ["enabled": NSNumber(value: 0)],
            "81": ["enabled": NSNumber(value: 1), "value": ["parameters": [NSNumber(value: 65535), NSNumber(value: 65535), NSNumber(value: 0)]]],
        ])
        #expect(table.status(of: .missionControl) == .available(KeyShortcut(keyCode: 0x7E, modifiers: .control)))
        #expect(table.status(of: .moveLeftSpace) == .disabled)
        #expect(table.status(of: .moveRightSpace) == .unassigned)
        #expect(table.status(of: .showDesktop) == SystemShortcutID.showDesktop.factoryDefault)
    }

    // MARK: Pointer and scroll math

    @Test func pointerSpeedMapsToResolutionAndBack() {
        #expect(PointerMath.resolution(forSpeed: 1) == 400)
        #expect(PointerMath.resolution(forSpeed: 2) == 200)
        #expect(PointerMath.resolution(forSpeed: 1, nativeResolution: 1000) == 1000)
        #expect(PointerMath.resolution(forSpeed: 0.01) == 2000)
        #expect(PointerMath.speed(forResolution: 200) == 2)
        #expect(PointerMath.acceleration(2, linear: true) == -1)
        #expect(PointerMath.acceleration(9, linear: false) == 3)
        #expect(PointerMath.ioFixed(1.5) == 98304)
        #expect(PointerMath.fromIOFixed(26_214_400) == 400)
        #expect(PointerMath.needsConfirmation(confirmed: 1, new: 2.5))
        #expect(!PointerMath.needsConfirmation(confirmed: 1, new: 2))
    }

    @Test func scrollAccelerationOnlyAboveThreshold() {
        #expect(ScrollMath.effectiveLines(base: 3, acceleration: 1, rate: 4) == 3)
        #expect(ScrollMath.effectiveLines(base: 3, acceleration: 0.5, rate: 10) == 12)
        #expect(ScrollMath.effectiveLines(base: 3, acceleration: 0, rate: 50) == 3)
        #expect(ScrollMath.notchRate(times: [0.0, 0.85, 0.9, 0.95, 1.0], now: 1.0) == 15)
        #expect(ScrollMath.notchRate(times: [1.0], now: 1.0) == 0)
    }
}
