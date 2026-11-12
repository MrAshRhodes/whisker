import AppKit
import SwiftUI
import WhiskerCore

/// Records a two-button chord: the first button pressed and a second one pressed while it is still down. Event
/// handling is paused meanwhile (`AppModel.capturing`), so neither press is held back or remapped.
@MainActor
final class ChordRecorder: ObservableObject {
    @Published private(set) var isRecording = false
    private var monitor: Any?
    private weak var model: AppModel?
    private var first: Int?
    private var down: Set<Int> = []

    func start(model: AppModel, onCapture: @escaping (Int, Int, ModifierSet) -> Void) {
        stop()
        self.model = model
        model.capturing = true
        isRecording = true
        let mask: NSEvent.EventTypeMask = [
            .leftMouseDown, .rightMouseDown, .otherMouseDown, .leftMouseUp, .rightMouseUp, .otherMouseUp, .keyDown,
        ]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            switch event.type {
            case .keyDown:
                if event.keyCode == 0x35 { self.stop() }
            case .leftMouseDown, .rightMouseDown, .otherMouseDown:
                let button = event.buttonNumber
                if let first = self.first, first != button, self.down.contains(first) {
                    let modifiers = ModifierSet(eventFlags: UInt64(event.modifierFlags.rawValue)).withoutFunction
                    self.stop()
                    onCapture(first, button, modifiers)
                    return nil
                }
                if self.down.isEmpty { self.first = button }
                self.down.insert(button)
            default:
                self.down.remove(event.buttonNumber)
                if self.down.isEmpty { self.first = nil }
            }
            return nil
        }
    }

    func stop() {
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        first = nil
        down = []
        if isRecording { model?.capturing = false }
        isRecording = false
    }
}

/// The two-button chords of one profile, and whether any connected mouse can form them right now.
struct ChordSection: View {
    @EnvironmentObject private var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var devices: DeviceMonitor
    @Binding var profile: Profile
    /// What the profile uses, its own list or an inherited one.
    let resolved: [ButtonChord]
    @StateObject private var recorder = ChordRecorder()
    @StateObject private var messages = MessageState()

    private var allowPrimary: Bool { store.settings.general.allowPrimaryButtonRemap }

    private var eligibleNames: [String] {
        devices.devices.filter { devices.chordEligibility[$0.id] == .eligible }.map(\.name)
    }

    /// New chords are only offered when one could work now; saved ones can always be changed or removed.
    private var canAdd: Bool { devices.identification == .listening && !eligibleNames.isEmpty }

    var body: some View {
        Section {
            status
            if let own = profile.chords {
                ForEach(own.indices, id: \.self) { index in
                    ChordRow(chord: chordBinding(index), settings: store.settings, allowPrimary: allowPrimary) {
                        profile.chords?.remove(at: index)
                    }
                }
                if own.isEmpty, !profile.isDefault {
                    Text("Chords are off in this profile.").foregroundStyle(.secondary)
                }
            } else if !resolved.isEmpty {
                ForEach(resolved.indices, id: \.self) { index in
                    Text("\(resolved[index].summary) — inherited").foregroundStyle(.secondary)
                }
                HStack {
                    Button("Edit Here") { profile.chords = resolved }
                    Button("Turn Off Here") { profile.chords = [] }
                }
            }
            if let own = profile.chords, !own.isEmpty, let problem = ButtonChord.problem(in: own, allowPrimary: allowPrimary) {
                Label("\(problem) Chords in this profile stay off until this is fixed.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            HStack {
                if recorder.isRecording {
                    ProgressView().controlSize(.small)
                    Text("Press one mouse button, then a second while holding the first… (Esc to cancel)")
                    Spacer()
                    Button("Cancel") { recorder.stop() }
                } else {
                    Button("Record Two-button Chord…") {
                        messages.text = nil
                        recorder.start(model: model) { first, second, modifiers in
                            add(ButtonChord(first: first, second: second, modifiers: modifiers,
                                            action: .click(button: 2, modifiers: [])))
                        }
                    }
                    .disabled(!canAdd)
                    Button(allowPrimary ? "Add Primary + Secondary → Middle Click" : "Add ⌥ Primary + Secondary → Middle Click") {
                        add(.middleClick(modifiers: allowPrimary ? [] : .option))
                    }
                    .disabled(!canAdd)
                    .help(allowPrimary ? "Press both main buttons together for a middle click."
                        : "Hold Option and press both main buttons together for a middle click. Without Option, the primary button is only used in chords when Allow remapping the primary button is on in General.")
                    Spacer()
                }
            }
            if let message = messages.text {
                Text(message).font(.footnote).foregroundStyle(.orange)
            }
        } header: {
            Text("Two-button Chords")
        } footer: {
            Text("Press two buttons of the same mouse together to run an action. While a chord is set, a single press of either of its buttons on a mouse that can form chords waits up to the chord’s press window (75 ms unless changed, 20–200 ms) for the other one, then goes through as usual. Other buttons, other mice and moving the mouse while a button is down are never held back. Not yet verified on hardware.")
                .font(.footnote).foregroundStyle(.secondary)
        }
        .onDisappear { recorder.stop() }
    }

    @ViewBuilder private var status: some View {
        Text(ButtonChordAvailability.explanation).foregroundStyle(.secondary)
        switch devices.identification {
        case .notAllowed:
            HStack {
                Text("Input Monitoring isn’t allowed, so every press passes through unchanged.")
                Button("Allow Input Monitoring…") { devices.requestIdentification() }
            }
            .font(.footnote)
        case .couldNotListen:
            HStack {
                Text("Whisker couldn’t start listening to your mice, so every press passes through unchanged.")
                Button("Try Again") { devices.requestIdentification() }
            }
            .font(.footnote)
        case .listening:
            if eligibleNames.isEmpty {
                Text("No connected mouse can form chords right now.").font(.footnote)
                ForEach(devices.devices.filter { devices.chordEligibility[$0.id] != nil }, id: \.id) { device in
                    Text("\(device.name): \(devices.chordEligibility[device.id]?.explanation ?? "")")
                        .font(.footnote).foregroundStyle(.secondary)
                }
            } else {
                Text("Ready on \(eligibleNames.formatted(.list(type: .and))).").font(.footnote)
            }
        }
    }

    private func chordBinding(_ index: Int) -> Binding<ButtonChord> {
        Binding(
            get: {
                let chords = profile.chords ?? []
                return chords.indices.contains(index) ? chords[index] : .middleClick()
            },
            set: { value in
                guard var chords = profile.chords, chords.indices.contains(index) else { return }
                chords[index] = value
                profile.chords = chords
            }
        )
    }

    private func add(_ chord: ButtonChord) {
        var chords = profile.chords ?? resolved
        chords.append(chord)
        if let problem = ButtonChord.problem(in: chords, allowPrimary: allowPrimary) {
            messages.text = problem
            return
        }
        messages.text = nil
        profile.chords = chords
    }
}

struct ChordRow: View {
    @Binding var chord: ButtonChord
    let settings: WhiskerSettings
    let allowPrimary: Bool
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Label(title, systemImage: "hand.tap").font(.headline)
                Spacer()
                Button(role: .destructive, action: onDelete) {
                    Image(systemName: "trash")
                }
                .buttonStyle(.borderless)
                .help("Remove this chord")
            }
            HStack {
                buttonPicker("First", \.first)
                buttonPicker("Second", \.second)
            }
            ModifierToggles(modifiers: $chord.modifiers)
            ActionEditor(action: $chord.action, settings: settings, inChord: true)
            Stepper("Press window: \(chord.pressWindow) ms", value: $chord.pressWindow, in: ButtonChord.windowRange, step: 5)
            Text(ButtonChordAvailability.latency(chord)).font(.footnote).foregroundStyle(.secondary)
            if let problem = chord.problem(allowPrimary: allowPrimary) {
                Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
            }
        }
        .padding(.vertical, 2)
    }

    private var title: String {
        let keys = chord.modifiers.withoutFunction
        return keys.isEmpty ? "\(Trigger.buttonTitle(chord.first)) + \(Trigger.buttonTitle(chord.second))"
            : "\(keys.symbols) \(Trigger.buttonTitle(chord.first)) + \(Trigger.buttonTitle(chord.second))"
    }

    private func buttonPicker(_ label: String, _ path: WritableKeyPath<ButtonChord, Int>) -> some View {
        Picker(label, selection: Binding(get: { chord[keyPath: path] }, set: { chord[keyPath: path] = $0 })) {
            ForEach(0...7, id: \.self) { number in
                Text(Trigger.buttonTitle(number)).tag(number)
            }
        }
    }
}
