import CoreGraphics
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Two-button chords in the event engine")
struct ChordEngineTests {
    /// What the router posted, in order, as the system would see it.
    final class Posted: @unchecked Sendable {
        private let lock = NSLock()
        private var _events: [CGEvent] = []
        var events: [CGEvent] { lock.withLock { _events } }
        var summary: [String] { events.map(ChordEngineTests.describe) }
        func append(_ event: CGEvent) { lock.withLock { _events.append(event) } }
    }

    final class Attribution: @unchecked Sendable {
        private let lock = NSLock()
        private var _source: ChordSource? = ChordEngineTests.source
        var source: ChordSource? {
            get { lock.withLock { _source } }
            set { lock.withLock { _source = newValue } }
        }
    }

    enum Phase { case down, up, drag }

    static let mouse = "1234:abcd"
    static let source = ChordSource(connection: ChordConnection(token: 7), deviceID: mouse)
    static let back = ButtonChord(first: 3, second: 4, action: .navigate(.back))
    static let location = CGPoint(x: 10, y: 20)

    final class Harness {
        let recorder = EventEngineTests.Recorder()
        let clock = ClickDebounceEngineTests.FakeClock()
        let posted = Posted()
        let attribution = Attribution()
        let settings: WhiskerSettings
        private(set) var engine: EventEngine!
        private var delivered = 0

        init(_ chords: [ButtonChord], allowPrimary: Bool = false, mappings: [Mapping] = []) {
            settings = ChordEngineTests.settings(chords, allowPrimary: allowPrimary, mappings: mappings)
            let posted = posted, attribution = attribution
            engine = EventEngine(
                synthesizer: recorder, attribute: { _, _ in DeviceAttribution(id: ChordEngineTests.mouse, exact: true) },
                frontmostApp: { nil }, clock: clock,
                attributeChord: { _, _, _ in attribution.source },
                postChordEvent: { posted.append($0) }
            )
            engine.update(settings)
        }

        /// Sends one event through the tap. `same` is true when the tap handed on the very event it was given.
        @discardableResult
        func send(_ button: Int, _ phase: Phase, clickState: Int64 = 1, flags: CGEventFlags = []) -> (result: CGEvent?, same: Bool) {
            let (type, event) = ChordEngineTests.event(button, phase, clickState: clickState, flags: flags)
            let result = engine.handle(type, event)?.takeUnretainedValue()
            return (result, result === event)
        }

        /// Feeds what the router posted back through the tap, as the system does; it must pass untouched.
        func deliverPosted() {
            let events = posted.events
            for event in events[delivered...] {
                #expect(engine.handle(event.type, event)?.takeUnretainedValue() === event)
            }
            delivered = events.count
        }
    }

    static func settings(_ chords: [ButtonChord], allowPrimary: Bool, mappings: [Mapping] = []) -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = mappings
        settings.profiles[0].chords = chords
        settings.general.allowPrimaryButtonRemap = allowPrimary
        return settings
    }

    static func event(_ button: Int, _ phase: Phase, clickState: Int64 = 1, flags: CGEventFlags = []) -> (CGEventType, CGEvent) {
        let type: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case 0:
            mouseButton = .left
            type = phase == .down ? .leftMouseDown : phase == .up ? .leftMouseUp : .leftMouseDragged
        case 1:
            mouseButton = .right
            type = phase == .down ? .rightMouseDown : phase == .up ? .rightMouseUp : .rightMouseDragged
        default:
            mouseButton = .center
            type = phase == .down ? .otherMouseDown : phase == .up ? .otherMouseUp : .otherMouseDragged
        }
        let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: mouseButton)!
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        event.flags = flags
        return (type, event)
    }

    static func describe(_ event: CGEvent) -> String {
        let button = event.getIntegerValueField(.mouseEventButtonNumber)
        switch event.type {
        case .leftMouseDown, .rightMouseDown, .otherMouseDown: return "down \(button)"
        case .leftMouseUp, .rightMouseUp, .otherMouseUp: return "up \(button)"
        case .leftMouseDragged, .rightMouseDragged, .otherMouseDragged: return "drag \(button)"
        case .mouseMoved: return "move"
        default: return "other"
        }
    }

    // MARK: Recognition

    @Test(arguments: [(3, 4), (4, 3)])
    func eitherOrderRunsTheActionOnceAndSwallowsBothButtons(first: Int, second: Int) {
        let harness = Harness([Self.back])
        #expect(harness.send(first, .down).result == nil)
        #expect(harness.send(second, .down).result == nil)
        #expect(harness.recorder.calls == [.init(action: .navigate(.back), phase: .once, clickState: 1)])
        #expect(harness.send(first, .up).result == nil)
        #expect(harness.send(second, .up).result == nil)
        #expect(harness.posted.events.isEmpty)
        #expect(harness.clock.pending == 0)
        // Nothing is left over: an unrelated click goes straight through.
        #expect(harness.send(5, .down).same)
        #expect(harness.send(5, .up).same)
    }

    @Test(arguments: [(0, 1), (1, 0)])
    func thePresetPostsExactlyOneMiddleClickThroughADragAndEitherRelease(firstUp: Int, secondUp: Int) {
        let harness = Harness([.middleClick(modifiers: .option)])
        #expect(harness.send(0, .down, flags: .maskAlternate).result == nil)
        #expect(harness.send(1, .down, flags: .maskAlternate).result == nil)
        #expect(harness.posted.summary == ["down 2"])
        let down = harness.posted.events[0]
        #expect(down.getIntegerValueField(.eventSourceUserData) == ChordRouter.marker)
        #expect(down.flags.contains(.maskAlternate))
        #expect(down.location == Self.location)
        harness.deliverPosted()

        let dragged = harness.send(0, .drag, flags: .maskAlternate).result
        #expect(dragged?.type == .otherMouseDragged)
        #expect(dragged?.getIntegerValueField(.mouseEventButtonNumber) == 2)

        #expect(harness.send(firstUp, .up).result == nil)
        #expect(harness.posted.summary == ["down 2", "up 2"])
        harness.deliverPosted()
        #expect(harness.send(secondUp, .drag).result?.type == .mouseMoved)
        #expect(harness.send(secondUp, .up).result == nil)
        #expect(harness.posted.summary == ["down 2", "up 2"])
        #expect(harness.recorder.calls.isEmpty)
    }

    @Test func thePrimaryButtonIsOnlyHeldBackWithAModifierOrTheOptIn() {
        let protected = Harness([.middleClick()])
        #expect(protected.send(0, .down).same)
        #expect(protected.send(0, .up).same)
        #expect(protected.posted.events.isEmpty)

        let optedIn = Harness([.middleClick()], allowPrimary: true)
        #expect(optedIn.send(0, .down).result == nil)
        #expect(optedIn.send(1, .down).result == nil)
        #expect(optedIn.posted.summary == ["down 2"])
    }

    // MARK: Falling back

    @Test func aLonePressIsReplayedAfterTheWindowWithItsClickCountAndFlags() {
        var chord = Self.back
        chord.modifiers = .shift
        let harness = Harness([chord])
        #expect(harness.send(3, .down, clickState: 2, flags: .maskShift).result == nil)
        #expect(harness.posted.events.isEmpty)
        harness.clock.advance(by: 0.1)
        #expect(harness.posted.summary == ["down 3"])
        let replayed = harness.posted.events[0]
        #expect(replayed.getIntegerValueField(.mouseEventClickState) == 2)
        #expect(replayed.getIntegerValueField(.eventSourceUserData) == ChordRouter.marker)
        #expect(replayed.flags.contains(.maskShift))
        #expect(replayed.location == Self.location)
        harness.deliverPosted()
        #expect(harness.send(3, .up, clickState: 2).same)
        #expect(harness.recorder.calls.isEmpty)
    }

    @Test func aLonePressOfAMappedButtonStillRunsItsMapping() {
        let harness = Harness([Self.back], mappings: [Mapping(trigger: .button(3), action: .navigate(.forward))])
        #expect(harness.send(3, .down).result == nil)
        #expect(harness.recorder.calls.isEmpty)
        harness.clock.advance(by: 0.1)
        #expect(harness.recorder.calls.map(\.action) == [.navigate(.forward)])
        #expect(harness.posted.events.isEmpty)
        #expect(harness.send(3, .up).result == nil)
    }

    @Test func anEarlyReleaseReplaysThePressThenTheReleaseInOrder() {
        let harness = Harness([Self.back])
        #expect(harness.send(3, .down).result == nil)
        #expect(harness.send(3, .up).result == nil)
        #expect(harness.posted.summary == ["down 3", "up 3"])
        #expect(harness.clock.pending == 0)
    }

    @Test func movingWithTheButtonDownAbandonsTheChordInOrder() {
        let harness = Harness([Self.back])
        #expect(harness.send(3, .down).result == nil)
        #expect(harness.send(3, .drag).result == nil)
        #expect(harness.posted.summary == ["down 3", "drag 3"])
        harness.deliverPosted()
        #expect(harness.send(4, .down).same)
        #expect(harness.recorder.calls.isEmpty)
    }

    @Test func otherButtonsAndUnidentifiedPressesAreNeverHeldBack() {
        let harness = Harness([Self.back])
        #expect(harness.send(5, .down).same)
        #expect(harness.send(5, .up).same)
        // Two mice of the same model, a receiver or a report that came too late: nothing to attribute it to.
        harness.attribution.source = nil
        #expect(harness.send(3, .down).same)
        #expect(harness.send(4, .down).same)
        #expect(harness.send(4, .up).same)
        #expect(harness.send(3, .up).same)
        #expect(harness.posted.events.isEmpty)
        #expect(harness.recorder.calls.isEmpty)
        #expect(harness.clock.pending == 0)
    }

    @Test func aClickAfterAChordCountsFromOne() {
        let harness = Harness([Self.back])
        harness.send(3, .down)
        harness.send(4, .down)
        harness.send(3, .up)
        harness.send(4, .up)
        // The system counted the presses the chord used; the next press of the same button is a first click.
        #expect(harness.send(3, .down, clickState: 2).result == nil)
        harness.clock.advance(by: 0.1)
        #expect(harness.posted.events.first?.getIntegerValueField(.mouseEventClickState) == 1)
    }

    // MARK: Order

    @Test func laterEventsQueueBehindAReplayUntilItComesBack() {
        let harness = Harness([Self.back])
        harness.send(3, .down)
        harness.clock.advance(by: 0.1)
        #expect(harness.send(5, .down).result == nil)
        #expect(harness.posted.summary == ["down 3", "down 5"])
        harness.deliverPosted()
        #expect(harness.send(5, .up).same)
        #expect(harness.send(3, .up).same)
    }

    @Test func theQueueStopsWaitingForAReplayThatNeverComesBack() {
        let harness = Harness([Self.back])
        harness.send(3, .down)
        harness.clock.advance(by: 0.1)
        harness.clock.advance(by: ChordRouter.fenceTimeout)
        #expect(harness.send(5, .down).same)
    }

    // MARK: Interruptions

    @Test(arguments: ["front app", "recording", "settings", "disconnect", "sleep"])
    func anInterruptionNeverReplaysAHeldPressIntoANewContext(_ interruption: String) {
        let harness = Harness([Self.back])
        #expect(harness.send(3, .down).result == nil)
        Self.interrupt(harness, interruption)
        harness.clock.advance(by: 0.1)
        // Its release is swallowed too, unless releases may have been missed (sleep, a tap interruption): then
        // nothing is trusted to be held and it goes through unpaired rather than risk swallowing a later press.
        let release = harness.send(3, .up)
        #expect(interruption == "sleep" ? release.same : release.result == nil)
        #expect(harness.posted.events.isEmpty)
        #expect(harness.recorder.calls.isEmpty)
        if interruption == "recording" { harness.engine.setCapturing(false) }
        // The next attempt starts clean.
        harness.send(3, .down)
        harness.send(4, .down)
        #expect(harness.recorder.calls.map(\.action) == [.navigate(.back)])
    }

    @Test(arguments: ["front app", "recording", "settings", "disconnect", "sleep"])
    func anInterruptionLetsGoOfAHeldMiddleClickOnce(_ interruption: String) {
        let harness = Harness([.middleClick(modifiers: .option)])
        harness.send(0, .down, flags: .maskAlternate)
        harness.send(1, .down, flags: .maskAlternate)
        Self.interrupt(harness, interruption)
        #expect(harness.posted.summary == ["down 2", "up 2"])
        harness.deliverPosted()
        let releases = [harness.send(1, .up), harness.send(0, .up)]
        #expect(releases.allSatisfy { interruption == "sleep" ? $0.same : $0.result == nil })
        #expect(harness.posted.summary == ["down 2", "up 2"])
    }

    @Test func aMouseThatStaysConnectedKeepsItsPress() {
        let harness = Harness([Self.back])
        harness.send(3, .down)
        harness.engine.devicesChanged(connected: [Self.mouse])
        harness.clock.advance(by: 0.1)
        #expect(harness.posted.summary == ["down 3"])
    }

    static func interrupt(_ harness: Harness, _ interruption: String) {
        switch interruption {
        case "front app": harness.engine.frontmostAppChanged()
        case "recording": harness.engine.setCapturing(true)
        // Any change to the settings, even one that leaves the chords as they were.
        case "settings": harness.engine.update(harness.settings)
        case "disconnect": harness.engine.devicesChanged(connected: [])
        default: harness.engine.releaseAll(because: .quit)
        }
    }
}
