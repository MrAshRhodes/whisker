import Combine
import Foundation
import IOKit.hid
import Testing
@testable import Whisker
@testable import WhiskerCore

/// Stands in for macOS's HID stack. It logs everything input timing asks of it, so a test can see that a capture
/// only describes, listens and stops, and it delivers reports the way a HID queue would.
private final class FakeTimingAccess: HIDDeviceAccess {
    enum Call: Equatable {
        case register, forget(Int), elements(Int), read(Int), observe(Int), stop(Int)

        var isObserve: Bool {
            if case .observe = self { return true }
            return false
        }
    }

    private(set) var calls: [Call] = []
    var layouts: [Int: [HIDElementDescription]] = [:]
    /// Interfaces macOS would refuse to open.
    var refusing: Set<Int> = []
    private var listeners: [Int: (onReport: @Sendable (HIDReportTiming) -> Void, onEnd: () -> Void)] = [:]
    /// Every report handler ever given out, so a test can call an old one as a report already on its way would.
    private var handlers: [Int: [@Sendable (HIDReportTiming) -> Void]] = [:]

    var observed: Set<Int> { Set(listeners.keys) }

    func register(_ device: IOHIDDevice) -> Int {
        calls.append(.register)
        return 0
    }

    func forget(runtimeID: Int) {
        calls.append(.forget(runtimeID))
    }

    func elements(of runtimeID: Int) -> [HIDElementDescription]? {
        calls.append(.elements(runtimeID))
        return layouts[runtimeID]
    }

    func readValues(of runtimeID: Int, indexes: [Int], completion: @escaping ([Int?]) -> Void) {
        calls.append(.read(runtimeID))
        completion(indexes.map { _ in nil })
    }

    func observeReports(of runtimeID: Int, onReport: @escaping @Sendable (HIDReportTiming) -> Void, onEnd: @escaping () -> Void) -> Bool {
        calls.append(.observe(runtimeID))
        guard !refusing.contains(runtimeID), listeners[runtimeID] == nil else { return false }
        listeners[runtimeID] = (onReport, onEnd)
        handlers[runtimeID, default: []].append(onReport)
        return true
    }

    func stopObservingReports(of runtimeID: Int) {
        calls.append(.stop(runtimeID))
        listeners[runtimeID] = nil
    }

    /// Delivers a report to whoever is listening to the interface now. Nobody listening drops it, as macOS would.
    func emit(_ runtimeID: Int, reportID: Int = 0, ticks: UInt64) {
        listeners[runtimeID]?.onReport(HIDReportTiming(reportID: reportID, timestampTicks: ticks))
    }

    /// Delivers a report to an earlier listener, as one already on its way when that listener stopped would.
    func emitToEarlierListener(_ runtimeID: Int, registration: Int = 0, ticks: UInt64) {
        handlers[runtimeID]?[registration](HIDReportTiming(reportID: 0, timestampTicks: ticks))
    }

    /// The interface went away while it was being listened to.
    func end(_ runtimeID: Int) {
        listeners.removeValue(forKey: runtimeID)?.onEnd()
    }
}

private final class FakeTimingSource: InputTimingSource {
    var devices: [ConnectedDevice] = []
    var interfaces: [String: [InputTimingInterface]] = [:]

    func pointingInterfaces(ofDevice id: String) -> [InputTimingInterface] { interfaces[id] ?? [] }
}

@Suite("Input timing controller")
@MainActor
struct InputTimingControllerTests {
    // MARK: Fixtures

    private static func info(product: String, productID: Int, serial: String?, location: Int, transport: String = "USB") -> HIDInterfaceInfo {
        HIDInterfaceInfo(
            vendorID: 0x1234, productID: productID, serial: serial, product: product, transport: transport, locationID: location,
            interfaceNumber: 0, primaryUsagePage: HIDUsage.genericDesktopPage, primaryUsage: HIDUsage.mouse
        )
    }

    private static let mouseA = info(product: "Test Mouse A", productID: 1, serial: "A1", location: 0x100)
    private static let mouseB = info(product: "Test Mouse B", productID: 2, serial: "B2", location: 0x200)
    private static let trackpad = info(product: "Test Trackpad", productID: 4, serial: nil, location: 0x500, transport: "Bluetooth")
    /// Two identical mice without serial numbers list as one device that two physical mice share.
    private static func twin(location: Int) -> HIDInterfaceInfo { info(product: "Test Mouse C", productID: 3, serial: nil, location: location) }

    private static func element(_ kind: HIDElementKind = .input, page: Int, usage: Int, reportID: Int, topLevel: Int = HIDUsage.mouse) -> HIDElementDescription {
        HIDElementDescription(
            kind: kind, usagePage: page, usage: usage, logicalMin: 0, logicalMax: 1, reportID: reportID,
            topLevelUsagePage: HIDUsage.genericDesktopPage, topLevelUsage: topLevel
        )
    }

    /// A mouse's buttons and movement on each report id, plus the battery feature element many receivers add.
    private static func pointing(_ reportIDs: [Int] = [0]) -> [HIDElementDescription] {
        reportIDs.flatMap { reportID in
            [
                element(page: HIDUsage.buttonPage, usage: 1, reportID: reportID),
                element(page: HIDUsage.genericDesktopPage, usage: 0x30, reportID: reportID),
            ]
        } + [element(.feature, page: 0x06, usage: 0x20, reportID: 0x10)]
    }

    private static func keyboard(_ reportID: Int) -> [HIDElementDescription] {
        [element(page: 0x07, usage: 4, reportID: reportID, topLevel: HIDUsage.keyboard)]
    }

    private static func measurement(_ stream: InputTimingStreamResult) -> InputTimingMeasurement? {
        if case .measured(let measurement) = stream.summary { return measurement }
        return nil
    }

    // MARK: Harness

    private final class Harness {
        struct Mouse {
            var device: PointingDevice
            /// The runtime id of each pointing interface, in order.
            var interfaces: [Int]
            var id: String { device.id }
        }

        let access = FakeTimingAccess()
        let source = FakeTimingSource()
        let timebase: HIDTimebase
        var granted = true
        var permissionRequests = 0
        /// The clock, in mach ticks.
        var now: UInt64
        /// When the capture under test began, in ticks.
        var captureStart: UInt64 = 0
        var timers: [Int: () -> Void] = [:]
        var delays: [TimeInterval] = []
        var defersSummaries = false
        var deferredSummaries: [() -> Void] = []
        private var nextTimer = 0
        private var nextRuntimeID = 0
        var controller: InputTimingController!

        init(timebase: HIDTimebase = .identity, now: UInt64 = 6_000_000_000) {
            self.timebase = timebase
            self.now = now
            controller = InputTimingController(
                access: access, source: source,
                permissionGranted: { [unowned self] in granted },
                requestAccess: { [unowned self] in permissionRequests += 1 },
                ticks: { [unowned self] in self.now },
                timebase: timebase,
                schedule: { [unowned self] delay, action in
                    delays.append(delay)
                    nextTimer += 1
                    let id = nextTimer
                    timers[id] = action
                    return { [weak self] in self?.timers[id] = nil }
                },
                summarise: { [unowned self] work, done in
                    if defersSummaries {
                        deferredSummaries.append { done(work()) }
                    } else {
                        done(work())
                    }
                }
            )
        }

        /// Lists a device whose interfaces are described by `layouts` (nil: macOS describes nothing).
        func plug(_ infos: [HIDInterfaceInfo], layouts: [[HIDElementDescription]?], interfaceNumbers: [Int?]? = nil) -> Mouse {
            let device = PointingDeviceClassifier.pointingDevices(from: infos)[0]
            let numbers = interfaceNumbers ?? layouts.indices.map { Optional($0) }
            var runtimeIDs: [Int] = []
            var listed: [InputTimingInterface] = []
            for (index, layout) in layouts.enumerated() {
                nextRuntimeID += 1
                access.layouts[nextRuntimeID] = layout
                runtimeIDs.append(nextRuntimeID)
                listed.append(InputTimingInterface(runtimeID: nextRuntimeID, interfaceNumber: numbers[index]))
            }
            source.devices.append(device)
            source.interfaces[device.id] = listed
            return Mouse(device: device, interfaces: runtimeIDs)
        }

        func begin(_ mouse: Mouse) {
            controller.start(deviceID: mouse.id)
            captureStart = now
        }

        func ticks(nanoseconds: UInt64) -> UInt64 { nanoseconds * timebase.denominator / timebase.numerator }

        /// Moves the clock on and lets the one pending tick run, as the run loop would.
        func advance(by seconds: TimeInterval) {
            now += ticks(nanoseconds: UInt64(seconds * 1_000_000_000))
            guard let id = timers.keys.min(), let action = timers.removeValue(forKey: id) else { return }
            action()
        }

        /// Lets the sample run its whole length, one live update at a time.
        func runToCompletion() {
            for _ in 0..<100 where controller.isSampling { advance(by: 0.25) }
        }

        /// `count` reports of one stream, `interval` milliseconds apart, the first one that long after the capture began.
        func emitSteady(_ runtimeID: Int, reportID: Int = 0, count: Int, every interval: UInt64 = 8) {
            for index in 0..<count {
                access.emit(runtimeID, reportID: reportID, ticks: captureStart + ticks(nanoseconds: (UInt64(index) + 1) * interval * 1_000_000))
            }
        }

        func completeSummaries() {
            let pending = deferredSummaries
            deferredSummaries = []
            for summary in pending { summary() }
        }

        var finished: InputTimingCaptureResult? {
            if case .finished(let result) = controller.state { return result }
            return nil
        }
    }

    // MARK: Starting

    @Test func nothingIsDescribedOrOpenedUntilACaptureIsRequested() {
        let h = Harness()
        _ = h.plug([Self.mouseA], layouts: [Self.pointing()])

        h.controller.sheetOpened()
        h.controller.prepare()

        #expect(h.controller.state == .idle)
        #expect(!h.controller.isSampling)
        #expect(h.access.calls.isEmpty)
        #expect(h.timers.isEmpty)
    }

    @Test func inputMonitoringIsOnlyRequestedWhenTheUserChoosesIt() {
        let h = Harness()
        h.granted = false
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])

        h.controller.sheetOpened()
        #expect(h.controller.state == .needsPermission)
        h.controller.start(deviceID: mouse.id)
        #expect(h.controller.state == .needsPermission)
        #expect(h.access.calls.isEmpty)
        #expect(h.permissionRequests == 0)

        h.controller.requestPermission()
        #expect(h.permissionRequests == 1)
        #expect(h.controller.state == .needsPermission)

        // It was allowed in System Settings, and the app came forward again.
        h.granted = true
        h.controller.prepare()
        #expect(h.controller.state == .idle)
        h.begin(mouse)
        #expect(h.controller.isSampling)
        #expect(h.permissionRequests == 1)
    }

    @Test func aCaptureOnlyDescribesListensAndStopsWithoutSeizingTheDevice() {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing([0]), Self.pointing([1, 2])])
        let (first, second) = (mouse.interfaces[0], mouse.interfaces[1])

        h.begin(mouse)
        #expect(h.controller.state == .sampling(elapsed: 0, reportCount: 0))
        #expect(h.access.observed == [first, second])
        h.emitSteady(first, count: 5)
        h.controller.cancel()

        // No value is read and nothing is registered or forgotten: the seam has no way to write a report or a
        // property, so this log is everything a capture does to a device.
        #expect(h.access.calls == [.elements(first), .elements(second), .observe(first), .observe(second), .stop(first), .stop(second)])
        #expect(HIDReportObservation.openOptions & IOOptionBits(kIOHIDOptionsTypeSeizeDevice) == 0)
    }

    // MARK: What is timed

    @Test func interfacesAndReportIDsStayApartAndKeyboardReportsAreIgnored() throws {
        let h = Harness()
        let mouse = h.plug(
            [Self.mouseA], layouts: [Self.pointing([1, 2]) + Self.keyboard(3), Self.pointing()], interfaceNumbers: [0, nil]
        )
        let (first, second) = (mouse.interfaces[0], mouse.interfaces[1])

        h.begin(mouse)
        h.emitSteady(first, reportID: 1, count: 101, every: 8)
        h.emitSteady(first, reportID: 2, count: 61, every: 16)
        h.emitSteady(first, reportID: 3, count: 50)
        h.emitSteady(second, count: 81, every: 4)
        h.runToCompletion()

        let result = try #require(h.finished)
        #expect(result.duration == 10)
        #expect(result.streams.map(\.label) == ["Interface 0 · report ID 1", "Interface 0 · report ID 2", "Interface 2"])
        #expect(result.streams.map { Self.measurement($0)?.totalReports } == [101, 61, 81])
        #expect(result.streams.map { Self.measurement($0)?.distribution.medianMs } == [8, 16, 4])
    }

    @Test func aKeyboardInterfaceOnTheSameDeviceIsNeverOpened() throws {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing(), Self.keyboard(0)])
        let (first, second) = (mouse.interfaces[0], mouse.interfaces[1])

        h.begin(mouse)
        #expect(h.access.calls == [.elements(first), .elements(second), .observe(first)])
        h.emitSteady(second, count: 40)
        h.emitSteady(first, count: 40)
        h.runToCompletion()

        let result = try #require(h.finished)
        #expect(result.streams.map { Self.measurement($0)?.totalReports } == [40])
    }

    @Test func twoMiceAreNeverMixed() throws {
        let h = Harness()
        let a = h.plug([Self.mouseA], layouts: [Self.pointing()])
        let b = h.plug([Self.mouseB], layouts: [Self.pointing()])
        let (first, second) = (a.interfaces[0], b.interfaces[0])

        h.begin(a)
        h.controller.start(deviceID: b.id)
        #expect(h.access.observed == [first])
        h.emitSteady(first, count: 40)
        h.emitSteady(second, count: 70)
        h.runToCompletion()
        let resultA = try #require(h.finished)
        #expect(resultA.streams.map { Self.measurement($0)?.totalReports } == [40])

        h.controller.sheetClosed()
        h.begin(b)
        #expect(h.access.observed == [second])
        h.emitSteady(second, count: 70)
        h.emitSteady(first, count: 40)
        h.runToCompletion()
        let resultB = try #require(h.finished)
        #expect(resultB.streams.map { Self.measurement($0)?.totalReports } == [70])
        #expect(h.access.calls.filter { $0 == .observe(first) }.count == 1)
    }

    enum Refusal: CaseIterable {
        case trackpad, identicalMice, unplugged, undescribed, keyboardOnly, mixedReport

        var expected: InputTimingState {
            switch self {
            case .trackpad: .unavailable(.excluded)
            case .identicalMice: .unavailable(.indistinguishable)
            case .unplugged: .unavailable(.disconnected)
            case .undescribed: .unavailable(.noEligibleInterfaces(.undescribed))
            case .keyboardOnly: .unavailable(.noEligibleInterfaces(.noPointingReports))
            case .mixedReport: .unavailable(.noEligibleInterfaces(.cannotSeparate))
            }
        }
    }

    @Test(arguments: Refusal.allCases)
    func aDeviceThatCannotBeTimedHonestlyIsRefusedWithoutListeningToAnything(refusal: Refusal) {
        let h = Harness()
        let mouse: Harness.Mouse
        switch refusal {
        case .trackpad: mouse = h.plug([Self.trackpad], layouts: [Self.pointing()])
        case .identicalMice: mouse = h.plug([Self.twin(location: 0x300), Self.twin(location: 0x400)], layouts: [Self.pointing(), Self.pointing()])
        case .unplugged:
            mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])
            h.source.devices = []
        case .undescribed: mouse = h.plug([Self.mouseA], layouts: [nil])
        case .keyboardOnly: mouse = h.plug([Self.mouseA], layouts: [Self.keyboard(0)])
        case .mixedReport: mouse = h.plug([Self.mouseA], layouts: [Self.pointing() + Self.keyboard(0)])
        }

        h.begin(mouse)

        let listened = h.access.calls.contains { $0.isObserve }
        #expect(h.controller.state == refusal.expected)
        #expect(!h.controller.isSampling)
        #expect(!listened)
        #expect(h.timers.isEmpty)
    }

    @Test func failingToOpenALaterInterfaceStopsTheEarlierOnesAndLeavesNothingBehind() {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing(), Self.pointing(), Self.pointing()])
        let ids = mouse.interfaces
        h.access.refusing = [ids[2]]

        h.begin(mouse)

        #expect(h.controller.state == .unavailable(.couldNotOpen))
        #expect(h.access.calls == [
            .elements(ids[0]), .elements(ids[1]), .elements(ids[2]),
            .observe(ids[0]), .observe(ids[1]), .observe(ids[2]),
            .stop(ids[0]), .stop(ids[1]),
        ])
        #expect(h.access.observed.isEmpty)
        #expect(!h.controller.isSampling)
        #expect(h.timers.isEmpty)

        h.access.refusing = []
        h.begin(mouse)
        #expect(h.controller.isSampling)
        #expect(h.access.observed == Set(ids))
    }

    // MARK: Ending

    enum Ending: CaseIterable {
        case cancelled, sheetClosed, sleep, permissionLost, noLongerListed, interfacesChanged, observerEnded, shutdown

        /// What the sheet shows afterwards.
        var expected: InputTimingState {
            switch self {
            case .cancelled: .interrupted(.cancelled)
            case .sheetClosed, .shutdown: .idle
            case .sleep: .interrupted(.sleep)
            case .permissionLost: .interrupted(.permissionLost)
            case .noLongerListed: .interrupted(.disconnected)
            case .interfacesChanged, .observerEnded: .interrupted(.deviceChanged)
            }
        }
    }

    private func apply(_ ending: Ending, to h: Harness, mouse: Harness.Mouse) {
        switch ending {
        case .cancelled: h.controller.cancel()
        case .sheetClosed: h.controller.sheetClosed()
        case .sleep: h.controller.interrupt(.sleep)
        case .permissionLost:
            h.granted = false
            h.advance(by: 0.25)
        case .noLongerListed:
            h.source.devices = []
            h.advance(by: 0.25)
        case .interfacesChanged:
            h.source.interfaces[mouse.id] = [InputTimingInterface(runtimeID: 99, interfaceNumber: 0)]
            h.advance(by: 0.25)
        case .observerEnded: h.access.end(mouse.interfaces[0])
        case .shutdown: h.controller.shutdown()
        }
    }

    @Test(arguments: Ending.allCases)
    func everyWayOfEndingACaptureStopsListeningAndDiscardsIt(ending: Ending) {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing(), Self.pointing([1])])
        h.begin(mouse)
        h.emitSteady(mouse.interfaces[0], count: 40)
        h.emitSteady(mouse.interfaces[1], reportID: 1, count: 40)
        h.advance(by: 0.25)
        #expect(h.controller.state == .sampling(elapsed: 0.25, reportCount: 80))

        apply(ending, to: h, mouse: mouse)

        #expect(h.controller.state == ending.expected)
        #expect(!h.controller.isSampling)
        #expect(h.access.observed.isEmpty)
        #expect(h.timers.isEmpty)
    }

    @Test func aReportAlreadyOnItsWayCannotReachALaterCapture() throws {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])
        let id = mouse.interfaces[0]

        h.begin(mouse)
        h.emitSteady(id, count: 30)
        h.controller.cancel()
        h.access.emitToEarlierListener(id, ticks: h.captureStart + 500_000)

        h.begin(mouse)
        h.emitSteady(id, count: 45)
        h.access.emitToEarlierListener(id, ticks: h.captureStart + 600_000)
        h.runToCompletion()

        let result = try #require(h.finished)
        #expect(result.streams.map { Self.measurement($0)?.totalReports } == [45])
    }

    @Test(arguments: [Ending.cancelled, .sheetClosed])
    func aSummaryStillOnItsWayIsDroppedOnceTheUserCancelsOrCloses(ending: Ending) {
        let h = Harness()
        h.defersSummaries = true
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])
        h.begin(mouse)
        h.emitSteady(mouse.interfaces[0], count: 40)
        h.runToCompletion()

        // Time is up: listening has ended, and only the summary is still being worked out.
        #expect(!h.controller.isSampling)
        #expect(h.access.observed.isEmpty)
        #expect(h.finished == nil)

        apply(ending, to: h, mouse: mouse)
        h.completeSummaries()

        #expect(h.controller.state == ending.expected)
    }

    @Test func aSheetNeverShowsWhatAnEarlierOneLeftBehind() {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])

        h.controller.sheetOpened()
        h.begin(mouse)
        h.emitSteady(mouse.interfaces[0], count: 40)
        h.runToCompletion()
        #expect(h.finished != nil)

        // The app coming forward again leaves a result on show; a new sheet starts clean.
        h.controller.prepare()
        #expect(h.finished != nil)
        h.controller.sheetOpened()
        #expect(h.controller.state == .idle)

        h.controller.start(deviceID: "not connected")
        #expect(h.controller.state == .unavailable(.disconnected))
        h.controller.prepare()
        #expect(h.controller.state == .unavailable(.disconnected))
        h.controller.sheetOpened()
        #expect(h.controller.state == .idle)

        h.controller.sheetClosed()
        #expect(h.controller.state == .idle)
    }

    @Test func sleepWithNothingRunningChangesNothing() {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])

        h.controller.interrupt(.sleep)
        #expect(h.controller.state == .idle)

        h.begin(mouse)
        h.emitSteady(mouse.interfaces[0], count: 40)
        h.runToCompletion()
        let result = h.controller.state
        h.controller.interrupt(.sleep)
        #expect(h.controller.state == result)
    }

    // MARK: What the numbers are

    @Test func aQuietMouseGivesInsufficientDataForEveryStreamNotZero() throws {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing([1, 2])])

        h.begin(mouse)
        h.runToCompletion()

        let result = try #require(h.finished)
        #expect(result.streams.count == 2)
        for stream in result.streams {
            #expect(stream.summary == .insufficient(validSamples: 0, totalReports: 0, quality: InputTimingQuality()))
        }
    }

    @Test func reportsStampedOnAnotherClockAreFlaggedNotTimed() throws {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])
        let id = mouse.interfaces[0]

        h.begin(mouse)
        for index in 0..<40 { h.access.emit(id, ticks: 42 + UInt64(index)) }
        h.runToCompletion()

        let result = try #require(h.finished)
        #expect(result.streams.map(\.summary) == [.clockMismatch(totalReports: 40)])
    }

    @Test func timestampsAreConvertedWithTheMachTimebase() throws {
        let h = Harness(timebase: HIDTimebase(numerator: 125, denominator: 3))
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])

        h.begin(mouse)
        h.emitSteady(mouse.interfaces[0], count: 60, every: 8)
        h.runToCompletion()

        let result = try #require(h.finished)
        #expect(result.duration == 10)
        #expect(result.streams.map { Self.measurement($0)?.distribution.medianMs } == [8])
    }

    @Test func theSheetIsUpdatedAtAThrottledRateAndCountsOnlyPointingReports() {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing() + Self.keyboard(7)])
        let id = mouse.interfaces[0]
        var changes = 0
        let subscription = h.controller.objectWillChange.sink { changes += 1 }
        defer { subscription.cancel() }

        h.begin(mouse)
        let afterStart = changes
        h.emitSteady(id, count: 300)
        h.emitSteady(id, reportID: 7, count: 100)
        #expect(changes == afterStart)
        #expect(h.delays == [1 / InputTimingDefaults.liveUpdateHz])

        h.advance(by: 0.25)
        #expect(h.controller.state == .sampling(elapsed: 0.25, reportCount: 300))
        #expect(changes == afterStart + 1)
    }

    // MARK: Normal input handling

    @Test func aRunningCaptureLeavesRecentInputAndAttributionAlone() {
        let h = Harness()
        let mouse = h.plug([Self.mouseA], layouts: [Self.pointing()])
        let monitor = DeviceMonitor(hidAccess: h.access)
        var changes = 0
        monitor.onChange = { _ in changes += 1 }

        func input(at time: TimeInterval) -> (recent: Set<String>, button: DeviceAttribution?, wheel: DeviceAttribution?) {
            monitor.recordInput(from: mouse.id, at: time)
            return (monitor.recentInput, monitor.attribute(.button(0), at: time + 0.001), monitor.attribute(.wheel, at: time + 0.001))
        }

        let before = input(at: 100)
        h.begin(mouse)
        h.emitSteady(mouse.interfaces[0], count: 200)
        #expect(h.controller.isSampling)
        let during = input(at: 200)
        h.runToCompletion()
        let after = input(at: 300)

        #expect(before.recent == [mouse.id])
        for later in [during, after] {
            #expect(later.recent == before.recent)
            #expect(later.button == before.button)
            #expect(later.wheel == before.wheel)
        }
        #expect(changes == 0)
        #expect(!h.access.calls.contains(.register))
    }
}
