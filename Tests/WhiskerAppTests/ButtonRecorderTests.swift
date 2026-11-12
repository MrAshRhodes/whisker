import AppKit
import CoreGraphics
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Button recorder")
@MainActor
struct ButtonRecorderTests {
    private func wheel(vertical: Int32, horizontal: Int32) throws -> NSEvent {
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0))
        return try #require(NSEvent(cgEvent: cgEvent))
    }

    @Test("Wheel notches record the same directions the event tap uses")
    func wheelDirections() throws {
        #expect(ButtonRecorder.trigger(for: try wheel(vertical: 1, horizontal: 0)) == .wheel(.up))
        #expect(ButtonRecorder.trigger(for: try wheel(vertical: -1, horizontal: 0)) == .wheel(.down))
        #expect(ButtonRecorder.trigger(for: try wheel(vertical: 0, horizontal: 1)) == .wheel(.left))
        #expect(ButtonRecorder.trigger(for: try wheel(vertical: 0, horizontal: -1)) == .wheel(.right))
    }

    @Test("Smooth trackpad scrolling isn't recorded as a wheel notch")
    func continuousScrollIgnored() throws {
        let cgEvent = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 1, wheel1: 12, wheel2: 0, wheel3: 0))
        cgEvent.setIntegerValueField(.scrollWheelEventIsContinuous, value: 1)
        #expect(ButtonRecorder.trigger(for: try #require(NSEvent(cgEvent: cgEvent))) == nil)
    }

    @Test("Mouse buttons record their number")
    func buttons() throws {
        let left = try #require(NSEvent.mouseEvent(with: .leftMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        let right = try #require(NSEvent.mouseEvent(with: .rightMouseDown, location: .zero, modifierFlags: [], timestamp: 0, windowNumber: 0, context: nil, eventNumber: 0, clickCount: 1, pressure: 1))
        #expect(ButtonRecorder.trigger(for: left) == .button(0))
        #expect(ButtonRecorder.trigger(for: right) == .button(1))

        let other = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        other.setIntegerValueField(.mouseEventButtonNumber, value: 4)
        #expect(ButtonRecorder.trigger(for: try #require(NSEvent(cgEvent: other))) == .button(4))
    }

    @Test("Mixed-axis and momentum scrolling aren't recorded as a wheel notch")
    func ambiguousScrollIgnored() throws {
        #expect(ButtonRecorder.trigger(for: try wheel(vertical: 1, horizontal: 1)) == nil)
        let coasting = try #require(CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: 0, wheel2: 1, wheel3: 0))
        coasting.setIntegerValueField(.scrollWheelEventMomentumPhase, value: 2)
        #expect(ButtonRecorder.trigger(for: try #require(NSEvent(cgEvent: coasting))) == nil)
    }

    @Test("The guided flow sees a horizontal notch as scrolling, never as a button")
    func tiltObservation() throws {
        let observation = try #require(TiltObserver.observation(for: try wheel(vertical: 0, horizontal: 1)))
        #expect(TiltClassifier.classify([observation]) == .horizontalScroll(.left))
        let other = try #require(CGEvent(mouseEventSource: nil, mouseType: .otherMouseDown, mouseCursorPosition: .zero, mouseButton: .center))
        other.setIntegerValueField(.mouseEventButtonNumber, value: 5)
        #expect(TiltObserver.observation(for: try #require(NSEvent(cgEvent: other))) == .buttonDown(5))
    }
}
