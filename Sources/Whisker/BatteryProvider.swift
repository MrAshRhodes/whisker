import Foundation
import WhiskerCore

/// Reads wireless mouse battery levels, best effort, and keeps them in memory.
///
/// It decides nothing itself: what counts as a percentage, who a reading may belong to and when it is stale are
/// `WhiskerCore`'s `BatteryDiscovery`, `BatterySource` and `BatteryTracker`. This only drives the reads. Main
/// thread only. It never writes to a device, never asks for a permission and never touches input handling.
///
/// Reads are bounded: one when a device connects (once Input Monitoring is allowed), one when the mouse reports
/// a new battery value, one when its details are opened (at most every `minimumGap`), and a timed refresh every
/// `refreshInterval` that stops after `maxTimedRefreshes`. Removing or reconnecting a device cancels its timer,
/// and a read that finishes afterwards is dropped.
final class BatteryProvider {
    static let refreshInterval: TimeInterval = 10 * 60
    static let maxTimedRefreshes = 12
    static let minimumGap: TimeInterval = 30

    /// Starts a one-shot timer and returns a function that cancels it.
    typealias Scheduler = (TimeInterval, @escaping () -> Void) -> () -> Void

    private let access: HIDDeviceAccess
    private let clock: () -> TimeInterval
    private let date: () -> Date
    private let schedule: Scheduler
    private(set) var tracker = BatteryTracker()
    /// Called when a state may have changed.
    var onChange: (() -> Void)?

    private struct Active {
        var handle: BatteryHandle
        var timedRefreshes = 0
        var lastRead: TimeInterval?
        var inFlight = false
        var cancelTimer: (() -> Void)?
    }

    private var active: [String: Active] = [:]
    private var discoveries: [Int: BatteryDiscovery] = [:]
    private var staleCancel: (() -> Void)?

    init(access: HIDDeviceAccess, clock: @escaping () -> TimeInterval, date: @escaping () -> Date = Date.init, schedule: @escaping Scheduler) {
        self.access = access
        self.clock = clock
        self.date = date
        self.schedule = schedule
    }

    /// Brings the readers in line with the listed devices. `interfaces` maps a device id to the runtime ids of
    /// the interfaces that belong to it. Without Input Monitoring nothing is described or read.
    func update(devices: [PointingDevice], interfaces: [String: [Int]], allowed: Bool) {
        let live = Set(interfaces.values.joined())
        discoveries = discoveries.filter { live.contains($0.key) }
        let candidates = devices.map { device in
            BatteryCandidate(
                deviceID: device.id,
                interfaces: (interfaces[device.id] ?? []).sorted().map { BatteryCandidate.Interface(runtimeID: $0, discovery: discovery(of: $0, allowed: allowed)) },
                physicalDevices: max(device.physicalKeys.count, 1),
                product: device.productName
            )
        }
        tracker.sync(candidates)
        let current = Dictionary(uniqueKeysWithValues: candidates.compactMap { tracker.handle(for: $0.deviceID) }.map { ($0.deviceID, $0) })
        for (id, entry) in active where current[id] != entry.handle {
            entry.cancelTimer?()
            active[id] = nil
        }
        if allowed {
            for (id, handle) in current where active[id] == nil {
                active[id] = Active(handle: handle)
                read(id, scheduled: false)
            }
        }
        armStaleness()
        onChange?()
    }

    private func discovery(of runtimeID: Int, allowed: Bool) -> BatteryDiscovery {
        guard allowed else { return .undescribed }
        if let known = discoveries[runtimeID], known != .undescribed { return known }
        let found = BatteryDiscovery.discover(access.elements(of: runtimeID)?.map {
            BatteryElement(kind: $0.kind, usagePage: $0.usagePage, usage: $0.usage, logicalMin: $0.logicalMin, logicalMax: $0.logicalMax)
        })
        discoveries[runtimeID] = found
        return found
    }

    /// The mouse reported a new battery value: read it again, at most once per `minimumGap`.
    func notified(runtimeID: Int) {
        guard let id = active.first(where: { $0.value.handle.runtimeID == runtimeID })?.key else { return }
        readIfOlder(id)
    }

    /// For when someone opens a device's details. Reads again unless a read happened in the last `minimumGap`.
    func refresh(deviceID: String) {
        guard active[deviceID] != nil else { return }
        readIfOlder(deviceID)
    }

    private func readIfOlder(_ id: String) {
        guard let entry = active[id], !entry.inFlight else { return }
        if let last = entry.lastRead, clock() - last < Self.minimumGap { return }
        read(id, scheduled: false)
    }

    private func read(_ id: String, scheduled: Bool) {
        guard var entry = active[id], !entry.inFlight, let elements = tracker.elements(for: entry.handle) else { return }
        entry.inFlight = true
        entry.lastRead = clock()
        if scheduled { entry.timedRefreshes += 1 }
        entry.cancelTimer?()
        entry.cancelTimer = nil
        active[id] = entry
        let handle = entry.handle
        let indexes = [elements.percent] + (elements.charging.map { [$0] } ?? [])
        access.readValues(of: handle.runtimeID, indexes: indexes) { [weak self] values in
            self?.finished(handle, values)
        }
    }

    private func finished(_ handle: BatteryHandle, _ values: [Int?]) {
        let outcome: BatteryReadOutcome
        if let raw = values.first ?? nil {
            outcome = .value(raw: raw, chargingRaw: values.count > 1 ? values[1] : nil)
        } else {
            outcome = .failed
        }
        guard tracker.complete(handle, outcome, at: clock(), date: date()) else { return }
        guard var entry = active[handle.deviceID], entry.handle == handle else { return }
        entry.inFlight = false
        if entry.timedRefreshes < Self.maxTimedRefreshes {
            let id = handle.deviceID
            entry.cancelTimer = schedule(Self.refreshInterval) { [weak self] in
                guard let self, self.active[id]?.handle == handle else { return }
                self.active[id]?.cancelTimer = nil
                self.read(id, scheduled: true)
            }
        }
        active[handle.deviceID] = entry
        armStaleness()
        onChange?()
    }

    /// Republishes once, when the oldest good reading goes stale.
    private func armStaleness() {
        staleCancel?()
        staleCancel = nil
        let now = clock()
        guard let due = tracker.nextStaleness(after: now) else { return }
        staleCancel = schedule(due - now + 0.1) { [weak self] in
            self?.staleCancel = nil
            self?.armStaleness()
            self?.onChange?()
        }
    }

    func stop() {
        for entry in active.values { entry.cancelTimer?() }
        active = [:]
        staleCancel?()
        staleCancel = nil
    }
}
