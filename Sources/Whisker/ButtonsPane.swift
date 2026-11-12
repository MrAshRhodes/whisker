import AppKit
import SwiftUI
import WhiskerCore

/// Holds the button recorder's state; the local event monitor lives here so it can be removed again.
@MainActor
final class ButtonRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private weak var model: AppModel?

    func start(model: AppModel, onCapture: @escaping (Trigger, ModifierSet) -> Void) {
        stop()
        self.model = model
        model.capturing = true
        isRecording = true
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 0x35 { self.stop() }
                return nil
            }
            guard let trigger = Self.trigger(for: event) else { return nil }
            let modifiers = ModifierSet(eventFlags: UInt64(event.modifierFlags.rawValue)).withoutFunction
            self.stop()
            onCapture(trigger, modifiers)
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isRecording { model?.capturing = false }
        isRecording = false
    }

    /// The trigger an event stands for, using the same wheel conventions as the event tap.
    static func trigger(for event: NSEvent) -> Trigger? {
        switch event.type {
        case .leftMouseDown: return .button(0)
        case .rightMouseDown: return .button(1)
        case .otherMouseDown: return .button(event.buttonNumber)
        case .scrollWheel:
            guard let cgEvent = event.cgEvent,
                  cgEvent.getIntegerValueField(.scrollWheelEventIsContinuous) == 0 else { return nil }
            let vertical = cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis1)
            let horizontal = cgEvent.getIntegerValueField(.scrollWheelEventDeltaAxis2)
            if vertical != 0 { return .wheel(vertical > 0 ? .up : .down) }
            if horizontal != 0 { return .wheel(horizontal > 0 ? .left : .right) }
            return nil
        default: return nil
        }
    }
}

// MARK: - Buttons

struct ButtonsPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @StateObject private var recorder = ButtonRecorder()
    @StateObject private var messages = MessageState()

    var body: some View {
        let profileID = store.settings.profile(id: model.selectedProfileID)?.id ?? Profile.defaultID
        let profile = model.profileBinding(profileID)
        let resolved = store.settings.resolvedProfile(id: profileID)
        let inherited = resolved.sortedMappings.filter(\.inherited)
        Form {
            Section {
                ProfilePicker(store: store)
            }
            Section {
                if profile.wrappedValue.mappings.isEmpty {
                    Text("No mappings yet. Record a button or pick one from Add to change what it does.")
                        .foregroundStyle(.secondary)
                }
                ForEach(profile.wrappedValue.mappings.indices, id: \.self) { index in
                    MappingRow(
                        mapping: mappingBinding(profile, index),
                        allowPrimary: store.settings.general.allowPrimaryButtonRemap,
                        onDelete: { profile.wrappedValue.mappings.remove(at: index) }
                    )
                }
                HStack {
                    if recorder.isRecording {
                        ProgressView().controlSize(.small)
                        Text("Press a mouse button or turn the wheel… (Esc to cancel)")
                        Spacer()
                        Button("Cancel") { recorder.stop() }
                    } else {
                        Button("Record Button…") {
                            messages.text = nil
                            recorder.start(model: model) { trigger, modifiers in
                                add(trigger, modifiers, to: profile)
                            }
                        }
                        Menu("Add") {
                            ForEach(3...7, id: \.self) { number in
                                Button(Trigger.buttonTitle(number)) { add(.button(number), [], to: profile) }
                            }
                            Divider()
                            Button(Trigger.buttonTitle(2)) { add(.button(2), [], to: profile) }
                            Divider()
                            ForEach(WheelDirection.allCases, id: \.self) { direction in
                                Button("Wheel \(direction.title)") { add(.wheel(direction), [], to: profile) }
                            }
                        }
                        .fixedSize()
                        Spacer()
                    }
                }
                if let message = messages.text {
                    Text(message).font(.footnote).foregroundStyle(.orange)
                }
            } header: {
                Text(profile.wrappedValue.isDefault ? "Mappings" : "Mappings in \(profile.wrappedValue.name)")
            } footer: {
                Text("Hold modifier keys while recording to map a combination, like ⌥ + Button 4.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !inherited.isEmpty {
                Section("Inherited") {
                    ForEach(inherited, id: \.mapping.key) { item in
                        HStack {
                            TriggerLabel(mapping: item.mapping)
                            Spacer()
                            Label(item.mapping.action.summary, systemImage: item.mapping.action.symbolName)
                                .foregroundStyle(.secondary)
                            Text("from \(store.settings.profile(id: item.sourceProfileID)?.name ?? item.sourceProfileID)")
                                .font(.footnote).foregroundStyle(.tertiary)
                            Button("Override") { profile.wrappedValue.mappings.append(item.mapping) }
                        }
                    }
                }
            }
        }
        .formStyle(.grouped)
        .onDisappear { recorder.stop() }
    }

    private func mappingBinding(_ profile: Binding<Profile>, _ index: Int) -> Binding<Mapping> {
        Binding(
            get: {
                let mappings = profile.wrappedValue.mappings
                return mappings.indices.contains(index) ? mappings[index] : Mapping(trigger: .button(2), action: .passthrough)
            },
            set: { value in
                guard profile.wrappedValue.mappings.indices.contains(index) else { return }
                let clash = profile.wrappedValue.mappings.enumerated().contains { $0.offset != index && $0.element.key == value.key }
                guard !clash else { return }
                profile.wrappedValue.mappings[index] = value
            }
        )
    }

    private func add(_ trigger: Trigger, _ modifiers: ModifierSet, to profile: Binding<Profile>) {
        let key = MappingKey(trigger, modifiers)
        if profile.wrappedValue.mapping(for: key) != nil {
            messages.text = "\(key.title) already has a mapping in this profile."
            return
        }
        var action = ActionKind.none.defaultAction
        if case .button(let number) = trigger {
            if number == 3 { action = .navigate(.back) } else if number == 4 { action = .navigate(.forward) }
        }
        let mapping = Mapping(trigger: trigger, modifiers: modifiers, action: action)
        if let problem = WhiskerSettings.problem(with: mapping, allowPrimary: store.settings.general.allowPrimaryButtonRemap) {
            messages.text = problem
            return
        }
        messages.text = nil
        profile.wrappedValue.mappings.append(mapping)
    }
}

struct TriggerLabel: View {
    let mapping: Mapping

    var body: some View {
        Label(MappingKey(mapping.trigger, mapping.modifiers).title, systemImage: mapping.trigger.symbolName)
    }
}

struct MappingRow: View {
    @Binding var mapping: Mapping
    let allowPrimary: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                TriggerLabel(mapping: mapping).font(.headline)
                Menu {
                    ForEach(ModifierSet.ordered.filter { $0.modifier != .function }, id: \.name) { entry in
                        Toggle(entry.title, isOn: modifierBinding(entry.modifier))
                    }
                } label: {
                    Image(systemName: "command")
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
                .help("Modifier keys to hold with this trigger")
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this mapping")
            }
            ActionEditor(action: $mapping.action)
            if case .wheel = mapping.trigger {
                Toggle("Repeat for every notch", isOn: $mapping.repeatPerNotch)
            }
            if mapping.trigger == .wheel(.left) || mapping.trigger == .wheel(.right) {
                Toggle("Also act on smooth scrolling from this mouse", isOn: Binding(
                    get: { mapping.continuousInput != nil },
                    set: { mapping.continuousInput = $0 ? ContinuousWheelInput() : nil }
                ))
                .help("Runs the action once per sideways swipe of a mouse that scrolls smoothly. Vertical scrolling at the same time carries on. Needs a mouse Whisker can identify; not yet verified on hardware.")
                if let continuous = mapping.continuousInput {
                    Stepper("Activate after \(Int(continuous.effectiveDistance)) pixels", value: Binding(
                        get: { continuous.effectiveDistance },
                        set: { mapping.continuousInput = ContinuousWheelInput(distance: $0) }
                    ), in: ContinuousWheelInput.distanceRange, step: 10)
                    .padding(.leading, 20)
                }
            }
            if let problem = WhiskerSettings.problem(with: mapping, allowPrimary: allowPrimary) {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private func modifierBinding(_ modifier: ModifierSet) -> Binding<Bool> {
        Binding(
            get: { mapping.modifiers.contains(modifier) },
            set: { on in
                var updated = mapping
                if on { updated.modifiers.insert(modifier) } else { updated.modifiers.remove(modifier) }
                mapping = updated
            }
        )
    }
}

// MARK: - Action editor

struct ActionEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var action: Action

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Picker("Action", selection: Binding(
                get: { action.kind },
                set: { kind in if kind != action.kind { action = kind.defaultAction } }
            )) {
                ForEach(ActionKind.allCases) { kind in
                    Label(kind.title, systemImage: kind.symbolName).tag(kind)
                }
            }
            details
        }
    }

    @ViewBuilder private var details: some View {
        switch action {
        case .passthrough:
            Text("The button does what it normally does.").font(.footnote).foregroundStyle(.secondary)
        case .none:
            Text("The button is ignored.").font(.footnote).foregroundStyle(.secondary)
        case let .click(button, modifiers):
            Picker("Button", selection: Binding(
                get: { button },
                set: { action = .click(button: $0, modifiers: modifiers) }
            )) {
                ForEach(0...7, id: \.self) { number in
                    Text(Trigger.buttonTitle(number)).tag(number)
                }
            }
            ModifierToggles(modifiers: Binding(
                get: { modifiers },
                set: { action = .click(button: button, modifiers: $0) }
            ))
        case .doubleClick(let modifiers):
            ModifierToggles(modifiers: Binding(
                get: { modifiers },
                set: { action = .doubleClick(modifiers: $0) }
            ))
        case .tripleClick(let modifiers):
            ModifierToggles(modifiers: Binding(
                get: { modifiers },
                set: { action = .tripleClick(modifiers: $0) }
            ))
            Text("Three left clicks in a row at the pointer. What an app does with them is up to the app.")
                .font(.footnote).foregroundStyle(.secondary)
        case let .shortcut(shortcut, repeats):
            ShortcutField(shortcut: Binding(
                get: { shortcut },
                set: { action = .shortcut($0, repeatWhileHeld: repeats) }
            ))
            Toggle("Repeat while held", isOn: Binding(
                get: { repeats },
                set: { action = .shortcut(shortcut, repeatWhileHeld: $0) }
            ))
        case .navigate(let direction):
            Picker("Direction", selection: Binding(get: { direction }, set: { action = .navigate($0) })) {
                ForEach(NavigationDirection.allCases, id: \.self) { Label($0.title, systemImage: $0.symbolName).tag($0) }
            }
            .pickerStyle(.segmented)
        case .media(let key):
            Picker("Key", selection: Binding(get: { key }, set: { action = .media($0) })) {
                ForEach(MediaKey.allCases, id: \.self) { Label($0.title, systemImage: $0.symbolName).tag($0) }
            }
        case .missionControl(let target):
            Picker("Show", selection: Binding(get: { target }, set: { action = .missionControl($0) })) {
                ForEach(MissionControlTarget.allCases, id: \.self) { Label($0.title, systemImage: $0.symbolName).tag($0) }
            }
            SystemShortcutNote(action: action)
        case .space(let direction):
            Picker("Direction", selection: Binding(get: { direction }, set: { action = .space($0) })) {
                ForEach(SpaceDirection.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            SystemShortcutNote(action: action)
        case .appSwitch(let direction):
            Picker("Switch to", selection: Binding(get: { direction }, set: { action = .appSwitch($0) })) {
                ForEach(AppSwitchDirection.allCases, id: \.self) { Text($0.title).tag($0) }
            }
        case let .scroll(direction, lines):
            Picker("Direction", selection: Binding(
                get: { direction },
                set: { action = .scroll(direction: $0, lines: lines) }
            )) {
                ForEach(WheelDirection.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            Stepper("\(lines) \(lines == 1 ? "line" : "lines")", value: Binding(
                get: { lines },
                set: { action = .scroll(direction: direction, lines: $0) }
            ), in: ScrollMath.linesRange)
        case let .holdToScroll(config):
            Picker("Scroll", selection: Binding(
                get: { config.axes },
                set: { var updated = config; updated.axes = $0; action = .holdToScroll(updated) }
            )) {
                ForEach(HoldScrollAxes.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Sensitivity")
                Slider(value: Binding(
                    get: { config.sensitivity },
                    set: { var updated = config; updated.sensitivity = $0; action = .holdToScroll(updated) }
                ), in: HoldScroll.sensitivityRange)
                Text(String(format: "%.1f×", config.sensitivity)).monospacedDigit().foregroundStyle(.secondary)
            }
            if config.axes != .horizontal {
                Toggle("Reverse vertical direction", isOn: Binding(
                    get: { config.invertVertical },
                    set: { var updated = config; updated.invertVertical = $0; action = .holdToScroll(updated) }
                ))
            }
            if config.axes != .vertical {
                Toggle("Reverse horizontal direction", isOn: Binding(
                    get: { config.invertHorizontal },
                    set: { var updated = config; updated.invertHorizontal = $0; action = .holdToScroll(updated) }
                ))
            }
            Text("Experimental. While the button is held, moving the ball scrolls and the pointer stays put; the page follows the ball. Keeping the pointer still has not yet been verified on hardware, and Whisker falls back to normal movement if it cannot. Only the mouse you pressed scrolls, which needs Input Monitoring.")
                .font(.footnote).foregroundStyle(.secondary)
            if !model.devices.canIdentifyDevices {
                Label("Input Monitoring is off, so Hold to Scroll cannot tell which mouse you pressed and the button keeps its normal behaviour.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            if let note = model.holdToScrollNote {
                Label(note, systemImage: "info.circle").font(.footnote).foregroundStyle(.secondary)
            }
        case .open(let url):
            OpenField(url: Binding(get: { url }, set: { action = .open(url: $0) }))
        }
    }
}

struct ModifierToggles: View {
    @Binding var modifiers: ModifierSet

    var body: some View {
        HStack {
            Text("Holding")
            ForEach(ModifierSet.ordered.filter { $0.modifier != .function }, id: \.name) { entry in
                Toggle(entry.symbol, isOn: Binding(
                    get: { modifiers.contains(entry.modifier) },
                    set: { on in
                        var updated = modifiers
                        if on { updated.insert(entry.modifier) } else { updated.remove(entry.modifier) }
                        modifiers = updated
                    }
                ))
                .toggleStyle(.button)
                .help(entry.title)
            }
        }
    }
}

/// Text entry for shortcuts like "cmd+shift+t"; keeps the last valid shortcut while typing.
struct ShortcutField: View {
    @Binding var shortcut: KeyShortcut
    @StateObject private var text = MessageState()

    var body: some View {
        let entry = text.text ?? shortcut.displayString
        VStack(alignment: .leading, spacing: 2) {
            TextField("Shortcut", text: Binding(
                get: { entry },
                set: { value in
                    text.text = value
                    if let parsed = KeyShortcut(parsing: value) { shortcut = parsed }
                }
            ), prompt: Text("e.g. cmd+shift+t"))
            .onSubmit { text.text = nil }
            if let typed = text.text, KeyShortcut(parsing: typed) == nil {
                Text("Type keys joined with +, like cmd+shift+t or ctrl+left.").font(.footnote).foregroundStyle(.orange)
            } else {
                Text("Sends \(shortcut.displayString)").font(.footnote).foregroundStyle(.secondary)
            }
        }
    }
}

struct OpenField: View {
    @Binding var url: String

    var body: some View {
        HStack {
            TextField("Open", text: $url, prompt: Text("https://example.com or choose an app"))
            Button("Choose…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.canChooseDirectories = true
                panel.allowsMultipleSelection = false
                panel.directoryURL = URL(fileURLWithPath: "/Applications")
                if panel.runModal() == .OK, let chosen = panel.url {
                    url = chosen.absoluteString
                }
            }
        }
    }
}

/// Warns when the system keyboard shortcut an action posts is turned off or has no key and there's no
/// app to open instead.
struct SystemShortcutNote: View {
    let action: Action

    var body: some View {
        if case .unavailable(let id) = action.systemShortcutPlan(SystemShortcutReader()) {
            VStack(alignment: .leading, spacing: 4) {
                Label("“\(id.title)” is turned off in Keyboard Shortcuts, so this action won’t do anything until you turn it on.",
                      systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
                Button("Open Keyboard Shortcuts") {
                    if let url = URL(string: "x-apple.systempreferences:com.apple.Keyboard-Settings.extension") {
                        NSWorkspace.shared.open(url)
                    }
                }
                .controlSize(.small)
            }
        }
    }
}
