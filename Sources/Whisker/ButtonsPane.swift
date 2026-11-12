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
                  case .notch(let direction) = EventEngine.readSample(cgEvent).classification else { return nil }
            return .wheel(direction)
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
    @StateObject private var tilt = TiltSheetState()

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
                        settings: store.settings,
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
                        Button("Identify tilt-wheel controls…") { messages.text = nil; tilt.isPresented = true }
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
            if let deviceID = Self.mouseID(of: profile.wrappedValue) {
                Section("Primary and Secondary Buttons") {
                    ButtonSwapControls(
                        store: store, devices: model.devices, id: deviceID,
                        name: store.settings.devices[deviceID]?.name ?? profile.wrappedValue.name
                    )
                }
            }
            ChordSection(store: store, devices: model.devices, profile: profile, resolved: resolved.chords)
            if !inherited.isEmpty {
                Section("Inherited") {
                    ForEach(inherited, id: \.mapping.key) { item in
                        HStack {
                            TriggerLabel(mapping: item.mapping)
                            Spacer()
                            Label(
                                item.mapping.gestures == nil ? store.settings.summary(of: item.mapping.action) : item.mapping.summary,
                                systemImage: item.mapping.symbolName
                            )
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
        .sheet(isPresented: $tilt.isPresented) {
            TiltIdentifySheet(store: store, profileID: profileID) { note in
                tilt.isPresented = false
                messages.text = note
            }
            .environmentObject(model)
        }
        .onDisappear { recorder.stop() }
    }

    /// The mouse a profile is for, when it is for one particular mouse in every app: the swap belongs to a mouse, not to a profile.
    private static func mouseID(of profile: Profile) -> String? {
        guard !profile.isDefault, profile.match.apps == [ProfileMatch.any],
              profile.match.devices.count == 1, let id = profile.match.devices.first, id != ProfileMatch.any else { return nil }
        return id
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
    let settings: WhiskerSettings
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
            if case .button = mapping.trigger {
                Toggle("Gestures", isOn: Binding(
                    get: { mapping.gestures != nil },
                    set: { on in
                        guard on != (mapping.gestures != nil) else { return }
                        var updated = mapping
                        updated.gestures = on ? ButtonGestures() : nil
                        // The button's own action isn't used while it has gestures; older versions of Whisker leave it alone.
                        if on { updated.action = .passthrough }
                        mapping = updated
                    }
                ))
                .help("Hold the button, move the mouse up, down, left or right and let go to run an action for each direction; letting go without moving can run one too. Not yet verified on hardware.")
            }
            if mapping.gestures != nil {
                GestureEditor(gestures: Binding(
                    get: { mapping.gestures ?? ButtonGestures() },
                    set: { mapping.gestures = $0 }
                ), settings: settings)
            } else {
                ActionEditor(action: $mapping.action, settings: settings, trigger: mapping.trigger)
            }
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
    let settings: WhiskerSettings
    var trigger: Trigger? = nil
    /// Gesture actions: only actions a gesture can run are offered, and none of them repeats while held.
    var inGesture = false
    /// Chord actions: a click, or anything a gesture can run.
    var inChord = false
    /// A gesture slot picks its kind itself (it can also be left empty), so it asks for the details alone.
    var showsKindPicker = true

    /// Pointer speed presets are offered once there is a preset to switch to, and Click Lock once it is switched on
    /// in General. A mapping that already has either keeps showing it.
    private var kinds: [ActionKind] {
        ActionKind.allCases.filter { kind in
            guard !inGesture || kind.defaultAction.allowedInGestures else { return false }
            guard !inChord || kind.defaultAction.allowedInChords else { return false }
            if let trigger, case .wheel = trigger, kind == .holdToScroll { return false }
            switch kind {
            case .pointerPreset: return action.kind == .pointerPreset || settings.firstPointerPreset() != nil
            case .clickLock: return action.kind == .clickLock || settings.general.experimentalClickLock
            default: return true
            }
        }
    }

    private func newAction(for kind: ActionKind) -> Action {
        if kind == .pointerPreset, let first = settings.firstPointerPreset() {
            return .pointerPreset(deviceID: first.deviceID, presetID: first.presetID)
        }
        return kind.defaultAction
    }
    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            if showsKindPicker {
                Picker("Action", selection: Binding(
                    get: { action.kind },
                    set: { kind in if kind != action.kind { action = newAction(for: kind) } }
                )) {
                    ForEach(kinds) { kind in
                        Label(kind.title, systemImage: kind.symbolName).tag(kind)
                    }
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
        case .clickLock:
            Text("Experimental. Press once to hold the primary button down, so moving the pointer drags. Press again, or press the primary button, to let go. Not yet verified on hardware; if the button ever seems stuck, press and release the primary button yourself.")
                .font(.footnote).foregroundStyle(.secondary)
            if !settings.general.experimentalClickLock {
                Label("Turned off in General, so this does nothing for now.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
        case let .shortcut(shortcut, repeats):
            ShortcutField(shortcut: Binding(
                get: { shortcut },
                set: { action = .shortcut($0, repeatWhileHeld: repeats) }
            ))
            if !inGesture && !inChord {
                Toggle("Repeat while held", isOn: Binding(
                    get: { repeats },
                    set: { action = .shortcut(shortcut, repeatWhileHeld: $0) }
                ))
            }
        case .shortcutSequence(let steps):
            SequenceEditor(steps: Binding(get: { steps }, set: { action = .shortcutSequence($0) }))
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
        case let .pointerPreset(deviceID, presetID):
            PointerPresetPicker(action: $action, settings: settings, deviceID: deviceID, presetID: presetID)
        case .slowPointer(let factor):
            HStack {
                Text("Speed factor")
                Slider(value: Binding(get: { factor }, set: { action = .slowPointer(factor: $0) }), in: SlowPointer.factorRange, step: 0.1)
                    .accessibilityLabel("Held pointer speed factor")
                Text(String(format: "%.1f×", factor)).monospacedDigit()
            }
            Text("Slows only the mouse you press, while held. Needs Input Monitoring, a supported mouse and an enabled custom pointer baseline. Otherwise the button keeps its normal behaviour. Overlapping holds use the slowest factor, not their product. Cancel from Pointer settings. This changes macOS pointer response, not sensor DPI; hardware and game compatibility are not yet verified.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !model.devices.canIdentifyDevices {
                Label("Input Monitoring is off; Whisker cannot safely identify the held mouse.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
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
            if config.axes == .automatic {
                Text("Each hold picks vertical or horizontal from its first movement and keeps it until you let go; a diagonal counts as vertical. The threshold is provisional and not yet verified on hardware, including thumb and finger trackballs.")
                    .font(.footnote).foregroundStyle(.secondary)
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
        case let .autoScroll(config):
            Picker("Scroll", selection: Binding(
                get: { config.axes },
                set: { var updated = config; updated.axes = $0; action = .autoScroll(updated) }
            )) {
                ForEach(AutoScrollAxes.allCases, id: \.self) { Text($0.title).tag($0) }
            }
            .pickerStyle(.segmented)
            HStack {
                Text("Dead zone")
                Slider(value: Binding(
                    get: { config.deadZone },
                    set: { var updated = config; updated.deadZone = $0; action = .autoScroll(updated) }
                ), in: AutoScroll.deadZoneRange)
                Text(String(format: "%.0f pt", config.deadZone)).monospacedDigit().foregroundStyle(.secondary)
            }
            HStack {
                Text("Top speed")
                Slider(value: Binding(
                    get: { config.maxSpeed },
                    set: { var updated = config; updated.maxSpeed = $0; action = .autoScroll(updated) }
                ), in: AutoScroll.maxSpeedRange)
                Text(String(format: "%.0f px/s", config.maxSpeed)).monospacedDigit().foregroundStyle(.secondary)
            }
            Text("Experimental. Press the button to anchor the pointer, then move it away from that spot: the further it goes, the faster the window under it scrolls, and inside the dead zone nothing moves. Press the button again, click, or scroll to stop; a change of app or profile, of connected mice, or going to sleep stops it too. There is no marker at the pointer, but the menu bar icon shows while it runs. The speeds are provisional, and TextEdit, nested scrolling in Safari, several displays, mixed pointing devices and which pane receives the scrolling have not yet been verified on hardware.")
                .font(.footnote).foregroundStyle(.secondary)
        case .open(let url):
            OpenField(url: Binding(get: { url }, set: { action = .open(url: $0) }))
        }
    }
}

/// Picks the mouse and the saved speed a button switches to.
struct PointerPresetPicker: View {
    @Binding var action: Action
    let settings: WhiskerSettings
    let deviceID: String
    let presetID: String

    private struct MouseChoice: Identifiable {
        let id: String
        let name: String
    }

    /// Mice with presets, and the one this mapping points at even when it has none left. Mice that share a
    /// name are told apart by their id.
    private var choices: [MouseChoice] {
        let listed = settings.devices
            .filter { !$0.value.pointerPresets.isEmpty || $0.key == deviceID }
            .sorted { ($0.value.name, $0.key) < ($1.value.name, $1.key) }
        let names = listed.map { $0.value.name.isEmpty ? $0.key : $0.value.name }
        return zip(listed, names).map { entry, name in
            MouseChoice(id: entry.key, name: names.filter { $0 == name }.count > 1 ? "\(name) (\(entry.key))" : name)
        }
    }

    var body: some View {
        let device = settings.devices[deviceID]
        let preset = device?.pointerPreset(id: presetID)
        Picker("Mouse", selection: Binding(
            get: { deviceID },
            set: { id in action = .pointerPreset(deviceID: id, presetID: settings.devices[id]?.pointerPresets.first?.id ?? "") }
        )) {
            ForEach(choices) { Text($0.name).tag($0.id) }
            if device == nil { Text("Unknown mouse").tag(deviceID) }
        }
        Picker("Preset", selection: Binding(
            get: { presetID },
            set: { action = .pointerPreset(deviceID: deviceID, presetID: $0) }
        )) {
            ForEach(device?.pointerPresets ?? []) { Text($0.label).tag($0.id) }
            if preset == nil { Text("No preset").tag(presetID) }
        }
        if preset == nil {
            Label("That preset no longer exists. Choose another, or remove this mapping.", systemImage: "exclamationmark.triangle")
                .font(.footnote).foregroundStyle(.orange)
        } else {
            Text("Switches this mouse to the preset’s speed. A big increase has to be kept within a few seconds, or it goes back.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
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

/// An ordered list of shortcuts, each with the wait before the next. The limits are the ones settings files are held to.
final class RowIdentities: ObservableObject {
    var ids: [UUID] = []
}

struct SequenceEditor: View {
    @Binding var steps: [SequenceStep]
    /// Gives each row a stable identity so moving or removing a row doesn't leave another's half-typed text behind.
    @StateObject private var identities = RowIdentities()

    private var limits: ShortcutSequenceLimits.Type { ShortcutSequenceLimits.self }

    var body: some View {
        syncRowIDs()
        return VStack(alignment: .leading, spacing: 6) {
            ForEach(Array(steps.indices), id: \.self) { index in
                row(index)
                    .id(identities.ids[index])
            }
            HStack {
                Button {
                    steps.append(SequenceStep(shortcut: steps.last?.shortcut ?? KeyShortcut(keyCode: 0x08, modifiers: .command)))
                } label: {
                    Label("Add Shortcut", systemImage: "plus")
                }
                .disabled(steps.count >= limits.stepCount.upperBound)
                Text("\(steps.count) of \(limits.stepCount.lowerBound)–\(limits.stepCount.upperBound) shortcuts, \(String(format: "%g", Double(limits.totalDelayMs(of: steps)) / 1000)) of \(limits.totalDelayMs / 1000) s waiting")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if let problem = limits.problem(with: steps) {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
            Text("Runs once per press, not while held. Using the same button again, switching app or turning Whisker off stops it. Delays can't make an app ready in time.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }

    private func syncRowIDs() {
        if identities.ids.count > steps.count { identities.ids.removeLast(identities.ids.count - steps.count) }
        while identities.ids.count < steps.count { identities.ids.append(UUID()) }
    }

    @ViewBuilder private func row(_ index: Int) -> some View {
        HStack(alignment: .top) {
            Text("\(index + 1).").monospacedDigit().frame(width: 24, alignment: .trailing)
            ShortcutField(shortcut: Binding(
                get: { index < steps.count ? steps[index].shortcut : KeyShortcut(keyCode: 0) },
                set: { if index < steps.count { steps[index].shortcut = $0 } }
            ))
            if index < steps.count - 1 {
                Stepper("then wait \(steps[index].delayAfterMs) ms", value: Binding(
                    get: { index < steps.count ? steps[index].delayAfterMs : 0 },
                    set: { if index < steps.count { steps[index].delayAfterMs = min(max($0, limits.delayMs.lowerBound), limits.delayMs.upperBound) } }
                ), in: limits.delayMs, step: 50)
                .fixedSize()
            }
            Button { move(index, by: -1) } label: { Image(systemName: "arrow.up") }
                .disabled(index == 0).help("Move up")
            Button { move(index, by: 1) } label: { Image(systemName: "arrow.down") }
                .disabled(index >= steps.count - 1).help("Move down")
            Button(role: .destructive) { remove(index) } label: { Image(systemName: "minus.circle") }
                .disabled(steps.count <= limits.stepCount.lowerBound).help("Remove this shortcut")
        }
        .buttonStyle(.borderless)
    }

    private func move(_ index: Int, by offset: Int) {
        let target = index + offset
        guard steps.indices.contains(index), steps.indices.contains(target) else { return }
        steps.swapAt(index, target)
        if identities.ids.count == steps.count { identities.ids.swapAt(index, target) }
    }

    private func remove(_ index: Int) {
        guard steps.indices.contains(index), steps.count > limits.stepCount.lowerBound else { return }
        steps.remove(at: index)
        if identities.ids.indices.contains(index) { identities.ids.remove(at: index) }
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
