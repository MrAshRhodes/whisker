import CoreGraphics
import Foundation
import os
import WhiskerCore

/// What the orientation tap asks of the rest of the app. Closures, so the tap never reaches into the engine's state.
struct PointerOrientationHooks: Sendable {
    /// The one device that reported movement at this moment, or nil when none or more than one did.
    var attributeMotion: @Sendable (TimeInterval) -> DeviceAttribution?
    /// The system switched the tap off, so a preview can no longer be trusted to be what the user sees.
    var interrupted: @Sendable () -> Void
}

/// Turns pointer movement for trackballs used sideways or upside down (see `PointerOrientationRouter`).
protocol PointerOrientationRewriting: AnyObject, Sendable {
    var isReady: Bool { get }
    /// The angle per device; the tap is on only while one is non-zero or a calibration is recording.
    func setAngles(_ angles: [String: Double])
    func setDisplays(_ displays: [PointerRect])
    /// Records one device's unrotated movement for a guided calibration, or stops recording (nil).
    func setCalibrating(_ deviceID: String?)
    /// The forward strokes recorded so far, each ended by a pause.
    func calibrationStrokes(at time: TimeInterval) -> [PointerVector]
    func invalidate()
}

typealias PointerOrientationFactory = @Sendable (CFRunLoop?, PointerOrientationHooks) -> (any PointerOrientationRewriting)?

/// The real orientation tap: a session tap for movement and drags only, added to the event tap's own run loop and
/// placed after the engine's tap, so the engine (hold to scroll, chords, Click Lock) sees movement as the mouse
/// reported it. It is off unless some device has a non-zero angle, so ordinary movement costs nothing.
///
/// The callback rewrites the deltas and location of attributed movement only and always passes the event on.
/// Whether every app follows a rewritten location (rather than reading raw input) has not been verified on hardware.
final class PointerOrientationTap: PointerOrientationRewriting, @unchecked Sendable {
    private struct Core {
        var router = PointerOrientationRouter()
        var calibrating: String?
        var recorder = PointerCalibrationRecorder()
        var wanted: Bool { router.isActive || calibrating != nil }
    }

    static let eventMask: CGEventMask = {
        let types: [CGEventType] = [.mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged]
        return types.reduce(CGEventMask(0)) { $0 | (CGEventMask(1) << CGEventMask($1.rawValue)) }
    }()

    private let hooks: PointerOrientationHooks
    private let runLoop: CFRunLoop
    private let core = OSAllocatedUnfairLock(initialState: Core())
    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var enabled = false

    init?(runLoop: CFRunLoop?, hooks: PointerOrientationHooks) {
        guard let runLoop else { return nil }
        self.runLoop = runLoop
        self.hooks = hooks
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: Self.eventMask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<PointerOrientationTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.events.error("Pointer orientation tap could not be created")
            return nil
        }
        CGEvent.tapEnable(tap: port, enable: false)
        guard let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, port, 0) else {
            CFMachPortInvalidate(port)
            return nil
        }
        self.port = port
        self.source = source
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CFRunLoopWakeUp(runLoop)
    }

    deinit {
        if let port {
            CGEvent.tapEnable(tap: port, enable: false)
            CFMachPortInvalidate(port)
        }
    }

    var isReady: Bool {
        lock.lock()
        defer { lock.unlock() }
        guard let port else { return false }
        return CFMachPortIsValid(port)
    }

    func setAngles(_ angles: [String: Double]) {
        let wanted = core.withLock { core -> Bool in
            core.router.setAngles(angles)
            return core.wanted
        }
        setEnabled(wanted)
    }

    func setDisplays(_ displays: [PointerRect]) {
        let wanted = core.withLock { core -> Bool in
            core.router.setDisplays(displays)
            return core.wanted
        }
        setEnabled(wanted)
    }

    func setCalibrating(_ deviceID: String?) {
        let wanted = core.withLock { core -> Bool in
            core.calibrating = deviceID
            core.recorder = PointerCalibrationRecorder()
            return core.wanted
        }
        setEnabled(wanted)
    }

    func calibrationStrokes(at time: TimeInterval) -> [PointerVector] {
        core.withLock { core in
            core.recorder.settle(at: time)
            return core.recorder.strokes
        }
    }

    private func setEnabled(_ enabled: Bool) {
        lock.lock()
        defer { lock.unlock() }
        guard let port, self.enabled != enabled else { return }
        self.enabled = enabled
        CGEvent.tapEnable(tap: port, enable: enabled)
    }

    func invalidate() {
        lock.lock()
        defer { lock.unlock() }
        guard let port else { return }
        CGEvent.tapEnable(tap: port, enable: false)
        enabled = false
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CFMachPortInvalidate(port)
        self.port = nil
        source = nil
        // A callback may be running on the tap thread, holding this object unretained; see `ClickLockMovementTap`.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { _ = self }
        CFRunLoopWakeUp(runLoop)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            // Movement went by unseen, so nothing carried over is trusted; a preview rolls back.
            let wanted = core.withLock { core -> Bool in
                core.router.breakContinuity()
                return core.wanted
            }
            lock.lock()
            if let port, wanted, enabled { CGEvent.tapEnable(tap: port, enable: true) }
            lock.unlock()
            hooks.interrupted()
        case .mouseMoved, .leftMouseDragged, .rightMouseDragged, .otherMouseDragged:
            Self.rotate(event, core: core, attribute: hooks.attributeMotion)
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Rewrites one movement event in place when the router says so. Kept static so it never touches anything
    /// but the lock-protected core.
    private static func rotate(
        _ event: CGEvent, core: OSAllocatedUnfairLock<Core>, attribute: @Sendable (TimeInterval) -> DeviceAttribution?
    ) {
        let marker = event.getIntegerValueField(.eventSourceUserData)
        guard marker != EventSynthesizer.marker, marker != ChordRouter.marker else {
            // Whisker's own events may have moved the pointer, so the next movement starts from where it is.
            core.withLock { $0.router.breakContinuity() }
            return
        }
        let now = ProcessInfo.processInfo.systemUptime
        let device = attribute(now)
        let delta = PointerMotion(
            dx: Int(event.getIntegerValueField(.mouseEventDeltaX)), dy: Int(event.getIntegerValueField(.mouseEventDeltaY))
        )
        let precise = PointerVector(dx: event.getDoubleValueField(.mouseEventDeltaX), dy: event.getDoubleValueField(.mouseEventDeltaY))
        let location = event.location
        let decision = core.withLock { core -> PointerOrientationRouter.Decision in
            if let calibrating = core.calibrating, let device, device.exact, !device.isExcluded, device.id == calibrating {
                core.recorder.record(precise, at: now)
            }
            return core.router.process(
                device: device, delta: delta, precise: precise, location: PointerPoint(x: location.x, y: location.y), at: now
            )
        }
        guard case let .rewrite(rotated, target) = decision else { return }
        event.setIntegerValueField(.mouseEventDeltaX, value: Int64(rotated.dx))
        event.setIntegerValueField(.mouseEventDeltaY, value: Int64(rotated.dy))
        event.location = CGPoint(x: target.x, y: target.y)
    }
}

extension PointerOrientationTap {
    /// The bounds of every active display, in the coordinates events use. Read on the main thread, never in the tap.
    static func activeDisplays() -> [PointerRect] {
        var count: UInt32 = 0
        guard CGGetActiveDisplayList(0, nil, &count) == .success, count > 0 else { return [] }
        var ids = [CGDirectDisplayID](repeating: 0, count: Int(count))
        guard CGGetActiveDisplayList(count, &ids, &count) == .success else { return [] }
        return ids.prefix(Int(count)).map { id in
            let bounds = CGDisplayBounds(id)
            return PointerRect(x: bounds.minX, y: bounds.minY, width: bounds.width, height: bounds.height)
        }
    }
}
