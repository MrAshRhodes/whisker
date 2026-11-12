import AppKit
import SwiftUI
import WhiskerCore

/// Listens for one prompt's worth of input and hands it over for classification. Observational only: it uses
/// a local monitor in Whisker's own window, never the event tap, and it consumes the events it sees.
@MainActor
final class TiltObserver: ObservableObject {
    /// How long after the last event the input counts as finished, so one tilt that sends several reports
    /// is read as one.
    static let settleDelay: TimeInterval = 0.7

    @Published private(set) var isListening = false
    private var monitor: Any?
    private var settle: Task<Void, Never>?
    private var observations: [ControlObservation] = []
    private weak var model: AppModel?

    func start(model: AppModel, onFinish: @escaping ([ControlObservation]) -> Void) {
        stop()
        self.model = model
        model.capturing = true
        isListening = true
        observations = []
        let mask: NSEvent.EventTypeMask = [.leftMouseDown, .rightMouseDown, .otherMouseDown, .scrollWheel, .keyDown]
        monitor = NSEvent.addLocalMonitorForEvents(matching: mask) { [weak self] event in
            guard let self else { return event }
            if event.type == .keyDown {
                if event.keyCode == 0x35 { self.stop() }
                return nil
            }
            if let observation = Self.observation(for: event) { self.observations.append(observation) }
            self.settle?.cancel()
            self.settle = Task { [weak self] in
                try? await Task.sleep(nanoseconds: UInt64(Self.settleDelay * 1_000_000_000))
                guard !Task.isCancelled, let self else { return }
                let finished = self.observations
                self.stop()
                onFinish(finished)
            }
            return nil
        }
    }

    func stop() {
        settle?.cancel()
        settle = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        if isListening { model?.capturing = false }
        isListening = false
    }

    static func observation(for event: NSEvent) -> ControlObservation? {
        switch event.type {
        case .leftMouseDown: return .buttonDown(0)
        case .rightMouseDown: return .buttonDown(1)
        case .otherMouseDown: return .buttonDown(event.buttonNumber)
        case .scrollWheel: return event.cgEvent.map { .scroll(EventEngine.readSample($0)) }
        default: return nil
        }
    }
}

@MainActor
final class TiltSheetState: ObservableObject {
    @Published var isPresented = false
}

struct TiltStepResult {
    var candidate: ControlCandidate
    var attribution: TiltDeviceAttribution
    var confirmed = false
    var label: String
}

@MainActor
final class TiltFlowState: ObservableObject {
    @Published var results: [TiltStep: TiltStepResult] = [:]
    @Published var current: TiltStep?
    @Published var message: String?
    @Published var useDeviceProfile = true
    let observer = TiltObserver()

    func record(_ step: TiltStep, model: AppModel) {
        message = nil
        current = step
        observer.start(model: model) { [weak self, weak model] observations in
            guard let self, let model else { return }
            self.current = nil
            let attribution = TiltDeviceAttribution.resolve(model.devices.connectedDetails)
            self.results[step] = TiltStepResult(
                candidate: TiltClassifier.classify(observations), attribution: attribution, label: step.suggestedLabel
            )
        }
    }

    func cancel() {
        observer.stop()
        current = nil
    }

    var confirmedSteps: [TiltStep] {
        TiltStep.allCases.filter { results[$0]?.confirmed == true && results[$0]?.candidate.trigger != nil }
    }

    var candidates: [TiltStep: ControlCandidate] { results.mapValues(\.candidate) }

    /// A device-specific profile is only offered when every confirmed control came from one exactly attributed device.
    var exactDevice: (id: String, name: String)? {
        var found: (String, String)?
        for step in confirmedSteps {
            guard case let .exact(id, name) = results[step]?.attribution else { return nil }
            if let found, found.0 != id { return nil }
            found = (id, name)
        }
        return found
    }
}

struct TiltIdentifySheet: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    let profileID: String
    let onDone: (String?) -> Void
    @StateObject private var flow = TiltFlowState()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text("Identify tilt-wheel controls").font(.title3.bold())
            Text("Whisker can only see what macOS reports. A tilt may arrive as a numbered button or as horizontal scrolling, and Whisker doesn't assume which. Nothing is saved until you confirm it.")
                .font(.callout).foregroundStyle(.secondary)
            Text("Not yet verified on hardware: no tilt-wheel mouse has been tested with this flow.")
                .font(.footnote).foregroundStyle(.secondary)
            Divider()
            ForEach(TiltStep.allCases, id: \.self) { step in stepRow(step) }
            Divider()
            deviceSection
            if let message = flow.message { Text(message).font(.footnote).foregroundStyle(.orange) }
            HStack {
                Button("Cancel") { flow.cancel(); onDone(nil) }.keyboardShortcut(.cancelAction)
                Spacer()
                Button("Save Confirmed") { save() }
                    .disabled(flow.confirmedSteps.isEmpty || flow.current != nil)
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 520)
        .onDisappear { flow.cancel() }
    }

    @ViewBuilder
    private func stepRow(_ step: TiltStep) -> some View {
        let result = flow.results[step]
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text(step.prompt).font(.headline)
                Spacer()
                if flow.current == step {
                    ProgressView().controlSize(.small)
                    Button("Stop") { flow.cancel() }
                } else {
                    Button(result == nil ? "Record" : "Try Again") { flow.record(step, model: model) }
                        .disabled(flow.current != nil)
                }
            }
            if flow.current == step {
                Text("Listening… do it now. Esc cancels.").font(.footnote).foregroundStyle(.secondary)
            }
            if let result {
                if let trigger = result.candidate.trigger {
                    Label("Preview: \(trigger.title)", systemImage: trigger.symbolName).font(.subheadline.bold())
                }
                Text(result.candidate.explanation).font(.footnote).foregroundStyle(.secondary)
                if let duplicate = TiltReview.duplicateProblem(flow.candidates, for: step) {
                    Text(duplicate).font(.footnote).foregroundStyle(.orange)
                } else if result.candidate.trigger != nil {
                    Toggle("Save this as a mapping", isOn: confirmBinding(step))
                    if result.confirmed, result.attribution.allowsLabels {
                        TextField("Label", text: labelBinding(step))
                            .textFieldStyle(.roundedBorder)
                    }
                }
            }
        }
    }

    private var deviceSection: some View {
        let latest = TiltStep.allCases.compactMap { flow.results[$0]?.attribution }.last
            ?? TiltDeviceAttribution.resolve(model.devices.connectedDetails)
        return VStack(alignment: .leading, spacing: 4) {
            Text("Selected device").font(.subheadline.bold())
            Text(latest.summary).font(.footnote).foregroundStyle(.secondary)
            if let device = flow.exactDevice {
                Toggle("Save in a profile just for \(device.name)", isOn: $flow.useDeviceProfile)
            } else if !flow.confirmedSteps.isEmpty {
                Text("Mappings go into the profile you have selected, without hardware labels.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    private func confirmBinding(_ step: TiltStep) -> Binding<Bool> {
        Binding(get: { flow.results[step]?.confirmed ?? false }, set: { flow.results[step]?.confirmed = $0 })
    }

    private func labelBinding(_ step: TiltStep) -> Binding<String> {
        Binding(get: { flow.results[step]?.label ?? "" }, set: { flow.results[step]?.label = $0 })
    }

    private func save() {
        var settings = store.settings
        let allowPrimary = settings.general.allowPrimaryButtonRemap
        var targetID = profileID
        if let device = flow.exactDevice, flow.useDeviceProfile {
            let existing = settings.profiles.first { $0.match.devices == [device.id] && $0.match.apps == [ProfileMatch.any] }
            if let existing {
                targetID = existing.id
            } else {
                let created = Profile(name: device.name, match: ProfileMatch(devices: [device.id]))
                settings.upsert(created)
                targetID = created.id
            }
        }
        guard var profile = settings.profile(id: targetID) else { return }
        var skipped: [String] = []
        for step in flow.confirmedSteps {
            guard let result = flow.results[step], let trigger = result.candidate.trigger else { continue }
            if result.attribution.allowsLabels, let id = result.attribution.deviceID {
                var device = settings.devices[id] ?? DeviceSettings()
                if device.name.isEmpty, case let .exact(_, name) = result.attribution { device.name = name }
                device.setControlLabel(result.label, for: trigger)
                settings.devices[id] = device
            }
            let mapping = Mapping(trigger: trigger, modifiers: [], action: .passthrough)
            if profile.mapping(for: mapping.key) != nil {
                skipped.append("\(trigger.title) already has a mapping in this profile")
            } else if let problem = WhiskerSettings.problem(with: mapping, allowPrimary: allowPrimary) {
                skipped.append(problem)
            } else {
                profile.mappings.append(mapping)
            }
        }
        settings.upsert(profile)
        store.settings = settings
        model.selectedProfileID = targetID
        onDone(skipped.isEmpty ? nil : "Saved, except: " + skipped.joined(separator: "; ") + ".")
    }
}
