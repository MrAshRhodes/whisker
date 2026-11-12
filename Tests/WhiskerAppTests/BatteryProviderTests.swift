import Foundation
import IOKit.hid
import Testing
@testable import Whisker
@testable import WhiskerCore

private final class FakeHIDAccess: HIDDeviceAccess {
    var layouts: [Int: [HIDElementDescription]?] = [:]
    var values: [Int: [Int?]] = [:]
    var pending: [(runtimeID: Int, indexes: [Int], completion: ([Int?]) -> Void)] = []
    var describeCalls = 0

    func register(_ device: IOHIDDevice) -> Int { 0 }
    func forget(runtimeID: Int) { layouts[runtimeID] = nil }

    func elements(of runtimeID: Int) -> [HIDElementDescription]? {
        describeCalls += 1
        return layouts[runtimeID] ?? nil
    }

    func readValues(of runtimeID: Int, indexes: [Int], completion: @escaping ([Int?]) -> Void) {
        pending.append((runtimeID, indexes, completion))
    }

    /// Completes the oldest outstanding read with the configured values.
    func finishOne() {
        let read = pending.removeFirst()
        read.completion(values[read.runtimeID] ?? read.indexes.map { _ in nil })
    }
}

@Suite("Battery provider")
@MainActor
struct BatteryProviderTests {
    private let battery = HIDElementDescription(kind: .feature, usagePage: 0x06, usage: 0x20, logicalMin: 0, logicalMax: 100)
    private let button = HIDElementDescription(kind: .input, usagePage: HIDUsage.buttonPage, usage: 1, logicalMin: 0, logicalMax: 1)

    private func mouse(serial: String? = "A1", location: Int? = 0x100) -> [PointingDevice] {
        PointingDeviceClassifier.pointingDevices(from: [HIDInterfaceInfo(
            vendorID: 0x046D, productID: 0xB034, serial: serial, product: "Mouse", transport: "Bluetooth Low Energy",
            locationID: location, interfaceNumber: nil, primaryUsagePage: HIDUsage.genericDesktopPage, primaryUsage: HIDUsage.mouse
        )])
    }

    private final class Harness {
        let access = FakeHIDAccess()
        var now: TimeInterval = 1_000
        var timers: [Int: () -> Void] = [:]
        var nextTimer = 0
        var changes = 0
        var provider: BatteryProvider!

        init() {
            provider = BatteryProvider(
                access: access, clock: { [unowned self] in now },
                schedule: { [unowned self] _, action in
                    nextTimer += 1
                    let id = nextTimer
                    timers[id] = action
                    return { [weak self] in self?.timers[id] = nil }
                }
            )
            provider.onChange = { [unowned self] in changes += 1 }
        }

        func state(_ device: PointingDevice, allowed: Bool = true) -> BatteryState {
            provider.tracker.state(for: device.id, at: now, inputMonitoringAllowed: allowed)
        }

        /// Fires the earliest outstanding timer, if any.
        @discardableResult func fireTimer() -> Bool {
            guard let id = timers.keys.min(), let action = timers.removeValue(forKey: id) else { return false }
            action()
            return true
        }
    }

    @Test func nothingIsDescribedOrReadUntilInputMonitoringIsAllowed() {
        let h = Harness()
        let device = mouse()
        h.access.layouts[1] = [battery]
        h.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: false)
        #expect(h.access.describeCalls == 0)
        #expect(h.access.pending.isEmpty)
        #expect(h.state(device[0], allowed: false) == .unavailable(.inputMonitoringOff))

        h.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: true)
        #expect(h.access.pending.count == 1)
        #expect(h.state(device[0]) == .waiting)
        h.access.values[1] = [72]
        h.access.finishOne()
        #expect(h.state(device[0]) == .value(percent: 72, charging: nil))
    }

    @Test func unsupportedMiceAreNeverRead() {
        let h = Harness()
        let device = mouse()
        h.access.layouts[1] = [button]
        h.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: true)
        #expect(h.access.pending.isEmpty)
        #expect(h.state(device[0]) == .notSupported)
    }

    @Test func aReadThatFinishesAfterRemovalIsDroppedAndItsTimerCancelled() {
        let h = Harness()
        let device = mouse()
        h.access.layouts[1] = [battery]
        h.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: true)
        h.provider.update(devices: [], interfaces: [:], allowed: true)
        h.access.values[1] = [50]
        h.access.finishOne()
        #expect(h.state(device[0]) == .disconnected)
        #expect(h.timers.isEmpty)
    }

    @Test func aReadFromBeforeAReconnectionNeverFillsTheNewConnection() {
        let h = Harness()
        let device = mouse()
        h.access.layouts[1] = [battery]
        h.access.layouts[2] = [battery]
        h.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: true)
        h.provider.update(devices: [], interfaces: [:], allowed: true)
        h.provider.update(devices: device, interfaces: [device[0].id: [2]], allowed: true)
        #expect(h.access.pending.count == 2)

        h.access.values[1] = [11]
        h.access.finishOne()
        #expect(h.state(device[0]) == .waiting)
        h.access.values[2] = [22]
        h.access.finishOne()
        #expect(h.state(device[0]) == .value(percent: 22, charging: nil))
    }

    @Test func identicalMiceWithoutSerialsAreNeverReadFromEitherInterface() {
        let h = Harness()
        let interfaces = [location(0x100), location(0x200)]
        let device = PointingDeviceClassifier.pointingDevices(from: interfaces)
        #expect(device.count == 1 && device[0].physicalKeys.count == 2)
        h.access.layouts[1] = [battery]
        h.access.layouts[2] = [battery]
        h.provider.update(devices: device, interfaces: [device[0].id: [1, 2]], allowed: true)
        #expect(h.access.pending.isEmpty)
        #expect(h.state(device[0]) == .unavailable(.ambiguousDevice))
    }

    private func location(_ id: Int) -> HIDInterfaceInfo {
        HIDInterfaceInfo(
            vendorID: 0x046D, productID: 0xB034, product: "Mouse", locationID: id, interfaceNumber: nil,
            primaryUsagePage: HIDUsage.genericDesktopPage, primaryUsage: HIDUsage.mouse
        )
    }

    @Test func timedRefreshIsBoundedAndStopsOnRemoval() {
        let h = Harness()
        let device = mouse()
        h.access.layouts[1] = [battery]
        h.access.values[1] = [80]
        h.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: true)
        var reads = 0
        var guardRail = 0
        while guardRail < 100 {
            guardRail += 1
            if !h.access.pending.isEmpty {
                reads += 1
                h.access.finishOne()
            } else {
                h.now += BatteryProvider.refreshInterval
                if !h.fireTimer() { break }
            }
        }
        #expect(reads == 1 + BatteryProvider.maxTimedRefreshes)
        #expect(guardRail < 100)

        let again = Harness()
        again.access.layouts[1] = [battery]
        again.access.values[1] = [80]
        again.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: true)
        again.access.finishOne()
        again.provider.update(devices: [], interfaces: [:], allowed: true)
        again.timers.removeAll()
        #expect(!again.fireTimer())
    }

    @Test func notificationsAndOpenedDetailsAreRateLimited() {
        let h = Harness()
        let device = mouse()
        h.access.layouts[1] = [battery]
        h.access.values[1] = [80]
        h.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: true)
        h.access.finishOne()
        h.provider.notified(runtimeID: 1)
        h.provider.refresh(deviceID: device[0].id)
        #expect(h.access.pending.isEmpty)

        h.now += BatteryProvider.minimumGap
        h.access.values[1] = [79]
        h.provider.notified(runtimeID: 1)
        h.provider.notified(runtimeID: 1)
        #expect(h.access.pending.count == 1)
        h.access.finishOne()
        #expect(h.state(device[0]) == .value(percent: 79, charging: nil))
        h.provider.notified(runtimeID: 99)
        #expect(h.access.pending.isEmpty)
    }

    @Test func aReadingGoesStaleWithoutAnyNewRead() {
        let h = Harness()
        let device = mouse()
        h.access.layouts[1] = [battery]
        h.access.values[1] = [80]
        h.provider.update(devices: device, interfaces: [device[0].id: [1]], allowed: true)
        h.access.finishOne()
        h.now += BatteryTracker.staleAfter + 1
        let before = h.changes
        while h.fireTimer() {}
        #expect(h.changes > before)
        guard case .stale(let percent, _, _) = h.state(device[0]) else { Issue.record("expected stale"); return }
        #expect(percent == 80)
    }
}
