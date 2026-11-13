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
        /// The device that triggered the last action, which a click gesture still under way depends on.
        var actionSource: String?
        /// Whether the app in front was on the bypass list at the last check, so standing aside happens once.
        var bypassed = false
        /// Duplicate-click filter for the devices that opted in; empty state when none did.
        var debouncer = ClickDebouncer()
        /// Calls off the timer set for the oldest press the filter is holding back.
        var cancelExpiry: (@Sendable () -> Void)?
        /// The local duplicate-click test last reported to `onClickFilterTest`.
        var reportedClickFilterTest: ClickFilterTally?
        /// The hold-to-scroll status last reported to `onHoldStatus`.
        var reportedHold: HoldScrollStatus = .idle
        /// System Reduce Motion, snapshotted by the app outside the tap. While on, nothing is smoothed.
        var reduceMotion = false
        /// Turns movement into a drag while a Click Lock is held. Nil until a Click Lock mapping needs it, and a
        /// lock never begins without it.
        var movement: (any ClickLockMovement)?
        /// The Click Lock state last reported to `onClickLockChange`.
        var reportedClickLock = false
        /// The generation of the auto-scroll the synthesizer is running, so it is only spoken to when that changes.
        var runningAutoScroll: Int?
        /// Whether `onAutoScrollActive` was last told that one is running.
        var reportedAutoScroll = false
        var slowPointerDevices: Set<String> = []
        var reportedSlowPointer: UInt64 = 0
        /// Turns movement of devices with an orientation angle. Nil until an angle, a preview or a calibration
        /// needs it.
        var orientation: (any PointerOrientationRewriting)?
        /// An unconfirmed angle being tried live. Never saved; see `PointerOrientationPreview`.
        var orientationPreview: PointerOrientationPreview?
        /// The device whose unrotated movement a guided calibration is recording.
        var orientationCalibration: String?
        /// The active displays, which a rotated pointer is kept on.
        var displays: [PointerRect] = []
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
    private let clock: any ClickClock
    private let attributeMotion: @Sendable (TimeInterval) -> DeviceAttribution?
    private let makeMovement: ClickLockMovementFactory
    private let makeOrientation: PointerOrientationFactory
    private let chords: ChordRouter
    /// Called on the main queue when a hold-to-scroll starts, falls back or can't start.
    var onHoldStatus: (@Sendable (HoldScrollStatus) -> Void)?
    /// Called on the main queue when a Click Lock begins or ends.
    var onClickLockChange: (@Sendable (Bool) -> Void)?
    /// Called on the main queue with whether an auto-scroll is running, whenever that changes.
    var onAutoScrollActive: (@Sendable (Bool) -> Void)?
    var onSlowPointer: (@MainActor @Sendable (SlowPointerCommand) -> Void)?
    /// Called on the main queue with a copy of the local duplicate-click test whenever it changes, nil once it ends.
    var onClickFilterTest: (@MainActor @Sendable (ClickFilterTally?) -> Void)?
    /// Called on the main queue when the system paused the orientation tap, so a preview has to roll back.
    var onOrientationInterrupted: (@MainActor @Sendable () -> Void)?

    private let tapLock = NSLock()
    private var tap: CFMachPort?
    private var runLoop: CFRunLoop?
    private var thread: Thread?

    init(
        synthesizer: any ActionPerforming,
        attribute: @escaping @Sendable (DeviceAttributor.ReportKind, TimeInterval) -> DeviceAttribution?,
        frontmostApp: @escaping @Sendable () -> String?,
        clock: any ClickClock = SystemClickClock(),
        attributeMotion: @escaping @Sendable (TimeInterval) -> DeviceAttribution? = { _ in nil },
        movement makeMovement: @escaping ClickLockMovementFactory = { runLoop, hooks in ClickLockMovementTap(runLoop: runLoop, hooks: hooks) },
        attributeChord: @escaping @Sendable (Int, Bool, TimeInterval) -> ChordSource? = { _, _, _ in nil },
        postChordEvent: @escaping @Sendable (CGEvent) -> Void = { $0.post(tap: .cghidEventTap) },
        orientation makeOrientation: @escaping PointerOrientationFactory = { runLoop, hooks in PointerOrientationTap(runLoop: runLoop, hooks: hooks) }
    ) {
        self.clock = clock
        self.synthesizer = synthesizer
        self.attribute = attribute
        self.frontmostApp = frontmostApp
        self.attributeMotion = attributeMotion
        self.makeMovement = makeMovement
        self.makeOrientation = makeOrientation
        chords = ChordRouter(clock: clock, attribute: attributeChord, post: postChordEvent)
        chords.host = self
    }

    var isRunning: Bool {
        tapLock.lock()
        defer { tapLock.unlock() }
        return tap != nil
    }

    func update(_ settings: WhiskerSettings) {
        let app = frontmostApp()
        let location = Self.cursorLocation()
        chords.update(engaged: settings.general.enabled && settings.profiles.contains { $0.chords?.isEmpty == false }, at: location)
        state.withLock { state in
            // A Click Lock began under the settings that are going away, so whatever changed, it ends.
            endClickLock(&state, settings.general.enabled ? .settingsChanged : .disabled, at: location)
            let previous = state.compiled
            state.compiled = CompiledSettings(settings, nativeWheelActive: state.compiled.nativeWheelActive)
            state.processor.resetScrollRecognition()
            // An auto-scroll started under settings that are going away, and a changed mapping or profile must
            // never carry one on.
            state.processor.cancelAutoScroll()
            state.processor.cancelSlowPointer()
            // Pending smoothing was planned under settings that are going away.
            synthesizer.cancelSmoothScroll()
            // Settings that decide what to filter may have changed under a press that is being held back.
            state.debouncer.settingsChanged(from: previous, to: state.compiled)
            armExpiry(&state)
            if settings.general.enabled {
                // A click gesture under way began under the settings that are going away.
                synthesizer.cancelPendingClicks()
                synthesizer.cancelSequence(.lifecycle)
            } else {
                release(&state, at: location, because: .disabled)
            }
            // A hold whose mapping was removed ends now; one that is merely edited keeps the settings it started with.
            if !state.compiled.needsMotion { state.processor.cancelHold() }
            // A gesture began under the settings that are going away, so it is called off rather than finished under new ones.
            state.processor.cancelGesture()
            syncBypass(&state, app: app, at: location)
            syncOrientation(&state)
            syncAutoScroll(&state)
            reportHold(&state)
        }
        prepareClickLockMovement()
        prepareOrientation()
    }

    /// Reduce Motion changed. Turning it on ends smoothing that is under way, and nothing is smoothed while it is on.
    func setReduceMotion(_ reduce: Bool) {
        state.withLock { state in
            guard state.reduceMotion != reduce else { return }
            state.reduceMotion = reduce
            if reduce { synthesizer.cancelSmoothScroll() }
        }
    }

    func setSlowPointerDevices(_ devices: Set<String>) {
        state.withLock { state in
            guard state.slowPointerDevices != devices else { return }
            state.slowPointerDevices = devices
            state.processor.cancelSlowPointer(unlessAvailable: devices)
            reportSlowPointer(&state)
        }
    }

    /// Also returned for immediate main-actor cancellation, without waiting for its queued notification.
    @discardableResult
    func cancelSlowPointer() -> SlowPointerCommand {
        state.withLock { state in
            state.processor.cancelSlowPointer()
            reportSlowPointer(&state)
            return state.processor.slowPointerCommand
        }
    }

    /// Mice whose own wheel service Whisker has changed: their software distance and acceleration stand aside.
    func setNativeWheelActive(_ devices: Set<String>) {
        state.withLock { state in
            guard state.compiled.nativeWheelActive != devices else { return }
            state.compiled = CompiledSettings(state.compiled.settings, nativeWheelActive: devices)
        }
    }

    /// The app in front changed. A click gesture under way was aimed at the app that has gone, so it is called
    /// off, and so is a button gesture or a hold to scroll. Whisker also lets go of what it holds when the new app
    /// is on the bypass list; the event tap itself already passes events through for it, this only ends what was
    /// started before.
    func frontmostAppChanged() {
        let app = frontmostApp()
        let location = Self.cursorLocation()
        chords.cancel(at: location)
        state.withLock { state in
            synthesizer.cancelPendingClicks()
            // What is still being spread out was aimed at the app that has gone.
            synthesizer.cancelSmoothScroll()
            synthesizer.cancelSequence(.applicationChanged)
            // The pointer is anchored in the window that was in front, so a hold never carries over to another app.
            state.processor.cancelHold()
            // A Click Lock began in the app that has gone.
            endClickLock(&state, .applicationChanged, at: location)
            // A gesture was aimed at the app that has gone, so it is called off rather than carried over.
            state.processor.cancelGesture()
            // An auto-scroll is addressed to the window under its anchor, so it ends rather than scroll the new app.
            state.processor.cancelAutoScroll()
            state.processor.cancelSlowPointer()
            syncBypass(&state, app: app, at: location)
            syncOrientation(&state)
            syncAutoScroll(&state)
            reportHold(&state)
        }
    }

    /// An app came to the front, even the one that already was (leaving an app and coming back counts).
    /// A shortcut sequence was aimed at the app as it was, so it is called off.
    func applicationActivated() {
        state.withLock { _ in synthesizer.cancelSequence(.applicationChanged) }
    }

    func setCapturing(_ capturing: Bool) {
        let location = Self.cursorLocation()
        if capturing { chords.cancel(at: location) }
        state.withLock { state in
            state.capturing = capturing
            if capturing { release(&state, at: location, because: .capture) }
            synthesizer.cancelSmoothScroll()
        }
    }

    /// Lets go of held buttons, a Click Lock and repeating keys (sleep, switching users, quitting).
    func releaseAll(because reason: ClickLockEnd = .quit) {
        let location = Self.cursorLocation()
        chords.reset(at: location)
        state.withLock { release(&$0, at: location, because: reason) }
    }

    /// Lets go of a Click Lock and nothing else: the menu command, and the way out when the Accessibility permission goes.
    func releaseClickLock(_ reason: ClickLockEnd = .menu) {
        let location = Self.cursorLocation()
        state.withLock { endClickLock(&$0, reason, at: location) }
    }

    /// The set of connected mice changed. A click gesture under way is called off if the mouse that started it is gone.
    func devicesChanged(connected: Set<String>) {
        let location = Self.cursorLocation()
        chords.devicesChanged(connected: connected, at: location)
        state.withLock { state in
            if ClickInterruption.isCalledOffByDeviceChange(startedBy: state.actionSource, connected: connected) {
                synthesizer.cancelPendingClicks()
            }
            synthesizer.cancelSmoothScroll(unlessConnected: connected)
            state.debouncer.devicesChanged(connected: connected)
            armExpiry(&state)
            // A Click Lock begun by a mouse that has gone lets go now; nobody is left to press the button again.
            let lockEnded = state.processor.cancelClickLock(unlessConnected: connected)
            finishClickLock(&state, ended: lockEnded, at: location)
            // A hold started by a device that has gone ends now, and so does a gesture.
            state.processor.cancelHold(unlessConnected: connected)
            state.processor.cancelGesture(unlessConnected: connected)
            state.processor.slowPointerDevicesChanged(connected: connected)
            // A swapped button of a mouse that has gone can't be released by the mouse itself.
            for (_, action) in state.processor.releaseSwaps(unlessConnected: connected) {
                synthesizer.perform(action, phase: .up, at: location, flags: [], clickState: 1)
            }
            // An auto-scroll follows the pointer, whichever mouse moves it, and which one started it is not
            // recorded. Any change to the set of mice ends it rather than guess what the new set means for it.
            state.processor.cancelAutoScroll()
            syncAutoScroll(&state)
            reportHold(&state)
        }
    }

    /// Ends an auto-scroll without touching anything else, for changes that leave its anchor meaning something
    /// else (displays rearranged, another Space) and so can't be told from the inside.
    func cancelAutoScroll() {
        state.withLock { state in
            state.processor.cancelAutoScroll()
            syncAutoScroll(&state)
        }
    }

    // MARK: Orientation

    /// Tries an unconfirmed angle live, or ends the preview (nil). Settings never see it.
    func setOrientationPreview(_ preview: PointerOrientationPreview?) {
        state.withLock { state in
            state.orientationPreview = preview
            syncOrientation(&state)
        }
        prepareOrientation()
    }

    /// Starts recording one device's unrotated movement for a guided calibration, or stops (nil).
    func setOrientationCalibration(_ deviceID: String?) {
        state.withLock { state in
            state.orientationCalibration = deviceID
            state.orientation?.setCalibrating(deviceID)
        }
        prepareOrientation()
    }

    /// The forward strokes recorded so far; empty when no calibration is recording.
    func orientationCalibrationStrokes() -> [PointerVector] {
        let now = ProcessInfo.processInfo.systemUptime
        let orientation = state.withLock { $0.orientationCalibration == nil ? nil : $0.orientation }
        return orientation?.calibrationStrokes(at: now) ?? []
    }

    /// The active displays changed; a rotated pointer is kept on them.
    func setDisplays(_ displays: [PointerRect]) {
        state.withLock { state in
            guard state.displays != displays else { return }
            state.displays = displays
            state.orientation?.setDisplays(displays)
        }
    }

    /// The angles in use now, for tests and the log: empty while Whisker is off or standing aside.
    var orientationAngles: [String: Double] {
        state.withLock { Self.orientationAngles($0) }
    }

    private static func orientationAngles(_ state: State) -> [String: Double] {
        guard !state.stopped, !state.bypassed else { return [:] }
        let settings = state.compiled.settings
        return PointerOrientationMath.effectiveAngles(
            devices: settings.devices, enabled: settings.general.enabled, preview: state.orientationPreview
        )
    }

    /// Call with the state lock held. Gives the orientation tap the angles that apply now; it switches itself off
    /// when there are none.
    private func syncOrientation(_ state: inout State) {
        state.orientation?.setAngles(Self.orientationAngles(state))
    }

    /// Makes the orientation tap when an angle, a preview or a calibration needs it and drops it otherwise. Takes
    /// the tap lock, so it is never called with the state lock held.
    private func prepareOrientation() {
        let (needed, present) = state.withLock { state in
            // Kept while Whisker is off or standing aside (the tap is merely switched off), so coming back needs no new tap.
            let angled = !PointerOrientationMath.effectiveAngles(
                devices: state.compiled.settings.devices, enabled: true, preview: state.orientationPreview
            ).isEmpty
            return (!state.stopped && (angled || state.orientationCalibration != nil), state.orientation != nil)
        }
        if needed, !present {
            tapLock.lock()
            let loop = runLoop
            tapLock.unlock()
            let hooks = PointerOrientationHooks(
                attributeMotion: attributeMotion,
                interrupted: { [weak self] in
                    guard let callback = self?.onOrientationInterrupted else { return }
                    DispatchQueue.main.async { MainActor.assumeIsolated { callback() } }
                }
            )
            guard let created = makeOrientation(loop, hooks) else { return }
            let kept = state.withLock { state -> Bool in
                guard state.orientation == nil, !state.stopped else { return false }
                state.orientation = created
                created.setDisplays(state.displays)
                created.setCalibrating(state.orientationCalibration)
                syncOrientation(&state)
                return true
            }
            if !kept { created.invalidate() }
        } else if !needed, present {
            let dropped = state.withLock { state -> (any PointerOrientationRewriting)? in
                defer { state.orientation = nil }
                return state.orientation
            }
            dropped?.invalidate()
        }
    }

    /// Starts the tap. Returns false when the system refuses one (no Accessibility access).
    @discardableResult
    func start() -> Bool {
        guard startTap() else { return false }
        prepareClickLockMovement()
        prepareOrientation()
        return true
    }

    private func startTap() -> Bool {
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
        chords.reset(at: location)
        let (movement, orientation) = state.withLock { state -> ((any ClickLockMovement)?, (any PointerOrientationRewriting)?) in
            state.stopped = true
            release(&state, at: location, because: .quit)
            defer {
                state.movement = nil
                state.orientation = nil
            }
            return (state.movement, state.orientation)
        }
        movement?.invalidate()
        orientation?.invalidate()
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
    private func release(_ state: inout State, at location: CGPoint, because reason: ClickLockEnd = .quit) {
        for (_, action) in state.processor.releaseAll(because: reason) {
            synthesizer.perform(action, phase: .up, at: location, flags: [], clickState: 1)
        }
        synthesizer.releaseAll()
        synthesizer.cancelSmoothScroll()
        syncAutoScroll(&state)
        state.debouncer.reset()
        armExpiry(&state)
        reportHold(&state)
        syncClickLock(&state)
    }

    /// Call with the state lock held. Ends the Click Lock if there is one, posting its one release.
    private func endClickLock(_ state: inout State, _ reason: ClickLockEnd, at location: CGPoint, flags: CGEventFlags = []) {
        let ended = state.processor.cancelClickLock(reason)
        finishClickLock(&state, ended: ended, at: location, flags: flags)
    }

    /// Call with the state lock held, once the processor has ended the lock (`ended`). The release is posted only
    /// then, so no path can ask for a second one.
    private func finishClickLock(_ state: inout State, ended: Bool, at location: CGPoint, flags: CGEventFlags = []) {
        if ended { synthesizer.perform(.clickLock, phase: .up, at: location, flags: flags, clickState: 1) }
        syncClickLock(&state)
    }

    /// Call with the state lock held. Keeps the movement tap on exactly while a lock is held and tells the app when
    /// that changes, off the tap thread.
    private func syncClickLock(_ state: inout State) {
        let active = state.processor.isClickLockActive
        state.movement?.setEnabled(active)
        guard active != state.reportedClickLock else { return }
        state.reportedClickLock = active
        if active {
            Log.events.notice("Click Lock began")
        } else {
            let reason = state.processor.lastClickLockEnd?.rawValue ?? "unknown"
            Log.events.notice("Click Lock ended: \(reason, privacy: .public)")
        }
        guard let onClickLockChange else { return }
        DispatchQueue.main.async { onClickLockChange(active) }
    }

    /// Makes the movement tap when Click Lock is on and mapped, and drops it when it no longer is. It takes the tap
    /// lock, so it is never called with the state lock held (starting the tap nests them the other way round).
    private func prepareClickLockMovement() {
        let (needed, present) = state.withLock { ($0.compiled.needsClickLock && !$0.stopped, $0.movement != nil) }
        if needed, !present {
            tapLock.lock()
            let loop = runLoop
            tapLock.unlock()
            let hooks = ClickLockMovementHooks(
                isLockActive: { [weak self] in self?.state.withLock { $0.processor.isClickLockActive } ?? false },
                interrupted: { [weak self] in self?.clickLockMovementInterrupted() }
            )
            guard let created = makeMovement(loop, hooks) else { return }
            let kept = state.withLock { state -> Bool in
                guard state.movement == nil, state.compiled.needsClickLock, !state.stopped else { return false }
                state.movement = created
                return true
            }
            if !kept { created.invalidate() }
        } else if !needed, present {
            let dropped = state.withLock { state -> (any ClickLockMovement)? in
                defer { state.movement = nil }
                return state.movement
            }
            dropped?.invalidate()
        }
    }

    /// The system paused the movement tap, so a held lock would stop following the pointer: it lets go.
    private func clickLockMovementInterrupted() {
        let location = Self.cursorLocation()
        state.withLock { endClickLock(&$0, .tapInterrupted, at: location) }
    }

    /// Call with the state lock held. Makes the synthesizer run exactly the auto-scroll the processor has: it is
    /// started or stopped the moment the processor's session changes, before the event that changed it goes on.
    /// Also tells the app, off the tap thread.
    private func syncAutoScroll(_ state: inout State) {
        let session = state.processor.autoScrollSession
        if session?.generation != state.runningAutoScroll {
            if let session { synthesizer.startAutoScroll(session) } else { synthesizer.cancelAutoScroll() }
            state.runningAutoScroll = session?.generation
        }
        let active = session != nil
        guard active != state.reportedAutoScroll else { return }
        state.reportedAutoScroll = active
        guard let onAutoScrollActive else { return }
        DispatchQueue.main.async { onAutoScrollActive(active) }
    }

    /// Call with the state lock held. Tells the app about a change of hold-to-scroll status, off the tap thread.
    private func reportHold(_ state: inout State) {
        reportSlowPointer(&state)
        let status = state.processor.holdStatus
        guard status != state.reportedHold else { return }
        state.reportedHold = status
        if case .fellBack = status { Log.events.notice("Hold to Scroll fell back to normal movement") }
        guard let onHoldStatus else { return }
        DispatchQueue.main.async { onHoldStatus(status) }
    }

    private func reportSlowPointer(_ state: inout State) {
        let command = state.processor.slowPointerCommand
        guard command.generation != state.reportedSlowPointer else { return }
        state.reportedSlowPointer = command.generation
        guard let onSlowPointer else { return }
        DispatchQueue.main.async { [weak self] in
            guard let self,
                  self.state.withLock({ $0.processor.slowPointerCommand.generation == command.generation }) else { return }
            MainActor.assumeIsolated { onSlowPointer(command) }
        }
    }

    /// Call with the state lock held. Standing aside for an app lets go of everything held, once; the real
    /// releases that follow are swallowed because the app never saw the presses. Coming back needs nothing:
    /// the next press starts afresh. Sleep, switching users and quitting apps don't pass through here, so
    /// they leave the state alone.
    private func syncBypass(_ state: inout State, app: String?, at location: CGPoint) {
        let bypassed = state.compiled.isBypassed(app: app)
        defer { state.bypassed = bypassed }
        guard bypassed, !state.bypassed else { return }
        synthesizer.cancelSmoothScroll()
        for (_, action) in state.processor.releaseAllForBypass() {
            synthesizer.perform(action, phase: .up, at: location, flags: [], clickState: 1)
        }
        synthesizer.releaseAll()
        state.debouncer.reset()
        armExpiry(&state)
        syncClickLock(&state)
    }

    /// Call with the state lock held, after anything the filter does. Sets a timer for the oldest press the filter
    /// is holding back, if any. The timer runs on the clock's own queue and only ever asks the filter what has
    /// expired. Also reports the local test.
    private func armExpiry(_ state: inout State) {
        reportClickFilterTest(&state)
        state.cancelExpiry?()
        state.cancelExpiry = nil
        guard let due = state.debouncer.nextDeadline else { return }
        state.cancelExpiry = clock.schedule(after: max(0, due - clock.now)) { [weak self] in self?.expireHeldClicks() }
    }

    private func expireHeldClicks() {
        state.withLock { state in
            let flushed = state.debouncer.expire(now: clock.now)
            if !state.stopped, !state.capturing { replay(flushed, &state) }
            armExpiry(&state)
        }
    }

    /// Starts the local duplicate-click test in Devices for one mouse, from zero, or ends it (nil). It only counts.
    func setClickFilterTest(device: String?) {
        state.withLock { state in
            if let device { state.debouncer.startTest(device: device, settings: state.compiled) } else { state.debouncer.stopTest() }
            reportClickFilterTest(&state)
        }
    }

    func clearClickFilterTest() {
        state.withLock { state in
            state.debouncer.clearTest()
            reportClickFilterTest(&state)
        }
    }

    /// Call with the state lock held. Hands the settings window a copy of the test when it changed. Copies leave in
    /// the order the lock was taken, so the last one to arrive is the latest; the tap never waits on the UI.
    private func reportClickFilterTest(_ state: inout State) {
        let test = state.debouncer.test
        guard test != state.reportedClickFilterTest else { return }
        state.reportedClickFilterTest = test
        guard let onClickFilterTest else { return }
        DispatchQueue.main.async { MainActor.assumeIsolated { onClickFilterTest(test) } }
    }

    /// Lets presses the filter held back through, in order, as if they had just arrived: mapped buttons run
    /// their action and unmapped ones are posted as synthetic clicks (which the tap ignores).
    /// Call with the state lock held.
    private func replay(_ flushed: [FlushedPress], _ state: inout State) {
        defer { syncClickLock(&state) }
        for press in flushed {
            // A press that waited can still let go of a Click Lock, but it can never begin one.
            let plan = state.processor.process(
                press.event, settings: state.compiled, slowPointerDevices: state.slowPointerDevices, startsClickLock: false
            )
            syncAutoScroll(&state)
            reportSlowPointer(&state)
            if ClickInterruption.isCalledOffBy(press.event.kind, plan: plan) { synthesizer.cancelPendingClicks() }
            let location = CGPoint(x: press.event.location?.x ?? 0, y: press.event.location?.y ?? 0)
            let flags = CGEventFlags(rawValue: press.event.modifiers.eventFlags & ModifierSet([.shift, .control, .option, .command]).eventFlags)
            guard case .buttonDown(let button) = press.event.kind else { continue }
            switch plan {
            case .passThrough:
                synthesizer.perform(.click(button: button, modifiers: []), phase: .down, at: location, flags: flags, clickState: press.clickCount)
            case let .perform(action, phase), let .performWithScroll(action, phase, _):
                state.actionSource = press.event.device?.id
                synthesizer.perform(action, phase: phase, at: location, flags: flags, clickState: press.clickCount)
            case let .performThenPassThrough(action, phase):
                state.actionSource = press.event.device?.id
                synthesizer.perform(action, phase: phase, at: location, flags: flags, clickState: press.clickCount)
                synthesizer.perform(.click(button: button, modifiers: []), phase: .down, at: location, flags: flags, clickState: press.clickCount)
            default:
                break
            }
        }
    }

    private static func cursorLocation() -> CGPoint {
        CGEvent(source: nil)?.location ?? .zero
    }

    // MARK: Tap thread

    func handle(_ type: CGEventType, _ event: CGEvent) -> Unmanaged<CGEvent>? {
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            // Releases may have been missed while the tap was off, so nothing held is trusted any more.
            let location = Self.cursorLocation()
            chords.reset(at: location)
            state.withLock { release(&$0, at: location, because: .tapInterrupted) }
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
        if event.getIntegerValueField(.eventSourceUserData) == ChordRouter.marker {
            chords.returned()
            return Unmanaged.passUnretained(event)
        }
        guard let kind = Self.inputKind(type, event) else { return Unmanaged.passUnretained(event) }

        let now = ProcessInfo.processInfo.systemUptime
        let originalClickState = event.getIntegerValueField(.mouseEventClickState)
        let reportKind: DeviceAttributor.ReportKind
        switch kind {
        case .buttonDown(let button), .buttonUp(let button), .buttonDragged(let button): reportKind = .button(button)
        case .scroll: reportKind = .wheel
        }
        let location = event.location
        var pending = InputEvent(
            kind,
            modifiers: ModifierSet(eventFlags: event.flags.rawValue),
            timestamp: now,
            device: attribute(reportKind, now),
            app: frontmostApp(),
            location: PointerPoint(x: location.x, y: location.y),
            clickCount: originalClickState
        )
        // Movement is only decoded and attributed while a hold or a gesture wants it; every other drag skips this.
        if case .buttonDragged = kind, state.withLock({ $0.processor.wantsMotion }) {
            pending.motion = PointerMotion(
                dx: Int(event.getIntegerValueField(.mouseEventDeltaX)),
                dy: Int(event.getIntegerValueField(.mouseEventDeltaY))
            )
            pending.motionDevice = attributeMotion(now)
        }
        return chords.route(event, pending, originalClickState: originalClickState)
    }

    /// Ordinary handling of one event, as if chords did not exist. A chord fallback replays held-back presses
    /// through here, so they get exactly what they would have had.
    func resolve(_ event: CGEvent, _ input: InputEvent, originalClickState: Int64) -> Unmanaged<CGEvent>? {
        let kind = input.kind
        let location = event.location
        let flags = CGEventFlags(rawValue: event.flags.rawValue & ModifierSet([.shift, .control, .option, .command]).eventFlags)
        let (plan, clickState) = state.withLock { state -> (EventPlan, Int64) in
            guard !state.capturing, !state.stopped else {
                // Even then, the release of a press the filter discarded never arrives without its press.
                return (state.debouncer.dropsOrphanedRelease(input) ? .swallow : .passThrough, originalClickState)
            }
            var clickState = originalClickState
            // A Click Lock whose app, profile or mapping has gone lets go before this event is handled.
            if state.processor.releaseStaleClickLock(app: input.app, settings: state.compiled) {
                finishClickLock(&state, ended: true, at: location, flags: flags)
            }
            let primaryEscape = input.kind == .buttonDown(0) && state.processor.isClickLockActive
            let outcome = state.debouncer.process(input, settings: state.compiled, preservingPress: primaryEscape)
            defer { armExpiry(&state) }
            replay(outcome.flushed, &state)
            switch outcome.decision {
            case .drop: return (.swallow, originalClickState)
            case .moveOnly: return (.dragAsMove, originalClickState)
            case .proceed(let count): clickState = count
            }
            var plan = state.processor.process(
                input, settings: state.compiled, slowPointerDevices: state.slowPointerDevices, startsClickLock: state.movement?.isReady == true,
                primaryEscape: primaryEscape
            )
            // A press or scroll that ended an auto-scroll stops its timer before the event goes on, and a press
            // that started one starts it. Both only touch a lock and a timer request, never the UI.
            syncAutoScroll(&state)
            // A hold starting takes over the scrolling: pending smoothing is dropped, never replayed.
            if state.processor.isHolding { synthesizer.cancelSmoothScroll() }
            // A scroll calls off a triple click whether or not smoothing takes it over.
            if ClickInterruption.isCalledOffBy(kind, plan: plan) { synthesizer.cancelPendingClicks() }
            if case let .smooth(request) = plan {
                plan = smooth(request, flags: event.flags.rawValue, reduceMotion: state.reduceMotion)
            }
            switch plan {
            case let .perform(action, phase), let .performWithScroll(action, phase, _), let .performThenPassThrough(action, phase):
                state.actionSource = input.device?.id
                synthesizer.perform(action, phase: phase, at: location, flags: flags, clickState: clickState)
            default:
                break
            }
            if case let .holdScroll(pixels, anchor) = plan {
                synthesizer.holdScroll(pixels, anchor: CGPoint(x: anchor.x, y: anchor.y))
            }
            reportHold(&state)
            syncClickLock(&state)
            return (plan, clickState)
        }
        // The filter dropped presses the system counted, so the count of a press that goes through is put right.
        if clickState != originalClickState { event.setIntegerValueField(.mouseEventClickState, value: clickState) }
        return apply(plan, to: event)
    }

    /// Call with the state lock held. Hands the distance over for spreading out and drops the original, or, when
    /// that isn't possible, falls back to what would have happened with smoothing off (fail open).
    private func smooth(_ request: SmoothRequest, flags: UInt64, reduceMotion: Bool) -> EventPlan {
        guard !reduceMotion else { return request.unsmoothed }
        let context = SmoothingContext(
            device: request.device, profile: request.profile, app: request.app, flags: flags & ~request.removing.eventFlags
        )
        let accepted = synthesizer.smoothScroll(
            vertical: request.sample.vertical.pixels, horizontal: request.sample.horizontal.pixels,
            context: context, durationMilliseconds: request.duration
        )
        return accepted ? .swallow : request.unsmoothed
    }

    private func apply(_ plan: EventPlan, to event: CGEvent) -> Unmanaged<CGEvent>? {
        switch plan {
        case .passThrough:
            return Unmanaged.passUnretained(event)
        case .swallow:
            return nil
        case .perform, .holdScroll:
            // Already posted under the state lock in `handle`.
            return nil
        case .performThenPassThrough:
            // Posted under the state lock in `handle`; the event itself carries on after it.
            return Unmanaged.passUnretained(event)
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
        case let .performWithScroll(_, _, remaining):
            // The action was posted under the state lock in `handle`; only the unmapped axis carries on.
            guard !remaining.isZero else { return nil }
            Self.write(remaining, to: event)
            return Unmanaged.passUnretained(event)
        case .smooth:
            // `handle` always settles it first.
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
            isContinuous: event.getIntegerValueField(.scrollWheelEventIsContinuous) != 0,
            isMomentum: momentum
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

extension EventEngine: ChordRouterHost {
    func chordGate(device: String, app: String?) -> ChordGate {
        state.withLock { state in
            let compiled = state.compiled
            guard !state.capturing, !state.stopped, compiled.general.enabled, !compiled.isBypassed(app: app),
                  compiled.settings.devices[device]?.enabled != false else { return .closed }
            let allowPrimary = compiled.general.allowPrimaryButtonRemap
            var chords = compiled.profile(device: device, app: app).chords
            // Swapped, the secondary button is the primary one, and keeps the same protection.
            if compiled.swappedDevices.contains(device), !allowPrimary {
                chords.removeAll { $0.contains(1) && $0.modifiers.withoutFunction.isEmpty }
            }
            return ChordGate(chords: chords, allowPrimary: allowPrimary,
                             outputsIdle: state.processor.ownsNoOutput && !state.debouncer.hasPending)
        }
    }

    func performChord(_ action: Action, _ phase: ActionPhase, at location: CGPoint, flags: CGEventFlags) {
        state.withLock { _ in synthesizer.perform(action, phase: phase, at: location, flags: flags, clickState: 1) }
    }
}
