import AppKit
import CoreGraphics
import os
import WhiskerCore

/// The event tap: sees every mouse button and wheel event and applies the current settings to it.
///
/// The tap runs on its own thread so a busy main thread can never stall the mouse. Settings reach it as an
/// immutable `CompiledSettings` swapped under a lock. That same lock covers deciding what an event does and
/// posting the synthetic events for it, so a cleanup can never post a release ahead of the press it releases.
final class EventEngine: @unchecked Sendable {
    private struct State {
        var processor = EventProcessor()
        var compiled = CompiledSettings(.default)
        /// While the settings window is recording a button, every event passes through untouched.
        var capturing = false
        /// Set by `stop()` so presses that arrive while the tap is being torn down pass through untouched.
        var stopped = false
        /// Whether the app in front was on the bypass list at the last check, so standing aside happens once.
        var bypassed = false
    }

    static let eventMask: CGEventMask = {
        let types: [CGEventType] = [
            .leftMouseDown, .leftMouseUp, .leftMouseDragged,
            .rightMouseDown, .rightMouseUp, .rightMouseDragged,
            .otherMouseDown, .otherMouseUp, .otherMouseDragged,
            .scrollWheel,
        ]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let synthesizer: any ActionPerforming
    private let attribute: @Sendable (DeviceAttributor.ReportKind, TimeInterval) -> DeviceAttribution?
    private let frontmostApp: @Sendable () -> String?

    private let tapLock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(
        synthesizer: any ActionPerforming,
        attribute: @escaping @Sendable (DeviceAttributor.ReportKind, TimeInterval) -> DeviceAttribution?,
        frontmostApp: @escaping @Sendable () -> String?
    ) {
        self.synthesizer = synthesizer
        self.attribute = attribute
        self.frontmostApp = frontmostApp
    }

    var isRunning: Bool {
        tapLock.lock()
        defer { tapLock.unlock() }
        return tap != nil
    }

    func update(_ settings: WhiskerSettings) {
        let compiled = CompiledSettings(settings)
        let app = frontmostApp()
        let location = Self.cursorLocation()
        state.withLock { state in
            state.compiled = compiled
            if !settings.general.enabled { release(&state, at: location) }
            syncBypass(&state, app: app, at: location)
        }
    }

    /// The app in front changed. Whisker lets go of what it holds when that app is on the bypass list; the
    /// event tap itself already passes events through for it, this only ends what was started before.
    func frontmostAppChanged() {
        let app = frontmostApp()
        let location = Self.cursorLocation()
        state.withLock { syncBypass(&$0, app: app, at: location) }
    }

    func setCapturing(_ capturing: Bool) {
        let location = Self.cursorLocation()
        state.withLock { state in
            state.capturing = capturing
            if capturing { release(&state, at: location) }
        }
    }

    /// Lets go of held buttons and repeating keys (sleep, switching users, quitting).
    func releaseAll() {
        let location = Self.cursorLocation()
        state.withLock { release(&$0, at: location) }
    }

    /// Starts the tap. Returns false when the system refuses one (no Accessibility access).
    @discardableResult
    func start() -> Bool {
        tapLock.lock()
        defer { tapLock.unlock() }
        guard tap == nil else { return true }
        let context = Unmanaged.passUnretained(self).toOpaque()
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<EventEngine>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            },
            userInfo: context
        ) else {
            Log.events.error("Event tap could not be created; Accessibility access is needed")
            return false
        }
        tap = port
        state.withLock { $0.stopped = false }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [weak self] in
            guard let self, let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
                ready.signal()
                return
            }
            let loop = CFRunLoopGetCurrent()
            CFRunLoopAddSource(loop, source, .commonModes)
            CGEvent.tapEnable(tap: port, enable: true)
            self.runLoop = loop
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "Whisker event tap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
        self.thread = thread
        Log.events.info("Event tap started")
        return true
    }

    func stop() {
        let location = Self.cursorLocation()
        state.withLock { state in
            state.stopped = true
            release(&state, at: location)
        }
        tapLock.lock()
        defer { tapLock.unlock() }
        guard let port = tap else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        CFMachPortInvalidate(port)
        if let runLoop { CFRunLoopStop(runLoop) }
        tap = nil
        runLoop = nil
        thread = nil
        Log.events.info("Event tap stopped")
    }

    /// Call with the state lock held.
    private func release(_ state: inout State, at location: CGPoint) {
        for (_, action) in state.processor.releaseAll() {
            synthesizer.perform(action, phase: .up, at: location, flags: [], clickState: 1)
        }
        synthesizer.releaseAll()
    }

    /// Call with the state lock held. Standing aside for an app lets go of everything held, once; the real
    /// releases that follow are swallowed because the app never saw the presses. Coming back needs nothing:
    /// the next press starts afresh. Sleep, switching users and quitting apps don't pass through here, so
    /// they leave the state alone.
    private func syncBypass(_ state: inout State, app: String?, at location: CGPoint) {
        let bypassed = state.compiled.isBypassed(app: app)
        defer { state.bypassed = bypassed }
        guard bypassed, !state.bypassed else { return }
        for (_, action) in state.processor.releaseAllForBypass() {
            synthesizer.perform(action, phase: .up, at: location, flags: [], clickState: 1)
        }
        synthesizer.releaseAll()
    }

    private static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Tap thread

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Releases may have been missed while the tap was off, so nothing held is trusted any more.
            let location = Self.cursorLocation()
            state.withLock { release(&$0, at: location) }
            tapLock.lock()
            let port = tap
            tapLock.unlock()
            if let port {
                CGEvent.tapEnable(tap: port, enable: true)
                Log.events.notice("Event tap re-enabled after the system paused it")
            }
            return Unmanaged.passUnretained(event)
        }
        if event.getIntegerValueField(.eventSourceUserData) == EventSynthesizer.marker {
            return Unmanaged.passUnretained(event)
        }
        guard let kind = Self.inputKind(type, event) else { return Unmanaged.passUnretained(event) }

        let now = ProcessInfo.processInfo.systemUptime
        let reportKind: DeviceAttributor.ReportKind
        switch kind {
        case .buttonDown(let button), .buttonUp(let button), .buttonDragged(let button): reportKind = .button(button)
        case .scroll: reportKind = .wheel
        }
        let input = InputEvent(
            kind,
            modifiers: ModifierSet(eventFlags: event.flags.rawValue),
            timestamp: now,
            device: attribute(reportKind, now),
            app: frontmostApp()
        )
        let location = event.location
        let flags = CGEventFlags(rawValue: event.flags.rawValue & ModifierSet([.shift, .control, .option, .command]).eventFlags)
        let clickState = event.getIntegerValueField(.mouseEventClickState)
        let plan = state.withLock { state -> EventPlan in
            guard !state.capturing, !state.stopped else { return .passThrough }
            let plan = state.processor.process(input, settings: state.compiled)
            if case let .perform(action, phase) = plan {
                synthesizer.perform(action, phase: phase, at: location, flags: flags, clickState: clickState)
            }
            return plan
        }
        return apply(plan, to: event)
    }

    private func apply(_ plan: EventPlan, to event: CGEvent) -> Unmanaged<CGEvent>? {
        switch plan {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .perform:
            // Already posted under the state lock in `handle`.
            return nil
        case let .dragAs(button, modifiers):
            switch button {
            case 0: event.type = .leftMouseDragged
            case 1: event.type = .rightMouseDragged
            default: event.type = .otherMouseDragged
            }
            event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
            event.flags = CGEventFlags(rawValue: event.flags.rawValue | modifiers.eventFlags)
            return Unmanaged.passUnretained(event)
        case .dragAsMove:
            event.type = .mouseMoved
            return Unmanaged.passUnretained(event)
        case let .scroll(sample, removing):
            Self.write(sample, to: event)
            if !removing.isEmpty {
                event.flags = CGEventFlags(rawValue: event.flags.rawValue & ~removing.eventFlags)
            }
            return Unmanaged.passUnretained(event)
        }
    }

    static func inputKind(_ type: CGEventType, _ event: CGEvent) -> InputKind? {
        let button = Int(event.getIntegerValueField(.mouseEventButtonNumber))
        switch type {
        case .leftMouseDown: return .buttonDown(0)
        case .leftMouseUp: return .buttonUp(0)
        case .leftMouseDragged: return .buttonDragged(0)
        case .rightMouseDown: return .buttonDown(1)
        case .rightMouseUp: return .buttonUp(1)
        case .rightMouseDragged: return .buttonDragged(1)
        case .otherMouseDown: return .buttonDown(button)
        case .otherMouseUp: return .buttonUp(button)
        case .otherMouseDragged: return .buttonDragged(button)
        case .scrollWheel: return .scroll(readSample(event))
        default: return nil
        }
    }

    static func readSample(_ event: CGEvent) -> ScrollSample {
        let momentum = event.getIntegerValueField(.scrollWheelEventMomentumPhase) != 0
        return ScrollSample(
            vertical: ScrollAxis(
                lines: Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis1)),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1),
                points: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis1))
            ),
            horizontal: ScrollAxis(
                lines: Int(event.getIntegerValueField(.scrollWheelEventDeltaAxis2)),
                fixed: event.getDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2),
                points: Double(event.getIntegerValueField(.scrollWheelEventPointDeltaAxis2))
            ),
            isContinuous: momentum || event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0
        )
    }

    static func write(_ sample: ScrollSample, to event: CGEvent) {
        event.setIntegerValueField(.scrollWheelEventDeltaAxis1, value: Int64(sample.vertical.lines))
        event.setIntegerValueField(.scrollWheelEventDeltaAxis2, value: Int64(sample.horizontal.lines))
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis1, value: sample.vertical.fixed)
        event.setDoubleValueField(.scrollWheelEventFixedPtDeltaAxis2, value: sample.horizontal.fixed)
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis1, value: Int64(sample.vertical.points.rounded()))
        event.setIntegerValueField(.scrollWheelEventPointDeltaAxis2, value: Int64(sample.horizontal.points.rounded()))
    }
}
