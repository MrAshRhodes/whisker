import Foundation
import os
import WhiskerCore

/// Runs one short Input Timing capture for the sheet in Devices: when each HID report from one mouse arrived.
///
/// It does nothing until `start` is called for a device, and a capture lives only until it finishes, is
/// cancelled, or anything makes it untrustworthy (the sheet closing, sleep, Input Monitoring going, the device
/// changing): then every observer is stopped and the raw timestamps are thrown away. Only the finished summary is
/// kept, in memory, until the sheet closes. Nothing is written to a device, saved or logged.
///
/// What counts as a measurement, which interfaces may be timed and how it is worded are `WhiskerCore`'s
/// (`InputTimingSummariser`, `InputTimingClassifier`, `InputTimingWording`). This only drives the capture, and
/// never touches the event tap or click attribution. Main thread only, apart from the report callback.
final class InputTimingController: ObservableObject {
    /// Runs `work` away from the main thread, then `done` on it.
    typealias Summarise = (@escaping @Sendable () -> InputTimingCaptureResult, @escaping (InputTimingCaptureResult) -> Void) -> Void

    @Published private(set) var state: InputTimingState = .idle

    private struct Plan {
        var runtimeID: Int
        var label: String
        var reportIDs: Set<Int>
    }

    private struct Capture {
        var deviceID: String
        var plans: [Plan]
        /// Every pointing interface the device had when the capture began, timed or not.
        var interfaceIDs: [Int]
        var startTicks: UInt64
        var gate: CaptureGate
        var cancelTick: () -> Void
    }

    private let access: HIDDeviceAccess
    private let source: InputTimingSource
    private let permissionGranted: () -> Bool
    private let requestAccess: () -> Void
    private let ticks: () -> UInt64
    private let timebase: HIDTimebase
    private let schedule: BatteryProvider.Scheduler
    private let summarise: Summarise
    private let duration: TimeInterval
    private var capture: Capture?
    /// Bumped whenever a capture starts or is abandoned, so a summary that finishes late is dropped.
    private var generation = 0

    init(
        access: HIDDeviceAccess, source: InputTimingSource,
        permissionGranted: @escaping () -> Bool, requestAccess: @escaping () -> Void,
        ticks: @escaping () -> UInt64 = { mach_absolute_time() },
        timebase: HIDTimebase = InputTimingController.systemTimebase(),
        schedule: @escaping BatteryProvider.Scheduler = InputTimingController.mainRunLoopSchedule,
        summarise: @escaping Summarise = InputTimingController.summariseInBackground,
        duration: TimeInterval = InputTimingDefaults.sampleDuration
    ) {
        self.access = access
        self.source = source
        self.permissionGranted = permissionGranted
        self.requestAccess = requestAccess
        self.ticks = ticks
        self.timebase = timebase
        self.schedule = schedule
        self.summarise = summarise
        self.duration = duration
    }

    var isSampling: Bool { capture != nil }

    /// The sheet opened: always starts clean, whatever an earlier sheet left behind, and shows whether a capture
    /// could start. Reads nothing from any device.
    func sheetOpened() {
        sheetClosed()
        prepare()
    }

    /// The app came back to the front, perhaps after Input Monitoring was allowed: shows whether a capture
    /// could start. Leaves a capture, a result or a reason already on show alone.
    func prepare() {
        switch state {
        case .idle, .needsPermission: state = permissionGranted() ? .idle : .needsPermission
        default: break
        }
    }

    /// Asks macOS for Input Monitoring. Only ever called from the user choosing to allow it.
    func requestPermission() {
        requestAccess()
        prepare()
    }

    /// Starts a capture on the user's explicit request. Refuses, with the reason, for anything that can't be
    /// timed honestly rather than timing something else.
    func start(deviceID: String) {
        guard capture == nil else { return }
        guard let device = source.devices.first(where: { $0.id == deviceID }) else { return unavailable(.disconnected) }
        guard !device.isExcluded else { return unavailable(.excluded) }
        guard device.physicalKeys.count <= 1 else { return unavailable(.indistinguishable) }
        guard permissionGranted() else {
            state = .needsPermission
            return
        }

        let interfaces = source.pointingInterfaces(ofDevice: deviceID)
        var plans: [Plan] = []
        var firstRejection: InputTimingRejection?
        for (ordinal, interface) in interfaces.enumerated() {
            let elements = access.elements(of: interface.runtimeID)?.map {
                InputTimingElement(kind: $0.kind, reportID: $0.reportID, topLevelUsagePage: $0.topLevelUsagePage, topLevelUsage: $0.topLevelUsage)
            }
            switch InputTimingClassifier.eligibility(of: elements) {
            case .eligible(let reportIDs):
                plans.append(Plan(runtimeID: interface.runtimeID, label: "Interface \(interface.interfaceNumber ?? ordinal + 1)", reportIDs: reportIDs))
            case .rejected(let rejection):
                firstRejection = firstRejection ?? rejection
            }
        }
        guard !plans.isEmpty else { return unavailable(.noEligibleInterfaces(firstRejection ?? .undescribed)) }

        let gate = CaptureGate(eligible: Dictionary(uniqueKeysWithValues: plans.map { ($0.runtimeID, $0.reportIDs) }), timebase: timebase)
        // Taken before anything listens, so no report can be stamped earlier than the window it is judged against.
        let startTicks = ticks()
        var observed: [Int] = []
        for plan in plans {
            let runtimeID = plan.runtimeID
            let listening = access.observeReports(
                of: runtimeID,
                onReport: { [gate] report in gate.accept(runtimeID: runtimeID, report) },
                onEnd: { [weak self] in self?.observerEnded() }
            )
            guard listening else {
                for started in observed { access.stopObservingReports(of: started) }
                _ = gate.close()
                return unavailable(.couldNotOpen)
            }
            observed.append(runtimeID)
        }
        generation += 1
        capture = Capture(
            deviceID: deviceID, plans: plans, interfaceIDs: interfaces.map(\.runtimeID), startTicks: startTicks, gate: gate,
            cancelTick: { }
        )
        state = .sampling(elapsed: 0, reportCount: 0)
        armTick()
    }

    /// The user cancelled: nothing is kept.
    func cancel() {
        discardCapture()
        guard case .sampling = state else { return }
        generation += 1
        state = .interrupted(.cancelled)
    }

    /// Something other than the user ended it (sleep, for one). Ignored when nothing is being captured.
    func interrupt(_ reason: InputTimingInterruption) {
        guard capture != nil else { return }
        discardCapture()
        state = .interrupted(reason)
    }

    /// The sheet went away: stop listening, forget everything, start over next time.
    func sheetClosed() {
        discardCapture()
        generation += 1
        state = .idle
    }

    func shutdown() {
        sheetClosed()
    }

    // MARK: Ticking

    private func armTick() {
        guard capture != nil else { return }
        let cancel = schedule(1 / InputTimingDefaults.liveUpdateHz) { [weak self] in self?.tick() }
        capture?.cancelTick = cancel
    }

    private func tick() {
        guard let capture else { return }
        if let reason = environmentInterruption(for: capture) { return interrupt(reason) }
        let elapsed = seconds(from: capture.startTicks, to: ticks())
        guard elapsed < duration else { return finish() }
        state = .sampling(elapsed: elapsed, reportCount: capture.gate.count)
        armTick()
    }

    /// An observed interface went away underneath the capture.
    private func observerEnded() {
        guard let capture else { return }
        interrupt(environmentInterruption(for: capture) ?? .deviceChanged)
    }

    /// Why the capture can no longer be trusted, if it can't be.
    private func environmentInterruption(for capture: Capture) -> InputTimingInterruption? {
        guard permissionGranted() else { return .permissionLost }
        guard let device = source.devices.first(where: { $0.id == capture.deviceID }) else { return .disconnected }
        guard !device.isExcluded, device.physicalKeys.count <= 1,
              source.pointingInterfaces(ofDevice: capture.deviceID).map(\.runtimeID) == capture.interfaceIDs
        else { return .deviceChanged }
        return nil
    }

    private func seconds(from start: UInt64, to end: UInt64) -> TimeInterval {
        Double(timebase.nanoseconds(fromTicks: end > start ? end - start : 0)) / 1_000_000_000
    }

    // MARK: Ending

    private func finish() {
        guard let capture else { return }
        let endTicks = ticks()
        discardObservers(of: capture)
        let recorder = capture.gate.close()
        self.capture = nil
        let window = InputTimingWindow(start: timebase.nanoseconds(fromTicks: capture.startTicks), end: timebase.nanoseconds(fromTicks: endTicks))
        let elapsed = seconds(from: capture.startTicks, to: endTicks)
        let plans = capture.plans
        generation += 1
        let token = generation
        state = .sampling(elapsed: elapsed, reportCount: recorder.timestampsNanoseconds.values.reduce(0) { $0 + $1.count })
        summarise({
            InputTimingCaptureResult(duration: elapsed, streams: plans.flatMap { plan in
                plan.reportIDs.sorted().map { reportID in
                    let key = InputTimingStreamKey(runtimeID: plan.runtimeID, reportID: reportID)
                    return InputTimingStreamResult(
                        label: reportID == 0 ? plan.label : "\(plan.label) · report ID \(reportID)",
                        summary: InputTimingSummariser.summarise(
                            timestampsNanoseconds: recorder.timestampsNanoseconds[key] ?? [], window: window,
                            overflowed: recorder.overflowed.contains(key)
                        )
                    )
                }
            })
        }, { [weak self] result in
            guard let self, self.generation == token else { return }
            self.state = .finished(result)
        })
    }

    private func discardCapture() {
        guard let capture else { return }
        self.capture = nil
        discardObservers(of: capture)
        _ = capture.gate.close()
    }

    private func discardObservers(of capture: Capture) {
        capture.cancelTick()
        for plan in capture.plans { access.stopObservingReports(of: plan.runtimeID) }
    }

    private func unavailable(_ reason: InputTimingUnavailableReason) {
        state = .unavailable(reason)
    }

    // MARK: Production defaults

    static func systemTimebase() -> HIDTimebase {
        var info = mach_timebase_info_data_t()
        mach_timebase_info(&info)
        return HIDTimebase(numerator: UInt64(info.numer), denominator: UInt64(info.denom))
    }

    static let mainRunLoopSchedule: BatteryProvider.Scheduler = { delay, action in
        let timer = Timer(timeInterval: delay, repeats: false) { _ in action() }
        RunLoop.main.add(timer, forMode: .common)
        return { timer.invalidate() }
    }

    static let summariseInBackground: Summarise = { work, done in
        DispatchQueue.global(qos: .utility).async {
            let result = work()
            DispatchQueue.main.async { done(result) }
        }
    }
}

/// Where the HID queue hands reports over: records each eligible one, by interface and report id, until closed.
/// Reports on a report id that isn't a pointing one are dropped before they are timed, so a keyboard collection
/// on the same interface contributes nothing. The lock is held for one append and nothing else.
private final class CaptureGate: @unchecked Sendable {
    private struct Inner {
        var accepting = true
        var recorder = InputTimingRecorder()
        var count = 0
    }

    private let inner = OSAllocatedUnfairLock(initialState: Inner())
    private let eligible: [Int: Set<Int>]
    private let timebase: HIDTimebase

    init(eligible: [Int: Set<Int>], timebase: HIDTimebase) {
        self.eligible = eligible
        self.timebase = timebase
    }

    func accept(runtimeID: Int, _ report: HIDReportTiming) {
        guard eligible[runtimeID]?.contains(report.reportID) == true else { return }
        let nanoseconds = timebase.nanoseconds(fromTicks: report.timestampTicks)
        inner.withLock { state in
            guard state.accepting else { return }
            state.recorder.append(nanoseconds, stream: InputTimingStreamKey(runtimeID: runtimeID, reportID: report.reportID))
            state.count += 1
        }
    }

    var count: Int { inner.withLock { $0.count } }

    /// Stops accepting and hands over what was recorded, leaving nothing behind.
    func close() -> InputTimingRecorder {
        inner.withLock { state in
            state.accepting = false
            let recorded = state.recorder
            state.recorder = InputTimingRecorder()
            return recorded
        }
    }
}
