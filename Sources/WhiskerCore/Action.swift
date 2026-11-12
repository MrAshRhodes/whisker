import Foundation

public enum MediaKey: String, Codable, CaseIterable, Sendable {
    case playPause, next, previous, volumeUp, volumeDown, mute, brightnessUp, brightnessDown

    public var title: String {
        switch self {
        case .playPause: return "Play/Pause"
        case .next: return "Next Track"
        case .previous: return "Previous Track"
        case .volumeUp: return "Volume Up"
        case .volumeDown: return "Volume Down"
        case .mute: return "Mute"
        case .brightnessUp: return "Brightness Up"
        case .brightnessDown: return "Brightness Down"
        }
    }

    public var symbolName: String {
        switch self {
        case .playPause: return "playpause"
        case .next: return "forward"
        case .previous: return "backward"
        case .volumeUp: return "speaker.wave.3"
        case .volumeDown: return "speaker.wave.1"
        case .mute: return "speaker.slash"
        case .brightnessUp: return "sun.max"
        case .brightnessDown: return "sun.min"
        }
    }

    /// The `NX_KEYTYPE_*` value from `<IOKit/hidsystem/ev_keymap.h>` posted as a system-defined event.
    public var systemKeyType: Int {
        switch self {
        case .volumeUp: return 0
        case .volumeDown: return 1
        case .brightnessUp: return 2
        case .brightnessDown: return 3
        case .mute: return 7
        case .playPause: return 16
        case .next: return 17
        case .previous: return 18
        }
    }

    /// Volume and brightness keys repeat while the trigger is held, like the keys on a keyboard.
    public var repeats: Bool {
        switch self {
        case .volumeUp, .volumeDown, .brightnessUp, .brightnessDown: return true
        default: return false
        }
    }
}

public enum NavigationDirection: String, Codable, CaseIterable, Sendable {
    case back, forward

    public var title: String { self == .back ? "Back" : "Forward" }
    public var symbolName: String { self == .back ? "chevron.backward" : "chevron.forward" }

    /// ⌘[ and ⌘], which Finder, Safari and most document browsers use.
    public var shortcut: KeyShortcut {
        KeyShortcut(keyCode: self == .back ? 0x21 : 0x1E, modifiers: .command)
    }
}

public enum MissionControlTarget: String, Codable, CaseIterable, Sendable {
    case missionControl, appWindows, showDesktop, launchpad, notificationCentre

    public var title: String {
        switch self {
        case .missionControl: return "Mission Control"
        case .appWindows: return "Application Windows"
        case .showDesktop: return "Show Desktop"
        case .launchpad: return "Launchpad"
        case .notificationCentre: return "Notification Centre"
        }
    }

    public var symbolName: String {
        switch self {
        case .missionControl: return "rectangle.3.group"
        case .appWindows: return "macwindow.on.rectangle"
        case .showDesktop: return "desktopcomputer"
        case .launchpad: return "square.grid.3x3"
        case .notificationCentre: return "bell"
        }
    }

    /// Whether opening an app in /System/Applications does the same job when the shortcut is off.
    public var hasAppFallback: Bool { !fallbackApps.isEmpty }

    /// Apps in /System/Applications to try, in order, when the shortcut is off. Launchpad became Apps in macOS 26.
    public var fallbackApps: [String] {
        switch self {
        case .missionControl: return ["Mission Control"]
        case .launchpad: return ["Launchpad", "Apps"]
        default: return []
        }
    }

    public var systemShortcut: SystemShortcutID {
        switch self {
        case .missionControl: return .missionControl
        case .appWindows: return .applicationWindows
        case .showDesktop: return .showDesktop
        case .launchpad: return .launchpad
        case .notificationCentre: return .notificationCentre
        }
    }
}

public enum SpaceDirection: String, Codable, CaseIterable, Sendable {
    case left, right

    public var title: String { self == .left ? "Space on the Left" : "Space on the Right" }
    public var symbolName: String { self == .left ? "arrow.left.square" : "arrow.right.square" }
    public var systemShortcut: SystemShortcutID { self == .left ? .moveLeftSpace : .moveRightSpace }
}

public enum AppSwitchDirection: String, Codable, CaseIterable, Sendable {
    case next, previous

    public var title: String { self == .next ? "Last Used App" : "Least Recently Used App" }
}

/// Everything a trigger can do. Encoded as `{"kind": "...", ...parameters}`.
public enum Action: Hashable, Sendable {
    /// Leave the event alone.
    case passthrough
    /// Swallow the event and do nothing.
    case none
    /// Press a mouse button for as long as the trigger is held.
    case click(button: Int, modifiers: ModifierSet)
    case doubleClick(modifiers: ModifierSet)
    /// Three left clicks in a row at the pointer, counted 1, 2 and 3. What an app does with them (some
    /// select a line or paragraph) is up to the app.
    case tripleClick(modifiers: ModifierSet)
    case shortcut(KeyShortcut, repeatWhileHeld: Bool)
    /// Several shortcuts one after another, run once per activation within `ShortcutSequenceLimits`.
    case shortcutSequence([SequenceStep])
    case scroll(direction: WheelDirection, lines: Int)
    case media(MediaKey)
    case navigate(NavigationDirection)
    case missionControl(MissionControlTarget)
    case space(SpaceDirection)
    case appSwitch(AppSwitchDirection)
    /// While the button is held, movement of the device that pressed it scrolls instead of moving the pointer.
    case holdToScroll(HoldScroll)
    /// An app, file or web address.
    case open(url: String)
    /// Switch one device's pointer speed to a saved preset. Both ids are explicit, so the mapping keeps
    /// working when presets are renamed or reordered and never lands on another device.
    case pointerPreset(deviceID: String, presetID: String)

    public var kind: ActionKind {
        switch self {
        case .passthrough: return .passthrough
        case .none: return .none
        case .click: return .click
        case .doubleClick: return .doubleClick
        case .tripleClick: return .tripleClick
        case .shortcut: return .shortcut
        case .shortcutSequence: return .shortcutSequence
        case .scroll: return .scroll
        case .media: return .media
        case .navigate: return .navigate
        case .missionControl: return .missionControl
        case .space: return .space
        case .appSwitch: return .appSwitch
        case .holdToScroll: return .holdToScroll
        case .open: return .open
        case .pointerPreset: return .pointerPreset
        }
    }

    /// Whether the action needs to see pointer movement, not just buttons and the wheel.
    public var usesMotion: Bool {
        if case .holdToScroll = self { return true }
        return false
    }

    /// Actions that follow the trigger: pressed while it is down, released when it comes up.
    public var followsTrigger: Bool {
        switch self {
        case .click: return true
        case .shortcut(_, let repeats): return repeats
        case .media(let key): return key.repeats
        default: return false
        }
    }

    /// The system keyboard shortcut this action can't work without. Mission Control and Launchpad
    /// fall back to opening the app, so they don't need one.
    public var systemShortcut: SystemShortcutID? {
        switch self {
        case .missionControl(let target):
            return target.hasAppFallback ? nil : target.systemShortcut
        case .space(let direction): return direction.systemShortcut
        default: return nil
        }
    }

    /// How a Mission Control or Spaces action gets carried out with the user's current keyboard shortcuts:
    /// post the shortcut, open the fallback app when the shortcut is off, or nothing (nil) when neither works.
    public func systemShortcutPlan(_ shortcuts: SystemShortcutProviding) -> SystemShortcutPlan? {
        let id: SystemShortcutID
        switch self {
        case .missionControl(let target): id = target.systemShortcut
        case .space(let direction): id = direction.systemShortcut
        default: return nil
        }
        if let shortcut = shortcuts.status(of: id).shortcut { return .post(shortcut) }
        if case .missionControl(let target) = self, !target.fallbackApps.isEmpty { return .openApp(target.fallbackApps) }
        return .unavailable(id)
    }

    /// One line describing the action, for lists and the menu bar.
    public var summary: String {
        switch self {
        case .passthrough: return "Default"
        case .none: return "Do Nothing"
        case let .click(button, modifiers):
            let name: String
            switch button {
            case 0: name = "Left Click"
            case 1: name = "Right Click"
            case 2: name = "Middle Click"
            default: name = "Button \(button + 1) Click"
            }
            return modifiers.isEmpty ? name : "\(modifiers.symbols) \(name)"
        case .doubleClick(let modifiers): return modifiers.isEmpty ? "Double Click" : "\(modifiers.symbols) Double Click"
        case .tripleClick(let modifiers): return modifiers.isEmpty ? "Triple Click" : "\(modifiers.symbols) Triple Click"
        case let .shortcut(shortcut, _): return "Keyboard Shortcut \(shortcut.displayString)"
        case .shortcutSequence(let steps): return "Shortcut Sequence \(steps.map(\.shortcut.displayString).joined(separator: " → "))"
        case let .scroll(direction, lines): return "\(direction.title) \(lines) \(lines == 1 ? "Line" : "Lines")"
        case .media(let key): return key.title
        case .navigate(let direction): return direction.title
        case .missionControl(let target): return target.title
        case .space(let direction): return "Move to \(direction.title)"
        case .appSwitch(let direction): return "Switch to \(direction.title)"
        case .holdToScroll(let config): return config.summary
        case .open(let url): return "Open \(Self.openTitle(url))"
        case .pointerPreset: return "Pointer Speed Preset"
        }
    }

    public var symbolName: String {
        switch self {
        case .media(let key): return key.symbolName
        case .navigate(let direction): return direction.symbolName
        case .missionControl(let target): return target.symbolName
        case .space(let direction): return direction.symbolName
        case .scroll(let direction, _): return direction.symbolName
        default: return kind.symbolName
        }
    }

    /// What an Open action points at: an absolute or `~` path becomes a file URL, anything else must be a URL
    /// with a scheme. Nil when the text is neither.
    public static func openURL(for string: String) -> URL? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        if trimmed.hasPrefix("/") || trimmed.hasPrefix("~") {
            return URL(fileURLWithPath: (trimmed as NSString).expandingTildeInPath)
        }
        guard let url = URL(string: trimmed), url.scheme != nil else { return nil }
        return url
    }

    static func openTitle(_ string: String) -> String {
        guard let url = openURL(for: string) else { return "Nothing" }
        if url.isFileURL {
            let name = url.deletingPathExtension().lastPathComponent
            return name.isEmpty ? url.path : name
        }
        return url.host ?? string
    }
}

/// The action families offered in the action picker, in menu order.
public enum ActionKind: String, CaseIterable, Identifiable, Sendable {
    case passthrough, none, click, doubleClick, tripleClick, shortcut, shortcutSequence, navigate, media, missionControl, space, appSwitch, scroll, holdToScroll, pointerPreset, open

    public var id: String { rawValue }

    public var title: String {
        switch self {
        case .passthrough: return "Default"
        case .none: return "Do Nothing"
        case .click: return "Click"
        case .doubleClick: return "Double Click"
        case .tripleClick: return "Triple Click"
        case .shortcut: return "Keyboard Shortcut"
        case .shortcutSequence: return "Keyboard Shortcut Sequence"
        case .navigate: return "Back or Forward"
        case .media: return "Media Key"
        case .missionControl: return "Mission Control"
        case .space: return "Switch Space"
        case .appSwitch: return "Switch App"
        case .scroll: return "Scroll"
        case .holdToScroll: return "Hold to Scroll (Experimental)"
        case .pointerPreset: return "Pointer Speed Preset"
        case .open: return "Open App, File or Website"
        }
    }

    public var symbolName: String {
        switch self {
        case .passthrough: return "computermouse"
        case .none: return "nosign"
        case .click: return "cursorarrow.click"
        case .doubleClick: return "cursorarrow.click.2"
        case .tripleClick: return "cursorarrow.motionlines.click"
        case .shortcut: return "keyboard"
        case .shortcutSequence: return "list.number"
        case .navigate: return "arrow.left.arrow.right"
        case .media: return "playpause"
        case .missionControl: return "rectangle.3.group"
        case .space: return "square.split.2x1"
        case .appSwitch: return "rectangle.stack"
        case .scroll: return "arrow.up.and.down"
        case .holdToScroll: return "arrow.up.and.down.and.arrow.left.and.right"
        case .pointerPreset: return "cursorarrow.motionlines"
        case .open: return "arrow.up.forward.app"
        }
    }

    /// The action a new mapping of this kind starts with. A pointer speed preset starts without a mouse or
    /// preset, which validation rejects: pick them (`WhiskerSettings.firstPointerPreset`) before saving.
    public var defaultAction: Action {
        switch self {
        case .passthrough: return .passthrough
        case .none: return .none
        case .click: return .click(button: 2, modifiers: [])
        case .doubleClick: return .doubleClick(modifiers: [])
        case .tripleClick: return .tripleClick(modifiers: [])
        case .shortcut: return .shortcut(KeyShortcut(keyCode: 0x11, modifiers: .command), repeatWhileHeld: false)
        case .shortcutSequence:
            return .shortcutSequence([
                SequenceStep(shortcut: KeyShortcut(keyCode: 0x00, modifiers: .command)),
                SequenceStep(shortcut: KeyShortcut(keyCode: 0x08, modifiers: .command)),
            ])
        case .navigate: return .navigate(.back)
        case .media: return .media(.playPause)
        case .missionControl: return .missionControl(.missionControl)
        case .space: return .space(.left)
        case .appSwitch: return .appSwitch(.next)
        case .scroll: return .scroll(direction: .down, lines: 3)
        case .holdToScroll: return .holdToScroll(HoldScroll())
        case .pointerPreset: return .pointerPreset(deviceID: "", presetID: "")
        case .open: return .open(url: "")
        }
    }
}

extension Action: Codable {
    private enum CodingKeys: String, CodingKey {
        case kind, button, modifiers, keyCode, repeatWhileHeld, direction, lines, key, target, url, steps, axes, sensitivity, invertVertical, invertHorizontal
        case device, preset
    }

    public init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let kind = try container.decode(String.self, forKey: .kind)
        func modifiers() throws -> ModifierSet {
            try container.decodeIfPresent(ModifierSet.self, forKey: .modifiers) ?? []
        }
        switch kind {
        case "passthrough": self = .passthrough
        case "none": self = .none
        case "click": self = .click(button: try container.decode(Int.self, forKey: .button), modifiers: try modifiers())
        case "doubleClick": self = .doubleClick(modifiers: try modifiers())
        case "tripleClick": self = .tripleClick(modifiers: try modifiers())
        case "shortcut":
            self = .shortcut(
                KeyShortcut(keyCode: try container.decode(UInt16.self, forKey: .keyCode), modifiers: try modifiers()),
                repeatWhileHeld: try container.decodeIfPresent(Bool.self, forKey: .repeatWhileHeld) ?? false
            )
        case "shortcutSequence": self = .shortcutSequence(try container.decode([SequenceStep].self, forKey: .steps))
        case "scroll":
            self = .scroll(
                direction: try container.decode(WheelDirection.self, forKey: .direction),
                lines: try container.decodeIfPresent(Int.self, forKey: .lines) ?? 3
            )
        case "media": self = .media(try container.decode(MediaKey.self, forKey: .key))
        case "navigate": self = .navigate(try container.decode(NavigationDirection.self, forKey: .direction))
        case "missionControl": self = .missionControl(try container.decode(MissionControlTarget.self, forKey: .target))
        case "space": self = .space(try container.decode(SpaceDirection.self, forKey: .direction))
        case "appSwitch": self = .appSwitch(try container.decode(AppSwitchDirection.self, forKey: .direction))
        case "holdToScroll":
            self = .holdToScroll(HoldScroll(
                axes: try container.decodeIfPresent(HoldScrollAxes.self, forKey: .axes) ?? .vertical,
                sensitivity: try container.decodeIfPresent(Double.self, forKey: .sensitivity) ?? 1,
                invertVertical: try container.decodeIfPresent(Bool.self, forKey: .invertVertical) ?? false,
                invertHorizontal: try container.decodeIfPresent(Bool.self, forKey: .invertHorizontal) ?? false
            ))
        case "open": self = .open(url: try container.decode(String.self, forKey: .url))
        case "pointerPreset":
            self = .pointerPreset(
                deviceID: try container.decode(String.self, forKey: .device),
                presetID: try container.decode(String.self, forKey: .preset)
            )
        default:
            throw DecodingError.dataCorruptedError(forKey: .kind, in: container, debugDescription: "Unknown action “\(kind)”.")
        }
    }

    public func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .passthrough: try container.encode("passthrough", forKey: .kind)
        case .none: try container.encode("none", forKey: .kind)
        case let .click(button, modifiers):
            try container.encode("click", forKey: .kind)
            try container.encode(button, forKey: .button)
            try container.encode(modifiers, forKey: .modifiers)
        case .doubleClick(let modifiers):
            try container.encode("doubleClick", forKey: .kind)
            try container.encode(modifiers, forKey: .modifiers)
        case .tripleClick(let modifiers):
            try container.encode("tripleClick", forKey: .kind)
            try container.encode(modifiers, forKey: .modifiers)
        case let .shortcut(shortcut, repeats):
            try container.encode("shortcut", forKey: .kind)
            try container.encode(shortcut.keyCode, forKey: .keyCode)
            try container.encode(shortcut.modifiers, forKey: .modifiers)
            try container.encode(repeats, forKey: .repeatWhileHeld)
        case .shortcutSequence(let steps):
            try container.encode("shortcutSequence", forKey: .kind)
            try container.encode(steps, forKey: .steps)
        case let .scroll(direction, lines):
            try container.encode("scroll", forKey: .kind)
            try container.encode(direction, forKey: .direction)
            try container.encode(lines, forKey: .lines)
        case .media(let key):
            try container.encode("media", forKey: .kind)
            try container.encode(key, forKey: .key)
        case .navigate(let direction):
            try container.encode("navigate", forKey: .kind)
            try container.encode(direction, forKey: .direction)
        case .missionControl(let target):
            try container.encode("missionControl", forKey: .kind)
            try container.encode(target, forKey: .target)
        case .space(let direction):
            try container.encode("space", forKey: .kind)
            try container.encode(direction, forKey: .direction)
        case .appSwitch(let direction):
            try container.encode("appSwitch", forKey: .kind)
            try container.encode(direction, forKey: .direction)
        case .holdToScroll(let config):
            try container.encode("holdToScroll", forKey: .kind)
            try container.encode(config.axes, forKey: .axes)
            try container.encode(config.sensitivity, forKey: .sensitivity)
            try container.encode(config.invertVertical, forKey: .invertVertical)
            try container.encode(config.invertHorizontal, forKey: .invertHorizontal)
        case .open(let url):
            try container.encode("open", forKey: .kind)
            try container.encode(url, forKey: .url)
        case let .pointerPreset(deviceID, presetID):
            try container.encode("pointerPreset", forKey: .kind)
            try container.encode(deviceID, forKey: .device)
            try container.encode(presetID, forKey: .preset)
        }
    }
}

public enum SystemShortcutPlan: Equatable, Sendable {
    case post(KeyShortcut)
    /// Open the first of these apps in /System/Applications that exists.
    case openApp([String])
    /// The shortcut is off or unassigned and there's no app to fall back on.
    case unavailable(SystemShortcutID)
}
