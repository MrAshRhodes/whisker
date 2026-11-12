import Foundation
import Testing
@testable import WhiskerCore

@Suite("Dormant two-button chord model")
struct ButtonChordTests {
    private typealias Recognizer = ChordRecognizer<InputEvent>
    private let a = ChordConnection(token: 1)
    private let b = ChordConnection(token: 2)
    private let middle = Action.click(button: 2, modifiers: [])
    private var pair: ButtonChord { ButtonChord(first: 3, second: 4, action: middle, pressWindow: 125) }

    private func input(_ button: Int, _ phase: ChordPhase = .down, at time: Double = 1,
                       connection: ChordConnection? = ChordConnection(token: 1),
                       modifiers: ModifierSet = [], count: Int64 = 1) -> Recognizer.Input {
        let kind: InputKind
        switch phase {
        case .down: kind = .buttonDown(button)
        case .up: kind = .buttonUp(button)
        case .drag: kind = .buttonDragged(button)
        }
        return Recognizer.Input(
            button: button, phase: phase, connection: connection, modifiers: modifiers, time: time,
            payload: InputEvent(kind, modifiers: modifiers, timestamp: time,
                                device: DeviceAttribution(id: "1234:5678", exact: true),
                                app: "com.example.app", location: PointerPoint(x: 37, y: 82), clickCount: count)
        )
    }

    @Test(arguments: [false, true], [false, true])
    func eitherOrderRecognisesAtInclusiveDeadlineAndDrainsBothReleases(reverse: Bool, releaseFirst: Bool) throws {
        var r = Recognizer()
        let first = reverse ? 4 : 3, second = reverse ? 3 : 4
        #expect(r.process(input(first), chords: [pair]).isEmpty)
        let deadline = try #require(r.deadline)
        #expect(r.expire(at: deadline).isEmpty)
        #expect(r.process(input(second, at: deadline), chords: [pair]) == [.perform(middle, .down)])
        let drag = input(first, .drag, at: 1.15)
        #expect(r.process(drag, chords: [pair]) == [.drag(drag.payload, button: 2, modifiers: [])])
        let released = releaseFirst ? first : second, remaining = releaseFirst ? second : first
        #expect(r.process(input(released, .up, at: 1.2), chords: [pair]) == [.perform(middle, .up)])
        #expect(r.process(input(remaining, .drag, at: 1.21), chords: [pair]) == [
            .move(input(remaining, .drag, at: 1.21).payload),
        ])
        #expect(r.process(input(remaining, .up, at: 1.22), chords: [pair]).isEmpty)
        #expect(r.cancel().isEmpty)
        #expect(r.process(input(second, at: 2), chords: [pair]).isEmpty)
        #expect(r.deadline != nil)
    }

    @Test(arguments: [ChordPhase.up, .drag])
    func earlyReleaseAndDragReplayOriginalPayloadsInOrder(phase: ChordPhase) {
        var r = Recognizer()
        var chord = pair
        chord.modifiers = [.option]
        let first = input(3, modifiers: [.option], count: 2)
        let next = input(3, phase, at: 1.01, modifiers: [.option], count: 2)
        #expect(r.process(first, chords: [chord]).isEmpty)
        #expect(r.process(next, chords: [chord]) == [.forward(first.payload), .forward(next.payload)])
        #expect(r.deadline == nil)
        #expect(r.expire(at: 2).isEmpty)
    }

    @Test(arguments: [false, true])
    func timeoutCannotRecogniseOrRebufferLateSecondPress(timerFires: Bool) {
        var r = Recognizer()
        let first = input(3, count: 3)
        let second = input(4, at: 1.126)
        #expect(r.process(first, chords: [pair]).isEmpty)
        if timerFires {
            #expect(r.expire(at: 1.126) == [.forward(first.payload)])
            #expect(r.process(second, chords: [pair]) == [.forward(second.payload)])
        } else {
            #expect(r.process(second, chords: [pair]) == [.forward(first.payload), .forward(second.payload)])
        }
        #expect(r.deadline == nil)
        #expect(r.process(input(3, .up, at: 1.2), chords: [pair]) == [.forward(input(3, .up, at: 1.2).payload)])
        #expect(r.process(input(4, .up, at: 1.3), chords: [pair]) == [.forward(input(4, .up, at: 1.3).payload)])
    }

    @Test func unrelatedButtonsNeverWaitAndFlushPendingBeforeThemselves() {
        var r = Recognizer()
        let first = input(3), other = input(7, at: 1.01)
        #expect(r.process(other, chords: [pair]) == [.forward(other.payload)])
        _ = r.process(input(7, .up, at: 1.02), chords: [pair])
        #expect(r.process(input(3, at: 2), chords: [pair]).isEmpty)
        #expect(r.process(input(7, at: 2.01), chords: [pair]) == [
            .forward(input(3, at: 2).payload), .forward(input(7, at: 2.01).payload),
        ])
        var empty = Recognizer()
        #expect(empty.process(first, chords: []) == [.forward(first.payload)])
    }

    @Test func primaryGuardAppliesBeforeEitherConstituentIsBuffered() {
        for button in [0, 1] {
            var r = Recognizer()
            let event = input(button)
            #expect(r.process(event, chords: [.middleClick()]) == [.forward(event.payload)])
            #expect(r.deadline == nil)
            #expect(r.cancel().isEmpty)
            var optedIn = Recognizer()
            #expect(optedIn.process(event, chords: [.middleClick()], allowPrimary: true).isEmpty)
            #expect(optedIn.deadline != nil)
            var modified = Recognizer()
            #expect(modified.process(input(button, modifiers: [.option]), chords: [.middleClick(modifiers: [.option])]).isEmpty)
            #expect(modified.deadline != nil)
        }
        #expect(ButtonChord.middleClick(modifiers: [.function]).problem(allowPrimary: false) != nil)
    }

    @Test(arguments: [false, true])
    func primaryPresetProducesOneHeldMiddleClickWithModifiersOrOptIn(optIn: Bool) {
        let modifiers: ModifierSet = optIn ? [] : [.option]
        let preset = ButtonChord.middleClick(modifiers: modifiers)
        var r = Recognizer()
        #expect(r.process(input(0, modifiers: modifiers), chords: [preset], allowPrimary: optIn).isEmpty)
        #expect(r.process(input(1, at: 1.01, modifiers: modifiers), chords: [preset], allowPrimary: optIn) == [.perform(middle, .down)])
        #expect(r.process(input(0, .up, at: 1.02), chords: [preset], allowPrimary: optIn) == [.perform(middle, .up)])
        #expect(r.process(input(1, .up, at: 1.03), chords: [preset], allowPrimary: optIn).isEmpty)
        #expect(r.cancel().isEmpty)
    }

    @Test func fallbackPayloadsCanResolveThroughOrdinaryMappingsWithoutReenteringChords() {
        var r = Recognizer(), processor = EventProcessor()
        let first = input(3), up = input(3, .up, at: 1.01)
        #expect(r.process(first, chords: [pair]).isEmpty)
        let effects = r.process(up, chords: [pair])
        let settings = CompiledSettings(WhiskerSettings())
        let plans = effects.compactMap { effect -> EventPlan? in
            guard case .forward(let original) = effect else { return nil }
            return processor.process(original, settings: settings)
        }
        #expect(plans == [.perform(.navigate(.back), .once), .swallow])
        #expect(r.deadline == nil)
    }

    @Test func identicalModelMiceCannotCombineAndUnknownAttributionNeverBuffers() {
        var r = Recognizer()
        let first = input(3, connection: a), second = input(4, at: 1.01, connection: b)
        #expect(first.payload.device == second.payload.device)
        #expect(r.process(first, chords: [pair]).isEmpty)
        #expect(r.process(second, chords: [pair]) == [.forward(first.payload), .forward(second.payload)])
        #expect(r.deadline == nil)
        var unknown = Recognizer()
        let missing = input(3, connection: nil)
        #expect(unknown.process(missing, chords: [pair]) == [.forward(missing.payload)])
        #expect(unknown.deadline == nil)
    }

    @Test func changedModifiersOrConfigurationAbandonPending() {
        for changeModifiers in [false, true] {
            var r = Recognizer()
            let first = input(3)
            #expect(r.process(first, chords: [pair]).isEmpty)
            let next = input(4, at: 1.01, modifiers: changeModifiers ? [.shift] : [])
            #expect(r.process(next, chords: changeModifiers ? [pair] : []) == [.forward(first.payload), .forward(next.payload)])
        }
    }

    @Test func overlappingPairsAndInvalidActionsFailOpen() {
        let overlapping = ButtonChord(first: 4, second: 5, modifiers: [.option], action: middle)
        #expect(ButtonChord.problem(in: [pair, overlapping], allowPrimary: false) != nil)
        for action in [Action.clickLock, .passthrough, .none, .slowPointer(factor: 0.5)] {
            var invalid = pair
            invalid.action = action
            #expect(invalid.problem(allowPrimary: false) != nil)
        }
        var r = Recognizer()
        let first = input(3)
        #expect(r.process(first, chords: [pair, overlapping]) == [.forward(first.payload)])
    }

    @Test func competingHeldOutputRefusesBufferingAndRecognition() {
        var r = Recognizer()
        let first = input(3), second = input(4, at: 1.01)
        #expect(r.process(first, chords: [pair], outputsIdle: false) == [.forward(first.payload)])
        #expect(r.cancel().isEmpty)
        var pending = Recognizer()
        #expect(pending.process(first, chords: [pair]).isEmpty)
        #expect(pending.process(second, chords: [pair], outputsIdle: false) == [.forward(first.payload), .forward(second.payload)])
        #expect(pending.cancel().isEmpty)
    }

    @Test func newSourceEndsOwnHoldBeforeAdmittingAnotherAndDoesNotReleaseItAgain() {
        var r = Recognizer()
        _ = r.process(input(3), chords: [pair])
        #expect(r.process(input(4, at: 1.01), chords: [pair]) == [.perform(middle, .down)])
        let competing = input(2, at: 1.02, connection: b)
        #expect(r.process(competing, chords: [pair]) == [.perform(middle, .up), .forward(competing.payload)])
        #expect(r.process(input(3, .up, at: 1.03), chords: [pair]).isEmpty)
        #expect(r.process(input(4, .up, at: 1.04), chords: [pair]).isEmpty)
        #expect(r.cancel().isEmpty)
    }

    @Test func cancellationDropsPendingWithoutStaleReplayAndConsumesKnownReleaseTail() {
        var r = Recognizer()
        #expect(r.process(input(3), chords: [pair]).isEmpty)
        #expect(r.cancel().isEmpty)
        #expect(r.expire(at: 10).isEmpty)
        #expect(r.process(input(3, .up, at: 11), chords: [pair]).isEmpty)
        #expect(r.process(input(4, at: 12), chords: [pair]).isEmpty)
        #expect(r.deadline != nil)
    }

    @Test func cancellationReleasesExactlyOnceAndCannotRearmUntilBothLetGo() {
        var r = Recognizer()
        _ = r.process(input(3), chords: [pair])
        _ = r.process(input(4, at: 1.01), chords: [pair])
        #expect(r.cancel() == [.perform(middle, .up)])
        #expect(r.cancel().isEmpty)
        #expect(r.process(input(3, .up, at: 2), chords: [pair]).isEmpty)
        let downAgain = input(3, at: 2.01)
        #expect(r.process(downAgain, chords: [pair]) == [.forward(downAgain.payload)])
        #expect(r.process(input(4, .up, at: 2.02), chords: [pair]).isEmpty)
        #expect(r.deadline == nil)
    }

    @Test func disconnectOnlyReleasesItsOwnConnectionAndNewTokenStartsClean() {
        var r = Recognizer()
        _ = r.process(input(3), chords: [pair])
        _ = r.process(input(4, at: 1.01), chords: [pair])
        #expect(r.disconnect(b).isEmpty)
        #expect(r.disconnect(a) == [.perform(middle, .up)])
        #expect(r.disconnect(a).isEmpty)
        #expect(r.process(input(3, at: 2, connection: b), chords: [pair]).isEmpty)
        #expect(r.deadline != nil)
    }

    @Test func oneShotActionsRunOnceWithoutAnInventedRelease() {
        var r = Recognizer()
        var chord = pair
        chord.action = .navigate(.back)
        _ = r.process(input(3), chords: [chord])
        #expect(r.process(input(4, at: 1.01), chords: [chord]) == [.perform(.navigate(.back), .once)])
        #expect(r.process(input(3, .up, at: 1.02), chords: [chord]).isEmpty)
        #expect(r.process(input(4, .up, at: 1.03), chords: [chord]).isEmpty)
        #expect(r.cancel().isEmpty)
    }

    @Test func nonMonotonicAndNonFiniteTimeNeverReplayPending() {
        for invalid in [0.0, Double.nan, Double.infinity] {
            var r = Recognizer()
            _ = r.process(input(3), chords: [pair])
            #expect(r.expire(at: invalid).isEmpty)
            #expect(r.deadline == nil)
            #expect(r.process(input(3, .up, at: 2), chords: [pair]).isEmpty)
        }
    }

    @Test func invalidReleaseTimestampDoesNotLeakAnOrphanUp() {
        var r = Recognizer()
        _ = r.process(input(3), chords: [pair])
        _ = r.process(input(4, at: 1.01), chords: [pair])
        #expect(r.process(input(3, .up, at: .nan), chords: [pair]) == [.perform(middle, .up)])
        #expect(r.process(input(4, .up, at: 2), chords: [pair]).isEmpty)
        #expect(r.cancel().isEmpty)
    }

    @Test func opaqueFallbackKeepsAllOriginalMetadata() {
        struct Payload: Equatable, Sendable {
            var rawFlags: UInt64
            var x: Double
            var y: Double
            var clickCount: Int64
            var opaqueID: UInt64
        }
        var r = ChordRecognizer<Payload>()
        let payload = Payload(rawFlags: UInt64.max, x: -18.25, y: 100.5, clickCount: 3, opaqueID: 42)
        _ = r.process(.init(button: 3, phase: .down, connection: a, time: 1, payload: payload), chords: [pair])
        #expect(r.expire(at: 2) == [.forward(payload)])
    }
}

@Suite("Chord settings and dormant runtime")
struct ButtonChordSettingsTests {
    private let chord = ButtonChord(first: 3, second: 4, action: .click(button: 2, modifiers: []))

    @Test func oldProfilesStayDisabledAndDoNotGainAKey() throws {
        let profile = try JSONDecoder().decode(Profile.self, from: Data(#"{"id":"default","mappings":[]}"#.utf8))
        #expect(profile.chords == nil)
        let json = try #require(JSONSerialization.jsonObject(with: JSONEncoder().encode(profile)) as? [String: Any])
        #expect(json["chords"] == nil)
        #expect(WhiskerSettings().resolvedProfile(id: Profile.defaultID).chords.isEmpty)
    }

    @Test func additiveRoundTripPreservesMappingsAndListInheritance() throws {
        var settings = WhiskerSettings()
        let mappings = settings.profiles[0].mappings
        settings.profiles[0].chords = [chord]
        settings.profiles.append(Profile(id: "child", name: "Child"))
        settings.profiles.append(Profile(id: "off", name: "Off", chords: []))
        settings.profiles.append(Profile(id: "none", name: "None", inherits: nil))
        settings.unknownKeys["future"] = .object(["preserved": .bool(true)])
        let decoded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(decoded == settings)
        #expect(decoded.profiles[0].mappings == mappings)
        #expect(decoded.resolvedProfile(id: "child").chords == [chord])
        #expect(decoded.resolvedProfile(id: "off").chords.isEmpty)
        #expect(decoded.resolvedProfile(id: "none").chords.isEmpty)
        #expect(CompiledSettings(decoded).profile(device: nil, app: nil).chords == [chord])
        #expect(decoded.validate().isEmpty)
    }

    @Test func childListReplacesInsteadOfOverlappingParent() {
        var settings = WhiskerSettings()
        settings.profiles[0].chords = [chord]
        let own = ButtonChord(first: 4, second: 5, action: .navigate(.back))
        settings.profiles.append(Profile(id: "child", name: "Child", chords: [own]))
        #expect(settings.resolvedProfile(id: "child").chords == [own])
        #expect(settings.validate().isEmpty)
    }

    @Test func invalidListIsDisabledRatherThanFallingBackToParent() {
        var settings = WhiskerSettings()
        settings.profiles[0].chords = [chord]
        settings.profiles.append(Profile(id: "child", name: "Child", chords: [chord, chord]))
        let fixed = settings.repairedWithIssues()
        #expect(fixed.issues.contains { $0.path == "profiles[1].chords" })
        #expect(fixed.settings.resolvedProfile(id: "child").chords.isEmpty)
        #expect(fixed.settings.profiles[0].chords == [chord])
        #expect(fixed.settings.repaired() == fixed.settings)
    }

    @Test(arguments: [19, 20, 200, 201])
    func boundedWindowsAreValidated(window: Int) {
        var value = chord
        value.pressWindow = window
        #expect((value.problem(allowPrimary: false) == nil) == (20...200).contains(window))
    }

    @Test func malformedPairsAndDefaultPrimaryPresetAreRejected() {
        for pair in [(3, 3), (-1, 4), (3, 32)] {
            #expect(ButtonChord(first: pair.0, second: pair.1, action: .navigate(.back)).problem(allowPrimary: false) != nil)
        }
        var settings = WhiskerSettings()
        settings.profiles[0].chords = [.middleClick()]
        #expect(!settings.validate().isEmpty)
        settings.general.allowPrimaryButtonRemap = true
        #expect(settings.validate().isEmpty)
    }

    @Test func importedChordsLeaveOrdinaryProcessingUnchanged() {
        var settings = WhiskerSettings()
        settings.profiles[0].chords = [chord, .middleClick(modifiers: [.option])]
        let compiled = CompiledSettings(settings)
        let original = CompiledSettings(WhiskerSettings())
        var withChords = EventProcessor(), withoutChords = EventProcessor()
        for kind in [InputKind.buttonDown(0), .buttonUp(0), .buttonDown(3), .buttonUp(3), .buttonDown(4), .buttonUp(4)] {
            let event = InputEvent(kind, timestamp: 1, device: DeviceAttribution(id: "1234:5678", exact: true))
            #expect(withChords.process(event, settings: compiled) == withoutChords.process(event, settings: original))
        }
    }
}
