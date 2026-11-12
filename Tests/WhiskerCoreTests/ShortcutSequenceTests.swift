import Foundation
import Testing
@testable import WhiskerCore

private func step(_ code: UInt16, _ modifiers: ModifierSet = .command, delay: Int = 0) -> SequenceStep {
    SequenceStep(shortcut: KeyShortcut(keyCode: code, modifiers: modifiers), delayAfterMs: delay)
}

@Suite("Shortcut sequences")
struct ShortcutSequenceTests {
    private func decode(_ json: String) throws -> Action {
        try JSONDecoder().decode(Action.self, from: Data(json.utf8))
    }

    // MARK: Coding

    @Test func payloadUsesStepsWithKeyCodeModifiersAndDelay() throws {
        let action = try decode(#"{"kind":"shortcutSequence","steps":[{"keyCode":0,"modifiers":["command"],"delayAfterMs":250},{"keyCode":8}]}"#)
        #expect(action == .shortcutSequence([step(0, delay: 250), step(8, [])]))

        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any]
        let steps = written?["steps"] as? [[String: Any]]
        #expect(written?["kind"] as? String == "shortcutSequence")
        #expect(steps?.first?["keyCode"] as? Int == 0)
        #expect(steps?.first?["delayAfterMs"] as? Int == 250)
        #expect(steps?.first?["modifiers"] as? [String] == ["command"])
    }

    @Test func stepsAreRequired() {
        #expect(throws: DecodingError.self) { try decode(#"{"kind":"shortcutSequence"}"#) }
    }

    @Test func existingShortcutPayloadIsUnchanged() throws {
        let action = Action.shortcut(KeyShortcut(keyCode: 0x11, modifiers: .command), repeatWhileHeld: false)
        let written = try JSONSerialization.jsonObject(with: JSONEncoder().encode(action)) as? [String: Any]
        #expect(Set(written?.keys.map { $0 } ?? []) == ["kind", "keyCode", "modifiers", "repeatWhileHeld"])
    }

    // MARK: Schema

    @Test func versionOneFilesUpgradeAndKeepTheirSettingsAndUnknownKeys() throws {
        let old = """
        {"schemaVersion":1,"future":{"x":1},"profiles":[{"id":"default","mappings":[
        {"trigger":{"type":"button","button":3},"action":{"kind":"shortcut","keyCode":17,"modifiers":["command"],"repeatWhileHeld":true}}]}]}
        """
        var settings = try SettingsCodec.decodeValidated(Data(old.utf8))
        #expect(settings.schemaVersion == 2)
        #expect(settings.defaultProfile.mappings == [
            Mapping(trigger: .button(3), action: .shortcut(KeyShortcut(keyCode: 17, modifiers: .command), repeatWhileHeld: true)),
        ])

        settings.profiles[0].mappings.append(Mapping(trigger: .button(4), action: .shortcutSequence([step(0), step(8)])))
        let reloaded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(reloaded == settings)
        #expect(reloaded.unknownKeys["future"] == .object(["x": .number(1)]))
    }

    @Test func aWhiskerThatPredatesSequencesRefusesTheFileInsteadOfReadingItWrongly() {
        // The version 1 reader's rule, as the current code applies it to a file from a later schema.
        #expect(throws: SettingsCodec.Failure.newerSchema(3)) { try SettingsCodec.decode(Data(#"{"schemaVersion":3}"#.utf8)) }
    }

    // MARK: Limits

    @Test func limitsAreEnforcedForTheEditorAndForFiles() throws {
        func problem(_ steps: [SequenceStep]) -> String? { ShortcutSequenceLimits.problem(with: steps) }
        let two = [step(0), step(8)]
        #expect(problem(two) == nil)
        #expect(problem([step(0)]) != nil)
        #expect(problem([]) != nil)
        #expect(problem(Array(repeating: step(0), count: 16)) == nil)
        #expect(problem(Array(repeating: step(0), count: 17)) != nil)
        #expect(problem([step(0, delay: 2000), step(8)]) == nil)
        #expect(problem([step(0, delay: 2001), step(8)]) != nil)
        #expect(problem([step(0, delay: -1), step(8)]) != nil)
        #expect(problem([step(0), step(0x80)]) != nil)

        // 5 waits of 2 s fit exactly; a sixth doesn't. The last step's delay is never waited.
        let five = (0..<5).map { step(UInt16($0), delay: 2000) } + [step(9, delay: 2000)]
        #expect(ShortcutSequenceLimits.totalDelayMs(of: five) == 10_000)
        #expect(problem(five) == nil)
        #expect(problem((0..<6).map { step(UInt16($0), delay: 2000) } + [step(9)]) != nil)

        var settings = WhiskerSettings()
        let bad = Mapping(trigger: .button(4), action: .shortcutSequence([step(0)]))
        settings.profiles[0].mappings = [bad, Mapping(trigger: .button(5), action: .shortcutSequence(two))]
        #expect(settings.validate().map(\.path) == ["profiles[0].mappings[0]"])
        #expect(settings.repaired().defaultProfile.mappings.count == 1)
        let data = try SettingsCodec.encode(settings)
        #expect(throws: SettingsCodec.Failure.self) { try SettingsCodec.decodeValidated(data) }
    }

    @Test func primaryButtonGuardAppliesToSequences() {
        let action = Action.shortcutSequence([step(0), step(8)])
        let bare = Mapping(trigger: .button(0), action: action)
        #expect(WhiskerSettings.problem(with: bare, allowPrimary: false) != nil)
        #expect(WhiskerSettings.problem(with: bare, allowPrimary: true) == nil)
        #expect(WhiskerSettings.problem(with: Mapping(trigger: .button(0), modifiers: .command, action: action), allowPrimary: false) == nil)
    }

    // MARK: Running

    @Test func aSequenceRunsEachStepOnceInOrderWithItsDelay() {
        var state = ShortcutSequenceState()
        let steps = [step(0, delay: 100), step(8, delay: 250), step(9, delay: 999)]
        #expect(state.activation(of: steps) == .start)
        state.begin(steps)

        var posted: [UInt16] = []
        var waits: [TimeInterval?] = []
        while let current = state.current {
            posted.append(current.shortcut.keyCode)
            waits.append(state.completeStep())
        }
        #expect(posted == [0, 8, 9])
        #expect(waits == [0.1, 0.25, nil])
        #expect(!state.isRunning)
        #expect(state.completeStep() == nil)
    }

    @Test func sameMappingCancelsAndAnotherIsIgnoredWhileRunning() {
        var state = ShortcutSequenceState()
        let mine = [step(0), step(8)]
        let other = [step(1), step(2)]
        state.begin(mine)
        #expect(state.activation(of: mine) == .cancelRunning)
        #expect(state.activation(of: other) == .ignored)
        state.stop()
        #expect(state.activation(of: other) == .start)
    }

    @Test func stoppingStartsANewGenerationAndDropsTheRest() {
        var state = ShortcutSequenceState()
        state.begin([step(0), step(8)])
        let before = state.generation
        state.stop()
        #expect(state.generation != before)
        #expect(state.current == nil)
        #expect(!state.isRunning)
    }

    // MARK: Physical keys

    @Test func heldModifiersMustBePartOfTheStep() {
        let commandC = step(8, .command)
        #expect(SequencePhysicalCheck.allows(commandC, heldModifiers: [], keyIsHeld: false))
        #expect(SequencePhysicalCheck.allows(commandC, heldModifiers: .command, keyIsHeld: false))
        #expect(!SequencePhysicalCheck.allows(commandC, heldModifiers: [.command, .option], keyIsHeld: false))
        #expect(!SequencePhysicalCheck.allows(step(48, []), heldModifiers: .command, keyIsHeld: false))
        #expect(SequencePhysicalCheck.allows(step(48, []), heldModifiers: .function, keyIsHeld: false))
        #expect(!SequencePhysicalCheck.allows(commandC, heldModifiers: [], keyIsHeld: true))
    }
}
