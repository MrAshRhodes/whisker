import AppKit
import CoreGraphics
import WhiskerCore

/// Reads the system keyboard shortcuts some actions post (Mission Control, Spaces…).
struct SystemShortcutReader: SystemShortcutProviding {
    func status(of id: SystemShortcutID) -> SystemShortcutStatus {
        let dictionary = UserDefaults(suiteName: "com.apple.symbolichotkeys")?.dictionary(forKey: "AppleSymbolicHotKeys")
        return SymbolicHotKeyTable(dictionary: dictionary).status(of: id)
    }
}

/// Turns mapped actions into events and commands. The event engine talks to this rather than to
/// `EventSynthesizer` so tests can watch what it asks for.
protocol ActionPerforming: AnyObject, Sendable {
    /// `clickState` is the click count of the real press, carried over to synthetic clicks.
    func perform(_ action: Action, phase: ActionPhase, at location: CGPoint, flags: CGEventFlags, clickState: Int64)
    /// Calls off a click gesture that is still posting its clicks (a triple click spread out over time).
    func cancelPendingClicks()
    /// Calls off a keyboard shortcut sequence that is still running; steps already posted stay posted.
    func cancelSequence(_ reason: SequenceStop)
    /// Lets go of everything held and stops repeating keys. Calls off a pending click gesture and a running
    /// shortcut sequence too.
    func releaseAll()
    /// Scrolls by whole pixels and puts the pointer back on `anchor`.
    func holdScroll(_ pixels: ScrollPixels, anchor: CGPoint)
    /// Hands pixel distance to smooth scrolling. False means it was refused and the caller must deliver the
    /// event itself.
    func smoothScroll(vertical: Double, horizontal: Double, context: SmoothingContext, durationMilliseconds: Int) -> Bool
    /// Drops smooth scrolling that is still waiting; none of it is delivered later.
    func cancelSmoothScroll()
    /// Drops it when it came from a device that is no longer connected.
    func cancelSmoothScroll(unlessConnected connected: Set<String>)
    /// Starts scrolling for an auto-scroll, in place of any that was running. Never posts for a session that has
    /// been cancelled, and keeps no timer while there is none.
    func startAutoScroll(_ session: AutoScrollSession)
    /// Ends the auto-scroll that is running. Nothing is posted for it once this returns.
    func cancelAutoScroll()
}

extension ActionPerforming {
    func holdScroll(_ pixels: ScrollPixels, anchor: CGPoint) {}
    func smoothScroll(vertical: Double, horizontal: Double, context: SmoothingContext, durationMilliseconds: Int) -> Bool { false }
    func cancelSmoothScroll() {}
    func cancelSmoothScroll(unlessConnected connected: Set<String>) {}
    func startAutoScroll(_ session: AutoScrollSession) {}
    func cancelAutoScroll() {}
}

/// Posts the events and runs the commands that mapped actions turn into.
///
/// Clicks are posted straight away from the event tap so they stay in order with the real events around them;
/// everything else runs on a serial queue (or the main thread) so the tap never waits.
final class EventSynthesizer: ActionPerforming, @unchecked Sendable {
    /// Marks Whisker's own events so the tap lets them through.
    static let marker: Int64 = 0x5748_4B52

    private let queue = DispatchQueue(label: "io.github.mrashrhodes.whisker.actions", qos: .userInteractive)
    private let shortcuts: SystemShortcutProviding
    private let switchApp: @MainActor (AppSwitchDirection) -> Void
    private let selectPointerPreset: @MainActor (_ deviceID: String, _ presetID: String) -> Void
    private let clicks: ClickScheduler
    private let tripleClickTiming: @Sendable () -> ClickTiming
    private let sequences: ShortcutSequenceRunner
    private var repeatTimer: DispatchSourceTimer?
    private let smoother = SmoothScroller()
    private let autoScroller = AutoScroller()

    /// `tripleClickTiming` is asked at every activation. It posts all three clicks back to back, like Double Click
    /// does, until spacing them out is shown to be needed: `{ .spaced(withinInterval: NSEvent.doubleClickInterval) }`.
    init(
        shortcuts: SystemShortcutProviding = SystemShortcutReader(),
        switchApp: @escaping @MainActor (AppSwitchDirection) -> Void,
        selectPointerPreset: @escaping @MainActor (_ deviceID: String, _ presetID: String) -> Void = { _, _ in },
        clicks: ClickScheduler = ClickScheduler(post: { EventSynthesizer.postClick($0, at: $1, flags: $2) }),
        tripleClickTiming: @escaping @Sendable () -> ClickTiming = { .immediate },
        sequences: ShortcutSequenceRunner = ShortcutSequenceRunner(
            environment: SystemSequenceEnvironment(frontmost: { nil }, marker: EventSynthesizer.marker), stopped: { _ in }
        )
    ) {
        self.shortcuts = shortcuts
        self.switchApp = switchApp
        self.selectPointerPreset = selectPointerPreset
        self.clicks = clicks
        self.tripleClickTiming = tripleClickTiming
        self.sequences = sequences
    }

    /// Runs on the event tap thread.
    func perform(_ action: Action, phase: ActionPhase, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {
        switch action {
        case .passthrough, .none:
            return
        case let .click(button, modifiers):
            let held = CGEventFlags(rawValue: flags.rawValue | modifiers.eventFlags)
            let count = max(1, clickState)
            switch phase {
            case .down: postMouse(button: button, down: true, at: location, flags: held, clickState: count)
            case .up: postMouse(button: button, down: false, at: location, flags: held, clickState: count)
            case .once:
                postMouse(button: button, down: true, at: location, flags: held, clickState: count)
                postMouse(button: button, down: false, at: location, flags: held, clickState: count)
            }
        case .doubleClick(let modifiers):
            guard phase != .up else { return }
            let held = CGEventFlags(rawValue: flags.rawValue | modifiers.eventFlags)
            for state in 1...2 {
                postMouse(button: 0, down: true, at: location, flags: held, clickState: Int64(state))
                postMouse(button: 0, down: false, at: location, flags: held, clickState: Int64(state))
            }
        case .tripleClick(let modifiers):
            // The trigger's release doesn't end the gesture: one press is one triple click.
            guard phase != .up else { return }
            let held = CGEventFlags(rawValue: flags.rawValue | modifiers.eventFlags)
            clicks.start(.tripleClick, timing: tripleClickTiming(), at: location, flags: held)
        case .clickLock:
            // Only the press that starts the lock and the one release that ends it are ever posted.
            switch phase {
            case .down: postMouse(button: 0, down: true, at: location, flags: flags, clickState: 1)
            case .up: postMouse(button: 0, down: false, at: location, flags: flags, clickState: 1)
            case .once: return
            }
        case let .shortcut(shortcut, repeats):
            runRepeating(phase: phase, repeats: repeats) { [weak self] in self?.postKey(shortcut) }
        case .shortcutSequence(let steps):
            // One press is one run; the release doesn't end it. The runner posts from its own queue.
            guard phase != .up else { return }
            sequences.activate(steps)
        case .media(let key):
            runRepeating(phase: phase, repeats: key.repeats) { [weak self] in self?.postMedia(key) }
        case .scroll(let direction, let lines):
            guard phase != .up else { return }
            queue.async { [weak self] in self?.postScroll(direction, lines: lines) }
        case .navigate(let direction):
            guard phase != .up else { return }
            queue.async { [weak self] in self?.postKey(direction.shortcut) }
        case .missionControl, .space:
            guard phase != .up else { return }
            // Reading the shortcut table touches user defaults, so it stays off the event tap thread.
            queue.async { [weak self] in
                guard let self, let plan = action.systemShortcutPlan(self.shortcuts) else { return }
                self.perform(plan)
            }
        case .appSwitch(let direction):
            guard phase != .up else { return }
            let switchApp = self.switchApp
            DispatchQueue.main.async { MainActor.assumeIsolated { switchApp(direction) } }
        case .holdToScroll, .slowPointer:
            // Driven by pointer movement through `holdScroll`, not by the press itself.
            return
        case .autoScroll:
            // The engine starts it from the processor's session through `startAutoScroll`.
            return
        case .open(let string):
            guard phase != .up else { return }
            DispatchQueue.main.async { Self.open(string) }
        case let .pointerPreset(deviceID, presetID):
            guard phase != .up else { return }
            // The pointer controller is the main actor's, and the tap thread never waits for it.
            let select = self.selectPointerPreset
            DispatchQueue.main.async { MainActor.assumeIsolated { select(deviceID, presetID) } }
        }
    }

    /// Runs on the event tap thread, inline, so scrolling stays in step with the movement that caused it.
    ///
    /// The pointer is put back with `CGWarpMouseCursorPosition` (public API; the mouse stays associated with the
    /// cursor). Whether that keeps the pointer still without a visible shake or a jump on release has not been
    /// verified on hardware; the event processor watches for drift and falls back to ordinary movement.
    func holdScroll(_ pixels: ScrollPixels, anchor: CGPoint) {
        CGWarpMouseCursorPosition(anchor)
        guard !pixels.isZero,
              let event = CGEvent(scrollWheelEvent2Source: nil, units: .pixel, wheelCount: 2, wheel1: Int32(clamping: pixels.vertical), wheel2: Int32(clamping: pixels.horizontal), wheel3: 0)
        else { return }
        event.location = anchor
        mark(event)
        event.post(tap: .cghidEventTap)
    }

    func smoothScroll(vertical: Double, horizontal: Double, context: SmoothingContext, durationMilliseconds: Int) -> Bool {
        smoother.enqueue(vertical: vertical, horizontal: horizontal, context: context, durationMilliseconds: durationMilliseconds)
    }

    func cancelSmoothScroll() {
        smoother.cancel()
    }

    func cancelSmoothScroll(unlessConnected connected: Set<String>) {
        smoother.cancel(unlessConnected: connected)
    }

    func startAutoScroll(_ session: AutoScrollSession) {
        autoScroller.start(session)
    }

    func cancelAutoScroll() {
        autoScroller.cancel()
    }

    /// Calls off a click gesture that is still under way; a press already posted gets its release.
    func cancelPendingClicks() {
        clicks.cancel()
    }

    func cancelSequence(_ reason: SequenceStop) {
        sequences.cancel(reason)
    }

    /// Stops a repeating key, calls off a sequence and lets go of anything held.
    func releaseAll() {
        clicks.cancel()
        sequences.cancel(.lifecycle)
        autoScroller.cancel()
        queue.async { [weak self] in self?.stopRepeat() }
    }

    // MARK: Repeating

    private func runRepeating(phase: ActionPhase, repeats: Bool, _ fire: @escaping () -> Void) {
        queue.async { [weak self] in
            guard let self else { return }
            switch phase {
            case .up:
                self.stopRepeat()
            case .once:
                fire()
            case .down:
                fire()
                guard repeats else { return }
                self.stopRepeat()
                let timer = DispatchSource.makeTimerSource(queue: self.queue)
                let delay = max(0.1, NSEvent.keyRepeatDelay)
                let interval = max(0.02, NSEvent.keyRepeatInterval)
                timer.schedule(deadline: .now() + delay, repeating: interval)
                timer.setEventHandler(handler: fire)
                timer.resume()
                self.repeatTimer = timer
            }
        }
    }

    private func stopRepeat() {
        repeatTimer?.cancel()
        repeatTimer = nil
    }

    // MARK: Posting

    private func mark(_ event: CGEvent) {
        Self.mark(event)
    }

    private static func mark(_ event: CGEvent) {
        event.setIntegerValueField(.eventSourceUserData, value: marker)
    }

    private func postMouse(button: Int, down: Bool, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {
        Self.postMouse(button: button, down: down, at: location, flags: flags, clickState: clickState)
    }

    /// Posts one event of a click gesture. Called from the event tap thread or a timer.
    static func postClick(_ step: ClickStep, at location: CGPoint, flags: CGEventFlags) {
        postMouse(button: step.button, down: step.isDown, at: location, flags: flags, clickState: step.clickState)
    }

    private static func postMouse(button: Int, down: Bool, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {
        let type: CGEventType
        let mouseButton: CGMouseButton
        switch button {
        case 0:
            type = down ? .leftMouseDown : .leftMouseUp
            mouseButton = .left
        case 1:
            type = down ? .rightMouseDown : .rightMouseUp
            mouseButton = .right
        default:
            type = down ? .otherMouseDown : .otherMouseUp
            mouseButton = CGMouseButton(rawValue: UInt32(button)) ?? .center
        }
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: location, mouseButton: mouseButton) else { return }
        event.flags = flags
        event.setIntegerValueField(.mouseEventButtonNumber, value: Int64(button))
        event.setIntegerValueField(.mouseEventClickState, value: clickState)
        mark(event)
        event.post(tap: .cghidEventTap)
    }

    private func postKey(_ shortcut: KeyShortcut) {
        let flags = CGEventFlags(rawValue: shortcut.eventFlags)
        for down in [true, false] {
            guard let event = CGEvent(keyboardEventSource: nil, virtualKey: shortcut.keyCode, keyDown: down) else { continue }
            event.flags = flags
            mark(event)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postMedia(_ key: MediaKey) {
        for down in [true, false] {
            let state = down ? 0xA : 0xB
            let data1 = (key.systemKeyType << 16) | (state << 8)
            guard let event = NSEvent.otherEvent(
                with: .systemDefined, location: .zero,
                modifierFlags: NSEvent.ModifierFlags(rawValue: UInt(state << 8)),
                timestamp: 0, windowNumber: 0, context: nil, subtype: 8, data1: data1, data2: -1
            )?.cgEvent else { continue }
            mark(event)
            event.post(tap: .cghidEventTap)
        }
    }

    private func postScroll(_ direction: WheelDirection, lines: Int) {
        let vertical: Int32 = direction == .up ? Int32(lines) : direction == .down ? -Int32(lines) : 0
        let horizontal: Int32 = direction == .left ? Int32(lines) : direction == .right ? -Int32(lines) : 0
        guard let event = CGEvent(scrollWheelEvent2Source: nil, units: .line, wheelCount: 2, wheel1: vertical, wheel2: horizontal, wheel3: 0) else { return }
        mark(event)
        event.post(tap: .cghidEventTap)
    }

    private func perform(_ plan: SystemShortcutPlan) {
        switch plan {
        case .post(let shortcut):
            postKey(shortcut)
        case .openApp(let names):
            DispatchQueue.main.async {
                let urls = names.map { URL(fileURLWithPath: "/System/Applications/\($0).app") }
                guard let url = urls.first(where: { FileManager.default.fileExists(atPath: $0.path) }) else {
                    NSSound.beep()
                    return
                }
                NSWorkspace.shared.openApplication(at: url, configuration: NSWorkspace.OpenConfiguration())
            }
        case .unavailable(let id):
            Log.events.notice("“\(id.title, privacy: .public)” has no keyboard shortcut in System Settings; nothing to post")
            DispatchQueue.main.async { NSSound.beep() }
        }
    }

    private static func open(_ string: String) {
        guard let url = Action.openURL(for: string) else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
