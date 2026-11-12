import Foundation
import Testing
@testable import WhiskerCore

@Suite("Battery status")
struct BatteryStatusTests {
    private func battery(
        _ page: Int = 0x06, _ usage: Int = 0x20, kind: HIDElementKind = .feature, min: Int = 0, max: Int = 100
    ) -> BatteryElement {
        BatteryElement(kind: kind, usagePage: page, usage: usage, logicalMin: min, logicalMax: max)
    }

    private let button = BatteryElement(kind: .input, usagePage: HIDUsage.buttonPage, usage: 1, logicalMin: 0, logicalMax: 1)

    private func candidate(_ interfaces: [(Int, BatteryDiscovery)], physical: Int = 1, product: String? = "Mouse") -> BatteryCandidate {
        candidate("046d:b034:A1", interfaces, physical: physical, product: product)
    }

    private func candidate(
        _ id: String, _ interfaces: [(Int, BatteryDiscovery)], physical: Int = 1, product: String? = "Mouse"
    ) -> BatteryCandidate {
        BatteryCandidate(
            deviceID: id, interfaces: interfaces.map { .init(runtimeID: $0.0, discovery: $0.1) },
            physicalDevices: physical, product: product
        )
    }

    private let readable = BatteryDiscovery.readable(percent: 0, charging: nil)

    // MARK: Discovery and validation

    @Test func onlyAZeroToHundredBatteryElementIsAPercentage() {
        #expect(BatteryDiscovery.discover([button, battery()]) == .readable(percent: 1, charging: nil))
        #expect(BatteryDiscovery.discover([battery(0x85, 0x65, kind: .input)]) == .readable(percent: 0, charging: nil))
        for range in [(0, 255), (0, 10), (1, 100), (0, 1000), (-100, 100)] {
            #expect(BatteryDiscovery.discover([battery(min: range.0, max: range.1)]) == .unrecognisedFormat)
        }
        #expect(BatteryDiscovery.discover([battery(kind: .output)]) == .unrecognisedFormat)
    }

    @Test func noBatteryElementIsNotSupportedAndNoDescriptionIsUndescribed() {
        #expect(BatteryDiscovery.discover([button]) == .notSupported)
        #expect(BatteryDiscovery.discover([]) == .undescribed)
        #expect(BatteryDiscovery.discover(nil) == .undescribed)
    }

    @Test func powerDeviceAndOtherBatteryUsagesAreNotMouseBatteries() {
        // A UPS reports on the Power Device page; remaining capacity and relative charge are not the validated source.
        #expect(BatteryDiscovery.discover([battery(0x84, 0x66)]) == .notSupported)
        #expect(BatteryDiscovery.discover([battery(0x85, 0x66), battery(0x85, 0x64)]) == .notSupported)
    }

    @Test func rawValuesOutsideTheRangeAreNeverPercentages() {
        #expect(BatteryDiscovery.percent(fromRaw: 0) == 0)
        #expect(BatteryDiscovery.percent(fromRaw: 100) == 100)
        #expect(BatteryDiscovery.percent(fromRaw: 101) == nil)
        #expect(BatteryDiscovery.percent(fromRaw: -1) == nil)
    }

    @Test func chargingIsOnlyKnownFromAnExplicitElementAndValue() {
        let withFlag = BatteryDiscovery.discover([battery(), battery(0x85, 0x44, kind: .input, max: 1)])
        #expect(withFlag == .readable(percent: 0, charging: 1))
        #expect(BatteryDiscovery.discover([battery()]) == .readable(percent: 0, charging: nil))
        // An invalid or duplicated flag is ignored rather than guessed at.
        #expect(BatteryDiscovery.discover([battery(), battery(0x85, 0x44, kind: .input, max: 3)]) == .readable(percent: 0, charging: nil))
        #expect(BatteryDiscovery.discover([battery(), battery(0x85, 0x44, kind: .input, max: 1), battery(0x85, 0x44, kind: .input, max: 1)]) == .readable(percent: 0, charging: nil))
        #expect(BatteryDiscovery.charging(fromRaw: 1) == true)
        #expect(BatteryDiscovery.charging(fromRaw: 0) == false)
        #expect(BatteryDiscovery.charging(fromRaw: 2) == nil)
        #expect(BatteryDiscovery.charging(fromRaw: nil) == nil)
    }

    @Test func twoPercentageElementsAreAmbiguous() {
        #expect(BatteryDiscovery.discover([battery(), battery(0x85, 0x65)]) == .ambiguous)
    }

    // MARK: Association

    @Test func aSingleReadableInterfaceIsTheSource() {
        #expect(BatterySource.resolve(candidate([(7, .notSupported), (8, .readable(percent: 3, charging: 4))])) == .readable(runtimeID: 8, percent: 3, charging: 4))
    }

    @Test func mergedIdenticalDevicesNeverShareAReading() {
        #expect(BatterySource.resolve(candidate("046d:b034", [(7, readable)], physical: 2)) == .unavailable(.ambiguousDevice))
    }

    @Test func receiversAndCompetingInterfacesAreAmbiguous() {
        #expect(BatterySource.resolve(candidate([(7, readable)], product: "USB Receiver")) == .unavailable(.ambiguousDevice))
        #expect(BatterySource.resolve(candidate([(7, readable), (8, readable)])) == .unavailable(.ambiguousDevice))
        #expect(BatterySource.resolve(candidate([(7, .ambiguous)])) == .unavailable(.ambiguousDevice))
        #expect(BatterySource.resolve(candidate([(7, .notSupported)], product: "USB Receiver")) == .notSupported)
    }

    @Test func unsupportedUnrecognisedAndUndescribedAreDistinct() {
        #expect(BatterySource.resolve(candidate([(7, .notSupported)])) == .notSupported)
        #expect(BatterySource.resolve(candidate([(7, .notSupported), (8, .unrecognisedFormat)])) == .unavailable(.unrecognisedFormat))
        #expect(BatterySource.resolve(candidate([(7, .undescribed)])) == .unavailable(.notDescribed))
        #expect(BatterySource.resolve(candidate([])) == .unavailable(.notDescribed))
    }

    // MARK: Tracking and states

    private func tracked(_ id: String = "a", runtime: Int = 1) -> (BatteryTracker, BatteryHandle) {
        var tracker = BatteryTracker()
        let handles = tracker.sync([candidate(id, [(runtime, .readable(percent: 0, charging: 1))])])
        return (tracker, handles[0])
    }

    private func state(_ tracker: BatteryTracker, _ id: String = "a", at time: TimeInterval = 0, allowed: Bool = true) -> BatteryState {
        tracker.state(for: id, at: time, inputMonitoringAllowed: allowed)
    }

    @Test func aConnectedReadableDeviceWaitsThenShowsAValidatedReading() {
        var (tracker, handle) = tracked()
        #expect(state(tracker) == .waiting)
        let r1 = tracker.complete(handle, .value(raw: 64, chargingRaw: nil), at: 10, date: Date(timeIntervalSince1970: 1))
        #expect(r1)
        #expect(state(tracker, at: 11) == .value(percent: 64, charging: nil))
        let r2 = tracker.complete(handle, .value(raw: 63, chargingRaw: 1), at: 12, date: Date(timeIntervalSince1970: 2))
        #expect(r2)
        #expect(state(tracker, at: 12) == .value(percent: 63, charging: true))
    }

    @Test func missingOrInvalidDataIsNeverZeroPercent() {
        var (tracker, handle) = tracked()
        tracker.complete(handle, .failed, at: 1, date: Date())
        #expect(state(tracker) == .unavailable(.readFailed))
        tracker.complete(handle, .value(raw: 250, chargingRaw: nil), at: 2, date: Date())
        #expect(state(tracker) == .unavailable(.invalidValue))
        // A bad value also drops the earlier good one instead of leaving it on display.
        tracker.complete(handle, .value(raw: 50, chargingRaw: nil), at: 3, date: Date())
        tracker.complete(handle, .value(raw: -3, chargingRaw: nil), at: 4, date: Date())
        #expect(state(tracker, at: 4) == .unavailable(.invalidValue))
    }

    @Test func aReadingGoesStaleAndKeepsItsTime() {
        var (tracker, handle) = tracked()
        let read = Date(timeIntervalSince1970: 500)
        tracker.complete(handle, .value(raw: 40, chargingRaw: 0), at: 100, date: read)
        #expect(tracker.nextStaleness(after: 100) == 100 + BatteryTracker.staleAfter)
        #expect(state(tracker, at: 100 + BatteryTracker.staleAfter - 1) == .value(percent: 40, charging: false))
        #expect(state(tracker, at: 100 + BatteryTracker.staleAfter) == .stale(percent: 40, charging: false, lastRead: read))
        #expect(tracker.nextStaleness(after: 100 + BatteryTracker.staleAfter) == nil)
    }

    @Test func aFailedReadAfterAGoodOneIsStale() {
        var (tracker, handle) = tracked()
        let read = Date(timeIntervalSince1970: 9)
        tracker.complete(handle, .value(raw: 40, chargingRaw: nil), at: 1, date: read)
        tracker.complete(handle, .failed, at: 2, date: Date())
        #expect(state(tracker, at: 2) == .stale(percent: 40, charging: nil, lastRead: read))
    }

    @Test func permissionOffHidesEverythingAndDisconnectedDevicesSayDisconnected() {
        var (tracker, handle) = tracked()
        tracker.complete(handle, .value(raw: 40, chargingRaw: nil), at: 1, date: Date())
        #expect(state(tracker, at: 1, allowed: false) == .unavailable(.inputMonitoringOff))
        tracker.sync([])
        #expect(state(tracker) == .disconnected)
        #expect(state(tracker, "never-seen") == .disconnected)
    }

    @Test func aLateReadAfterRemovalOrReconnectionIsRejected() {
        var (tracker, old) = tracked("a", runtime: 1)
        tracker.sync([])
        let r3 = tracker.complete(old, .value(raw: 90, chargingRaw: nil), at: 5, date: Date())
        #expect(!r3)
        #expect(state(tracker) == .disconnected)

        // The same device comes back as a new connection: the old handle can't fill it in.
        let fresh = tracker.sync([candidate("a", [(2, .readable(percent: 0, charging: nil))])])[0]
        #expect(fresh.generation != old.generation)
        let r4 = tracker.complete(old, .value(raw: 90, chargingRaw: nil), at: 6, date: Date())
        #expect(!r4)
        #expect(state(tracker, at: 6) == .waiting)
        let r5 = tracker.complete(fresh, .value(raw: 10, chargingRaw: nil), at: 7, date: Date())
        #expect(r5)
        #expect(state(tracker, at: 7) == .value(percent: 10, charging: nil))
    }

    @Test func aReadingNeverMovesToAnotherDevice() {
        var tracker = BatteryTracker()
        let handles = tracker.sync([
            candidate("a", [(1, .readable(percent: 0, charging: nil))]),
            candidate("b", [(2, .readable(percent: 0, charging: nil))]),
        ])
        tracker.complete(handles[0], .value(raw: 77, chargingRaw: nil), at: 1, date: Date())
        #expect(state(tracker, "a", at: 1) == .value(percent: 77, charging: nil))
        #expect(state(tracker, "b", at: 1) == .waiting)
        // A handle can't be used for another device's id.
        let forged = BatteryHandle(deviceID: "b", runtimeID: 1, generation: handles[0].generation)
        let r6 = tracker.complete(forged, .value(raw: 5, chargingRaw: nil), at: 2, date: Date())
        #expect(!r6)
        #expect(state(tracker, "b", at: 2) == .waiting)
    }

    @Test func aSyncThatChangesNothingKeepsTheReading() {
        var (tracker, handle) = tracked()
        tracker.complete(handle, .value(raw: 40, chargingRaw: nil), at: 1, date: Date())
        let again = tracker.sync([candidate("a", [(1, .readable(percent: 0, charging: 1))])])
        #expect(again == [handle])
        #expect(state(tracker, at: 1) == .value(percent: 40, charging: nil))
    }

    // MARK: Presentation and rows

    @Test func statesReadInPlainWords() {
        let time: (Date) -> String = { _ in "10:42" }
        #expect(BatteryState.notSupported.text(time: time) == "Not supported")
        #expect(BatteryState.waiting.text(time: time) == "Waiting for a reading")
        #expect(BatteryState.disconnected.text(time: time) == "Disconnected")
        #expect(BatteryState.unavailable(.inputMonitoringOff).text(time: time).hasPrefix("Unavailable — "))
        #expect(BatteryState.value(percent: 80, charging: nil).text(time: time) == "80%")
        #expect(BatteryState.value(percent: 80, charging: true).text(time: time) == "80%, charging")
        #expect(BatteryState.value(percent: 80, charging: false).text(time: time) == "80%, not charging")
        #expect(BatteryState.stale(percent: 80, charging: nil, lastRead: Date()).text(time: time) == "Stale — 80%, last read 10:42")
        #expect(BatteryState.waiting.inlineText(time: time) == nil)
        #expect(BatteryState.value(percent: 80, charging: nil).inlineText(time: time) == "Battery: 80%")
    }

    @Test func hostBatteryAndUpsNeverPopulateMouseRows() {
        let mouse = HIDInterfaceInfo(
            vendorID: 0x046D, productID: 0xB034, serial: "A1", product: "Mouse", transport: "Bluetooth Low Energy",
            locationID: nil, interfaceNumber: nil, primaryUsagePage: HIDUsage.genericDesktopPage, primaryUsage: HIDUsage.mouse
        )
        let devices = PointingDeviceClassifier.pointingDevices(from: [mouse])
        // A UPS and the host battery are not rows, and their elements are not an accepted source.
        let ups = BatteryDiscovery.discover([BatteryElement(kind: .feature, usagePage: 0x84, usage: 0x66, logicalMin: 0, logicalMax: 100)])
        #expect(ups == .notSupported)
        var tracker = BatteryTracker()
        tracker.sync([BatteryCandidate(deviceID: devices[0].id, interfaces: [.init(runtimeID: 1, discovery: ups)], physicalDevices: 1, product: "Mouse")])
        let states = BatteryStates.states(for: devices, tracker: tracker, at: 0, inputMonitoringAllowed: true)
        #expect(states == [devices[0].id: .notSupported])
    }

    @Test func detailsCarryBatteryStateAndRememberedMiceAreDisconnected() {
        let mouse = HIDInterfaceInfo(
            vendorID: 0x05AC, productID: 0x0269, serial: "S", product: "Magic Mouse", transport: "Bluetooth",
            locationID: nil, interfaceNumber: nil, primaryUsagePage: HIDUsage.genericDesktopPage, primaryUsage: HIDUsage.mouse
        )
        let devices = PointingDeviceClassifier.pointingDevices(from: [mouse])
        let id = devices[0].id
        let shown = DeviceDetailsBuilder.details(for: devices, identification: .listening, batteries: [id: .value(percent: 55, charging: nil)])
        #expect(shown[0].battery == .value(percent: 55, charging: nil))
        // Reading a touch mouse's battery leaves it excluded.
        #expect(shown[0].excludedKind == .touchMouse)
        #expect(DeviceDetailsBuilder.details(for: devices, identification: .listening)[0].battery == .unavailable(.notDescribed))
        #expect(DeviceDetailsBuilder.remembered(id: id, name: "x", identification: .listening).battery == .disconnected)
    }
}
