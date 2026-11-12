import Foundation
import Testing
@testable import WhiskerCore

@Suite("Chord connection attribution")
struct ChordAttributionTests {
    private func info(_ token: UInt64, id: String = "46d:b034", vendor: Int = 0x46d, product: Int = 0xb034,
                      transport: String? = "Bluetooth Low Energy", location: Int? = 0x1234, excluded: Bool = false) -> ChordConnectionInfo {
        ChordConnectionInfo(token: token, deviceID: id, vendorID: vendor, productID: product, transport: transport,
                            locationID: location, excluded: excluded)
    }

    @Test func onlyALoneLocatedBluetoothMouseIsEligible() {
        let ball = info(1)
        #expect(ChordConnectionPolicy.eligibility(of: ball, among: [ball]) == .eligible)
        let usb = info(2, transport: "USB")
        #expect(ChordConnectionPolicy.eligibility(of: usb, among: [usb]) == .notBluetooth)
        let receiver = info(3, transport: nil)
        #expect(ChordConnectionPolicy.eligibility(of: receiver, among: [receiver]) == .notBluetooth)
        let unlocated = info(4, location: 0)
        #expect(ChordConnectionPolicy.eligibility(of: unlocated, among: [unlocated]) == .noLocation)
        let trackpad = info(5, excluded: true)
        #expect(ChordConnectionPolicy.eligibility(of: trackpad, among: [trackpad]) == .excluded)
    }

    @Test func identicalModelsFailOpenForBothEvenWithDifferentIDs() {
        let left = info(1, id: "46d:b034:AAA", location: 0x10)
        let right = info(2, id: "46d:b034:BBB", location: 0x20)
        let other = info(3, id: "5ac:269", vendor: 0x5ac, product: 0x269, location: 0x30)
        let all = [left, right, other]
        #expect(ChordConnectionPolicy.eligibility(of: left, among: all) == .sameModel)
        #expect(ChordConnectionPolicy.eligibility(of: right, among: all) == .sameModel)
        #expect(ChordConnectionPolicy.eligibility(of: other, among: all) == .eligible)
        #expect(ChordConnectionPolicy.eligibility(byDevice: all) == [
            "46d:b034:AAA": .sameModel, "46d:b034:BBB": .sameModel, "5ac:269": .eligible,
        ])
        // Two interfaces of one mouse share a location and stay eligible; an excluded twin doesn't count.
        let second = info(4, location: 0x1234)
        #expect(ChordConnectionPolicy.eligibility(of: info(1), among: [info(1), second, info(9, location: 0x99, excluded: true)]) == .eligible)
    }

    @Test func attributesEachTransitionOnceToTheOneConnectionThatReportedIt() {
        var attributor = ChordAttributor()
        attributor.update(connections: [info(1), info(2, id: "5ac:269", vendor: 0x5ac, product: 0x269, location: 0x30)])
        attributor.record(token: 1, button: 0, down: true, at: 10)
        attributor.record(token: 1, button: 0, down: true, at: 10.001)  // a repeated value is not a transition
        let source = attributor.attribute(button: 0, down: true, at: 10.03)
        #expect(source == ChordSource(connection: ChordConnection(token: 1), deviceID: "46d:b034"))
        #expect(attributor.attribute(button: 0, down: true, at: 10.03) == nil)
        attributor.record(token: 1, button: 0, down: false, at: 11)
        #expect(attributor.attribute(button: 0, down: true, at: 11) == nil)
        #expect(attributor.attribute(button: 0, down: false, at: 11.0301) == nil)
        #expect(attributor.attribute(button: 0, down: false, at: 11.02)?.connection == ChordConnection(token: 1))
    }

    @Test func simultaneousReportsFromTwoConnectionsAreAmbiguous() {
        var attributor = ChordAttributor()
        attributor.update(connections: [info(1), info(2, id: "5ac:269", vendor: 0x5ac, product: 0x269, location: 0x30)])
        attributor.record(token: 1, button: 1, down: true, at: 5)
        attributor.record(token: 2, button: 1, down: true, at: 5.002)
        #expect(attributor.attribute(button: 1, down: true, at: 5.003) == nil)
    }

    @Test func ineligibleOrForgottenConnectionsNeverAttribute() {
        var attributor = ChordAttributor()
        attributor.update(connections: [info(1, transport: "USB")])
        attributor.record(token: 1, button: 0, down: true, at: 1)
        #expect(attributor.attribute(button: 0, down: true, at: 1) == nil)
        attributor.update(connections: [info(2)])
        attributor.record(token: 1, button: 0, down: false, at: 2)
        attributor.record(token: 2, button: 0, down: true, at: 2)
        attributor.update(connections: [])
        #expect(attributor.attribute(button: 0, down: true, at: 2) == nil)
    }

    @Test func settlingForgetsUnattributedHoldsAndReleases() {
        let pair = ButtonChord(first: 3, second: 4, action: .click(button: 2, modifiers: []))
        let a = ChordConnection(token: 1)
        var r = ChordRecognizer<Int>()
        _ = r.process(.init(button: 5, phase: .down, connection: a, time: 1, payload: 1), chords: [pair])
        // Its release could not be attributed, so the recogniser still thinks button 5 is held.
        _ = r.process(.init(button: 5, phase: .up, connection: nil, time: 1.1, payload: 2), chords: [pair])
        #expect(r.process(.init(button: 3, phase: .down, connection: a, time: 1.2, payload: 3), chords: [pair]) == [.forward(3)])
        _ = r.process(.init(button: 3, phase: .up, connection: a, time: 1.3, payload: 4), chords: [pair])
        #expect(r.settle().isEmpty)
        #expect(r.process(.init(button: 3, phase: .down, connection: a, time: 1.4, payload: 5), chords: [pair]).isEmpty)
        #expect(r.pendingPayload == 5)
        #expect(!r.isIdle)
        #expect(r.settle().isEmpty)
        #expect(r.process(.init(button: 4, phase: .down, connection: a, time: 1.41, payload: 6), chords: [pair])
            == [.perform(.click(button: 2, modifiers: []), .down)])
        // Both releases went unattributed: once every button is up the hold ends once and nothing stays consumed.
        _ = r.process(.init(button: 3, phase: .up, connection: nil, time: 1.5, payload: 7), chords: [pair])
        _ = r.process(.init(button: 4, phase: .up, connection: nil, time: 1.5, payload: 8), chords: [pair])
        #expect(r.settle().isEmpty)
        #expect(r.isIdle)
        #expect(r.process(.init(button: 4, phase: .down, connection: a, time: 1.6, payload: 9), chords: [pair]).isEmpty)
    }
}
