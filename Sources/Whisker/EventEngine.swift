import AppKit
import CoreGraphics
import os
import WhiskerCore

/// The event tap: sees every mouse button and wheel event and applies the current settings to it.
///
/// The tap runs on its own thread so a busy main thread can never stall the mouse. Settings reach it as an
/// immutable `CompiledSettings` swapped under a lock.
final class EventEngine: @unchecked Sendable {
    private struct State {
        var processor = EventProcessor()
        var compiled = CompiledSettings(.default)
        /// While the settings window is recording a button, every event passes through untouched.
        var capturing = false
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
    private let synthesizer: EventSynthesizer
    private let attribute: @Sendable (DeviceAttributor.ReportKind, TimeInterval) -> DeviceAttribution?
    private let frontmostApp: @Sendable () -> String?

    private let tapLock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(
        synthesizer: EventSynthesizer,
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
        let released = state.withLock { state -> [(button: Int, action: Action)] in
            state.compiled = compiled
            return settings.general.enabled ? [] : state.processor.releaseAll()
        }
        finish(released)
    }

    func setCapturing(_ capturing: Bool) {
        let released = state.withLock { state -> [(button: Int, action: Action)] in
            state.capturing = capturing
            return capturing ? state.processor.releaseAll() : []
        }
        finish(released)
    }

    /// Lets go of held buttons and repeating keys (sleep, switching users, quitting).
    func releaseAll() {
        finish(state.withLock { $0.processor.releaseAll() })
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
        releaseAll()
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

    private func finish(_ released: [(button: Int, action: Action)]) {
        let location = CGEvent(source: nil)?.location ?? .zero
        for (_, action) in released {
            synthesizer.perform(action, phase: .up, at: location, flags: [])
        }
        synthesizer.releaseAll()
    }

    // MARK: Tap thread

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
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
        let plan = state.withLock { state -> EventPlan in
            state.capturing ? .passThrough : state.processor.process(input, settings: state.compiled)
        }
        return apply(plan, to: event)
    }

    private func apply(_ plan: EventPlan, to event: CGEvent) -> Unmanaged<CGEvent>? {
        switch plan {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case let .perform(action, phase):
            let flags = CGEventFlags(rawValue: event.flags.rawValue & ModifierSet([.shift, .control, .option, .command]).eventFlags)
            synthesizer.perform(action, phase: phase, at: event.location, flags: flags)
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
