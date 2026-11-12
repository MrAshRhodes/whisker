import CoreGraphics
import Foundation

/// What the movement tap asks of the event engine. Closures, so the tap never reaches into the engine's state.
struct ClickLockMovementHooks: Sendable {
    /// Whether a Click Lock is holding the primary button down right now.
    var isLockActive: @Sendable () -> Bool
    /// The system switched the tap off, so movement can no longer be trusted to follow the lock.
    var interrupted: @Sendable () -> Void
}

/// Makes pointer movement a drag of the primary button while a Click Lock holds it down.
///
/// With nothing physically pressed the system reports movement as plain pointer motion, and apps would not see the
/// held button being dragged. The engine's own tap is not asked about plain motion at all (that would put every
/// move of every mouse through it), so this is a second tap that is on only while a lock is held.
protocol ClickLockMovement: AnyObject, Sendable {
    /// Whether the tap exists and can be switched on. A lock never begins unless it can.
    var isReady: Bool { get }
    /// Switches the tap on while a lock is held and off otherwise. Safe to repeat.
    func setEnabled(_ enabled: Bool)
    /// Tears the tap down for good.
    func invalidate()
}

/// Makes the movement tap, or returns nil when there is no event tap run loop yet or the system refuses one.
typealias ClickLockMovementFactory = @Sendable (CFRunLoop?, ClickLockMovementHooks) -> (any ClickLockMovement)?

/// The real movement tap: a session tap for pointer movement only, added to the event tap's own run loop so the
/// engine's callbacks and this one never run at the same time. It is created switched off.
///
/// The callback only retypes movement and always passes the event on. Whether the system lets a tap retype
/// movement as a drag, and whether apps then treat it as one, has not been verified on hardware.
final class ClickLockMovementTap: ClickLockMovement, @unchecked Sendable {
    private let hooks: ClickLockMovementHooks
    private let runLoop: CFRunLoop
    private let lock = NSLock()
    private var port: CFMachPort?
    private var source: CFRunLoopSource?
    private var enabled = false

    init?(runLoop: CFRunLoop?, hooks: ClickLockMovementHooks) {
        guard let runLoop else { return nil }
        self.runLoop = runLoop
        self.hooks = hooks
        let mask = CGEventMask(1) << CGEventMask(CGEventType.mouseMoved.rawValue)
        guard let port = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .tailAppendEventTap, options: .defaultTap,
            eventsOfInterest: mask,
            callback: { _, type, event, context in
                guard let context else { return Unmanaged.passUnretained(event) }
                return Unmanaged<ClickLockMovementTap>.fromOpaque(context).takeUnretainedValue().handle(type, event)
            },
            userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.events.error("Click Lock movement tap could not be created")
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

    func setEnabled(_ enabled: Bool) {
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
        // A callback may be running on the tap thread right now, and it holds this object unretained. The block keeps
        // it alive until that thread comes round to it, which is after the callback has finished.
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.commonModes.rawValue) { _ = self }
        CFRunLoopWakeUp(runLoop)
    }

    private func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .tapDisabledByTimeout, .tapDisabledByUserInput:
            lock.lock()
            enabled = false
            lock.unlock()
            hooks.interrupted()
        case .mouseMoved:
            if event.getIntegerValueField(.eventSourceUserData) != EventSynthesizer.marker, hooks.isLockActive() {
                Self.becomeDrag(event)
            }
        default:
            break
        }
        return Unmanaged.passUnretained(event)
    }

    /// Retypes movement as a drag of the primary button, which is what a held primary button would have produced.
    static func becomeDrag(_ event: CGEvent) {
        event.type = .leftMouseDragged
        event.setIntegerValueField(.mouseEventButtonNumber, value: 0)
        event.setIntegerValueField(.mouseEventClickState, value: 1)
    }
}
