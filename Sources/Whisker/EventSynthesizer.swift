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

/// Posts the events and runs the commands that mapped actions turn into.
///
/// Clicks are posted straight away from the event tap so they stay in order with the real events around them;
/// everything else runs on a serial queue (or the main thread) so the tap never waits.
final class EventSynthesizer: @unchecked Sendable {
    /// Marks Whisker's own events so the tap lets them through.
    static let marker: Int64 = 0x5748_4B52

    private let queue = DispatchQueue(label: "io.github.mrashrhodes.whisker.actions", qos: .userInteractive)
    private let shortcuts: SystemShortcutProviding
    private let switchApp: @MainActor (AppSwitchDirection) -> Void
    private var repeatTimer: DispatchSourceTimer?

    init(shortcuts: SystemShortcutProviding = SystemShortcutReader(), switchApp: @escaping @MainActor (AppSwitchDirection) -> Void) {
        self.shortcuts = shortcuts
        self.switchApp = switchApp
    }

    /// Runs on the event tap thread.
    func perform(_ action: Action, phase: ActionPhase, at location: CGPoint, flags: CGEventFlags) {
        switch action {
        case .passthrough, .none:
            return
        case let .click(button, modifiers):
            let held = CGEventFlags(rawValue: flags.rawValue | modifiers.eventFlags)
            switch phase {
            case .down: postMouse(button: button, down: true, at: location, flags: held, clickState: 1)
            case .up: postMouse(button: button, down: false, at: location, flags: held, clickState: 1)
            case .once:
                postMouse(button: button, down: true, at: location, flags: held, clickState: 1)
                postMouse(button: button, down: false, at: location, flags: held, clickState: 1)
            }
        case .doubleClick(let modifiers):
            guard phase != .up else { return }
            let held = CGEventFlags(rawValue: flags.rawValue | modifiers.eventFlags)
            for state in 1...2 {
                postMouse(button: 0, down: true, at: location, flags: held, clickState: Int64(state))
                postMouse(button: 0, down: false, at: location, flags: held, clickState: Int64(state))
            }
        case let .shortcut(shortcut, repeats):
            runRepeating(phase: phase, repeats: repeats) { [weak self] in self?.postKey(shortcut) }
        case .media(let key):
            runRepeating(phase: phase, repeats: key.repeats) { [weak self] in self?.postMedia(key) }
        case .scroll(let direction, let lines):
            guard phase != .up else { return }
            queue.async { [weak self] in self?.postScroll(direction, lines: lines) }
        case .navigate(let direction):
            guard phase != .up else { return }
            queue.async { [weak self] in self?.postKey(direction.shortcut) }
        case .missionControl, .space:
            guard phase != .up, let plan = action.systemShortcutPlan(shortcuts) else { return }
            queue.async { [weak self] in self?.perform(plan) }
        case .appSwitch(let direction):
            guard phase != .up else { return }
            let switchApp = self.switchApp
            DispatchQueue.main.async { MainActor.assumeIsolated { switchApp(direction) } }
        case .open(let string):
            guard phase != .up else { return }
            DispatchQueue.main.async { Self.open(string) }
        }
    }

    /// Stops a repeating key and lets go of anything held.
    func releaseAll() {
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
        event.setIntegerValueField(.eventSourceUserData, value: Self.marker)
    }

    private func postMouse(button: Int, down: Bool, at location: CGPoint, flags: CGEventFlags, clickState: Int64) {
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
        let url: URL?
        if string.hasPrefix("/") || string.hasPrefix("~") {
            url = URL(fileURLWithPath: (string as NSString).expandingTildeInPath)
        } else {
            url = URL(string: string)
        }
        guard let url else {
            NSSound.beep()
            return
        }
        NSWorkspace.shared.open(url)
    }
}
