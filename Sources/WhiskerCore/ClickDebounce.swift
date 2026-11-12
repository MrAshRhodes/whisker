import Foundation

/// An opt-in filter for very short duplicate clicks from one mouse: a press that follows the release of the
/// previous click within `interval`, and is itself let go within `interval`, is dropped together with its release.
///
/// Timing alone can't tell chatter from an intentional fast double-click, so a real double-click quicker than the
/// interval is filtered too. The interval is deliberately short and the filter is off unless buttons are listed.
public struct ClickDebounceSettings: Equatable, Sendable {
    /// Seconds. Anything longer would start eating deliberate clicks, anything shorter catches nothing useful.
    public static let intervalRange: ClosedRange<Double> = 0.02...0.10
    public static let defaultInterval: Double = 0.05
    /// Physical buttons the filter may be switched on for.
    public static let buttonRange: ClosedRange<Int> = 0...31

    /// Buttons the filter applies to. Empty means off.
    public var buttons: [Int]
    public var interval: Double

    public init(buttons: [Int] = [], interval: Double = ClickDebounceSettings.defaultInterval) {
        self.buttons = buttons
        self.interval = interval
    }

    public var isEnabled: Bool { !buttons.isEmpty }

    /// Buttons sorted, each once and in range; the interval clamped. Non-finite intervals become the default.
    public var normalised: ClickDebounceSettings {
        let interval = self.interval.isFinite ? Self.intervalRange.clamp(self.interval) : Self.defaultInterval
        return ClickDebounceSettings(buttons: Array(Set(buttons.filter(Self.buttonRange.contains))).sorted(), interval: interval)
    }
}

/// A press the filter held back and now lets through, in the order it must be handled.
public struct FlushedPress: Equatable, Sendable {
    public var event: InputEvent
    /// The click count to carry, adjusted for presses the filter dropped before it.
    public var clickCount: Int64

    public init(event: InputEvent, clickCount: Int64) {
        self.event = event
        self.clickCount = clickCount
    }
}

/// What to do with the event just fed to `ClickDebouncer.process`.
public enum ClickDebounceDecision: Equatable, Sendable {
    /// Carry on to the mapping stage with this click count (the original one unless presses were dropped).
    case proceed(clickCount: Int64)
    /// Drop the event: it belongs to a press or release the filter removed.
    case drop
    /// Turn the drag into plain movement: its press was held back and never reached an app.
    case moveOnly
}

public struct ClickDebounceOutcome: Equatable, Sendable {
    /// Presses held back earlier that must be handled now, before the event itself.
    public var flushed: [FlushedPress]
    public var decision: ClickDebounceDecision
}

/// Decides, event by event, which presses to drop as duplicates. Pure state: the caller supplies timestamps,
/// handles the presses it is handed back in order and arms a timer for `nextDeadline`.
///
/// State is kept per device and physical button. The first click is never delayed; only a press that follows
/// a release closely is held, for at most `interval`, and then either dropped together with its release or
/// flushed (a long hold, a drag, any other input, expiry). A press that was delivered always has its release
/// delivered; a press that was dropped never has its release delivered.
public struct ClickDebouncer: Sendable {
    struct Key: Hashable, Sendable {
        var device: String
        var button: Int
    }

    private struct Pending: Sendable {
        var event: InputEvent
        var interval: TimeInterval
        var clickCount: Int64
    }

    private enum Phase: Sendable {
        /// The press reached the app; its release must too.
        case delivered(clickCount: Int64)
        case pending(Pending)
        /// The press was dropped (or held back and discarded) but the button may still be down.
        case orphaned
    }

    private var phases: [Key: Phase] = [:]
    private var lastRelease: [Key: TimeInterval] = [:]
    /// Presses dropped since the last one delivered, so the count of the next one can be put right.
    private var dropped: [Key: Int64] = [:]
    /// The local test in Devices, while one runs: what happened to one mouse's presses, counted and nothing more.
    public private(set) var test: ClickFilterTally?

    public init() {}

    /// Whether any press is being held back.
    public var hasPending: Bool { phases.values.contains { if case .pending = $0 { true } else { false } } }

    /// When the oldest held press must be let through, or nil when none is held.
    public var nextDeadline: TimeInterval? {
        phases.values.compactMap { phase -> TimeInterval? in
            guard case .pending(let pending) = phase else { return nil }
            return pending.event.timestamp + pending.interval
        }.min()
    }

    /// A safety escape is delivered immediately, but still tracks its matching release and flushes older input.
    public mutating func process(_ event: InputEvent, settings: CompiledSettings, preservingPress: Bool = false) -> ClickDebounceOutcome {
        switch event.kind {
        case .buttonDown(let button): return down(button, event, settings, preservingPress: preservingPress)
        case .buttonUp(let button): return up(button, event)
        case .buttonDragged(let button): return dragged(button, event)
        case .scroll: return ClickDebounceOutcome(flushed: flushPending(except: nil), decision: .proceed(clickCount: event.clickCount))
        }
    }

    /// Lets through every held press whose interval is over at `now`. A clock that went backwards counts as over.
    public mutating func expire(now: TimeInterval) -> [FlushedPress] {
        var due: [Key] = []
        for (key, phase) in phases {
            guard case .pending(let pending) = phase else { continue }
            let age = now - pending.event.timestamp
            if !age.isFinite || age < 0 || age >= pending.interval { due.append(key) }
        }
        return deliver(due)
    }

    /// Forgets what it holds for bypass, disabling, sleep, recording a button or a paused tap, and the local test
    /// starts again from zero. A held press is discarded whole: its button is remembered, so the release that is
    /// still to come is dropped with it. A paused tap may have missed that release, so letting the press through
    /// instead could leave the button down in the app.
    ///
    /// The system keeps counting a run of clicks across all this, so presses the app never saw still put the
    /// count of the next press of the run right, even once the filter is off.
    public mutating func reset() {
        discardHeld()
        test?.clear()
    }

    /// Settings changed: what is held is discarded as in `reset()`. The local test ends once the filter is off for
    /// its mouse, and starts again from zero only when something that decides what the filter does with that
    /// mouse changed.
    public mutating func settingsChanged(from old: CompiledSettings, to new: CompiledSettings) {
        discardHeld()
        guard let device = test?.device else { return }
        let scope = Self.scope(new, device)
        guard let buttons = scope.config?.buttons, !buttons.isEmpty else {
            test = nil
            return
        }
        if scope != Self.scope(old, device) { test = ClickFilterTally(device: device, buttons: buttons) }
    }

    /// Forgets mice that are no longer connected. A mouse that is gone can't send the release, so nothing waits for
    /// it, and a test of it ends.
    public mutating func devicesChanged(connected: Set<String>) {
        phases = phases.filter { connected.contains($0.key.device) }
        lastRelease = lastRelease.filter { connected.contains($0.key.device) }
        dropped = dropped.filter { connected.contains($0.key.device) }
        if let device = test?.device, !connected.contains(device) { test = nil }
    }

    /// While events pass through untouched (recording a button, the tap stopping), the release of a press the
    /// filter discarded is still dropped, so nothing ever sees an up without its down.
    public mutating func dropsOrphanedRelease(_ event: InputEvent) -> Bool {
        guard case .buttonUp(let button) = event.kind, let key = resolve(button, event), case .orphaned = phases[key] else { return false }
        phases[key] = nil
        return true
    }

    // MARK: Local test

    /// Starts the local test of one mouse from zero, ending any other. Nothing is counted while the filter is off
    /// for that mouse, so then there is no test.
    public mutating func startTest(device: String, settings: CompiledSettings) {
        guard let buttons = Self.scope(settings, device).config?.buttons, !buttons.isEmpty else {
            test = nil
            return
        }
        test = ClickFilterTally(device: device, buttons: buttons)
    }

    public mutating func stopTest() {
        test = nil
    }

    public mutating func clearTest() {
        test?.clear()
    }

    // MARK: Events

    private mutating func down(_ button: Int, _ event: InputEvent, _ settings: CompiledSettings, preservingPress: Bool) -> ClickDebounceOutcome {
        let flushed = flushPending(except: nil)
        // A press with no release in between: whatever was waiting for one is over.
        for key in Array(phases.keys) where key.button == button && (event.device.map { $0.id == key.device } ?? true) { phases[key] = nil }

        guard let (key, interval) = candidate(button, event, settings) else {
            return ClickDebounceOutcome(flushed: flushed, decision: .proceed(clickCount: unfiltered(button, event)))
        }
        if !preservingPress, let last = lastRelease[key] {
            let gap = event.timestamp - last
            if gap.isFinite, gap >= 0, gap < interval {
                phases[key] = .pending(Pending(event: event, interval: interval, clickCount: event.clickCount))
                return ClickDebounceOutcome(flushed: flushed, decision: .drop)
            }
        }
        // A click count of 1 starts a new run of clicks in the app, whatever was dropped before.
        if event.clickCount <= 1 { dropped[key] = nil }
        let count = adjusted(event.clickCount, key)
        phases[key] = .delivered(clickCount: count)
        judge(.accepted, key)
        return ClickDebounceOutcome(flushed: flushed, decision: .proceed(clickCount: count))
    }

    /// The count for a press the filter doesn't apply to. While its button has presses dropped earlier in the same
    /// run of clicks (the filter was switched off since, or the press no longer carries a modifier), the count is
    /// still put right, and its release and drags carry the same count. A source that isn't known exactly keeps
    /// its own count: the filter never guesses which mouse it is.
    private mutating func unfiltered(_ button: Int, _ event: InputEvent) -> Int64 {
        guard let device = event.device, device.exact else { return event.clickCount }
        let key = Key(device: device.id, button: button)
        judge(.accepted, key)
        guard dropped[key] != nil else { return event.clickCount }
        guard event.clickCount > 1 else {
            dropped[key] = nil
            return event.clickCount
        }
        let count = adjusted(event.clickCount, key)
        phases[key] = .delivered(clickCount: count)
        return count
    }

    private mutating func up(_ button: Int, _ event: InputEvent) -> ClickDebounceOutcome {
        guard let key = resolve(button, event) else {
            return ClickDebounceOutcome(flushed: flushPending(except: nil), decision: .proceed(clickCount: event.clickCount))
        }
        let flushed = flushPending(except: key)
        switch phases[key] {
        case .pending(let pending):
            let hold = event.timestamp - pending.event.timestamp
            if hold.isFinite, hold >= 0, hold < pending.interval {
                phases[key] = nil
                dropped[key, default: 0] += 1
                judge(.filtered, key)
                return ClickDebounceOutcome(flushed: flushed, decision: .drop)
            }
            let late = deliverPending(key).map { [$0] } ?? []
            phases[key] = nil
            lastRelease[key] = event.timestamp
            return ClickDebounceOutcome(flushed: flushed + late, decision: .proceed(clickCount: late.first?.clickCount ?? event.clickCount))
        case .delivered(let count):
            phases[key] = nil
            lastRelease[key] = event.timestamp
            return ClickDebounceOutcome(flushed: flushed, decision: .proceed(clickCount: count))
        case .orphaned:
            phases[key] = nil
            return ClickDebounceOutcome(flushed: flushed, decision: .drop)
        case nil:
            return ClickDebounceOutcome(flushed: flushed, decision: .proceed(clickCount: event.clickCount))
        }
    }

    private mutating func dragged(_ button: Int, _ event: InputEvent) -> ClickDebounceOutcome {
        guard let key = resolve(button, event) else {
            return ClickDebounceOutcome(flushed: flushPending(except: nil), decision: .proceed(clickCount: event.clickCount))
        }
        let flushed = flushPending(except: key)
        switch phases[key] {
        case .pending:
            // Click and drag: the press is let through first, then the drag carries on from it.
            let own = deliverPending(key).map { [$0] } ?? []
            return ClickDebounceOutcome(flushed: flushed + own, decision: .proceed(clickCount: own.first?.clickCount ?? event.clickCount))
        case .delivered(let count):
            return ClickDebounceOutcome(flushed: flushed, decision: .proceed(clickCount: count))
        case .orphaned:
            return ClickDebounceOutcome(flushed: flushed, decision: .moveOnly)
        case nil:
            return ClickDebounceOutcome(flushed: flushed, decision: .proceed(clickCount: event.clickCount))
        }
    }

    // MARK: Helpers

    /// The key and interval when this press is one the filter applies to: Whisker and the device are on, the app
    /// isn't bypassed, the device is known exactly, the button is listed and it isn't the protected primary button.
    private func candidate(_ button: Int, _ event: InputEvent, _ settings: CompiledSettings) -> (Key, TimeInterval)? {
        guard settings.general.enabled, !settings.isBypassed(app: event.app),
              let attribution = event.device, attribution.exact,
              settings.settings.devices[attribution.id]?.enabled != false,
              let config = settings.settings.devices[attribution.id]?.clickDebounce?.normalised,
              config.buttons.contains(button) else { return nil }
        if button == 0, event.modifiers.withoutFunction.isEmpty, !settings.general.allowPrimaryButtonRemap { return nil }
        return (Key(device: attribution.id, button: button), config.interval)
    }

    /// The tracked press an up or drag belongs to. An exactly attributed event belongs to its own mouse and never
    /// to another's, tracked or not. Otherwise the button has to be tracked for exactly one device, or the event
    /// is treated as unrelated: the filter never guesses between two presses.
    private func resolve(_ button: Int, _ event: InputEvent) -> Key? {
        if let device = event.device, device.exact {
            let key = Key(device: device.id, button: button)
            return phases[key] != nil ? key : nil
        }
        let matches = phases.keys.filter { $0.button == button }
        guard matches.count == 1, let key = matches.first else { return nil }
        // A source inferred to be a different mouse is not this press's release either.
        if let device = event.device, device.id != key.device { return nil }
        return key
    }

    private func adjusted(_ count: Int64, _ key: Key) -> Int64 {
        max(1, count - (dropped[key] ?? 0))
    }

    /// Counts a press for the local test when it is one of the mouse under test.
    private mutating func judge(_ verdict: ClickFilterTally.Verdict, _ key: Key) {
        guard test?.device == key.device else { return }
        test?.record(verdict, button: key.button)
    }

    /// Discards held presses whole (see `reset()`) and forgets delivered ones and when buttons were let go.
    private mutating func discardHeld() {
        for (key, phase) in phases {
            switch phase {
            case .pending:
                phases[key] = .orphaned
                // The system counted it, the app never sees it.
                dropped[key, default: 0] += 1
            case .delivered:
                phases[key] = nil
            case .orphaned:
                break
            }
        }
        lastRelease.removeAll()
    }

    /// Everything that decides what the filter does with one mouse's presses.
    private struct Scope: Equatable {
        var enabled: Bool
        var allowPrimaryButtonRemap: Bool
        var bypassApps: [String]
        var deviceEnabled: Bool
        var config: ClickDebounceSettings?
    }

    private static func scope(_ settings: CompiledSettings, _ device: String) -> Scope {
        let general = settings.general
        let config = settings.settings.devices[device]?.clickDebounce?.normalised
        return Scope(
            enabled: general.enabled, allowPrimaryButtonRemap: general.allowPrimaryButtonRemap, bypassApps: general.bypassApps,
            deviceEnabled: settings.settings.devices[device]?.enabled != false, config: config?.isEnabled == true ? config : nil
        )
    }

    private func pendingTime(_ key: Key) -> TimeInterval {
        if case .pending(let pending) = phases[key] { return pending.event.timestamp }
        return 0
    }

    private mutating func flushPending(except spared: Key?) -> [FlushedPress] {
        let keys = phases.compactMap { key, phase -> Key? in
            guard key != spared, case .pending = phase else { return nil }
            return key
        }
        return deliver(keys)
    }

    /// Delivers the held presses of `keys`, oldest first.
    private mutating func deliver(_ keys: [Key]) -> [FlushedPress] {
        var result: [FlushedPress] = []
        for key in keys.sorted(by: { pendingTime($0) < pendingTime($1) }) {
            if let press = deliverPending(key) { result.append(press) }
        }
        return result
    }

    /// Turns a held press into a delivered one.
    private mutating func deliverPending(_ key: Key) -> FlushedPress? {
        guard case .pending(let pending) = phases[key] else { return nil }
        let count = adjusted(pending.clickCount, key)
        phases[key] = .delivered(clickCount: count)
        judge(.accepted, key)
        return FlushedPress(event: pending.event, clickCount: count)
    }
}
