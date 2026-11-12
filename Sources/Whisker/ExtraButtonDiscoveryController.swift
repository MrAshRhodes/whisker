import Foundation
import WhiskerCore

struct ExtraButtonInterfaceResult: Identifiable {
    var id: Int
    var label: String
    var collections: [String]
    var controls: [ExtraButtonControl]
}

/// Main-thread, explicitly started diagnostics. No actions, report requests or event-tap integration.
final class ExtraButtonDiscoveryController: ObservableObject {
    @Published private(set) var interfaces: [ExtraButtonInterfaceResult] = []
    @Published private(set) var message = "Off. Enable discovery, then choose Inspect."
    @Published private(set) var keyboardInterfaces = 0
    @Published private(set) var isInspecting = false
    private let access: HIDDeviceAccess
    private let source: ExtraButtonSource
    private let permission: () -> Bool
    private let settings: () -> WhiskerSettings
    private let schedule: BatteryProvider.Scheduler
    private var deviceID: String?
    private var interfaceIDs: [Int] = []
    private var metadata: Set<HIDInterfaceInfo> = []
    private var observedIDs: Set<Int> = []
    private var recorders: [Int: ExtraButtonRecorder] = [:]
    private var pending: [Int: [Int: Int]] = [:]
    private var cancelTick: (() -> Void)?
    private var generation = 0

    init(access: HIDDeviceAccess, source: ExtraButtonSource, permission: @escaping () -> Bool,
         settings: @escaping () -> WhiskerSettings,
         schedule: @escaping BatteryProvider.Scheduler = InputTimingController.mainRunLoopSchedule) {
        self.access = access
        self.source = source
        self.permission = permission
        self.settings = settings
        self.schedule = schedule
    }

    func start(deviceID: String) {
        stop()
        let current = settings()
        guard current.general.enabled, current.devices[deviceID]?.enabled != false,
              current.devices[deviceID]?.extraButtons.discoveryEnabled == true else {
            message = "Discovery is off, or this mouse is disabled. Ordinary mappings are unchanged."
            return
        }
        guard permission() else {
            message = "Input Monitoring is required even with one mouse. Ordinary mappings are unchanged."
            return
        }
        guard let device = source.devices.first(where: { $0.id == deviceID }), !device.isExcluded else {
            message = "This mouse is disconnected or left alone."
            return
        }
        let sources = source.pointingInterfaces(ofDevice: deviceID)
        guard !sources.isEmpty, sources.count <= 8 else {
            message = "Unavailable — no bounded, attributable pointing interfaces."
            return
        }
        let metadata = source.discoveryMetadata(ofDevice: deviceID)
        let proven = sources.count == 1 && ExtraButtonDiscovery.associationProven(device: device, metadata: metadata)
        keyboardInterfaces = metadata.filter(\.isKeyboard).count
        self.deviceID = deviceID
        interfaceIDs = sources.map(\.runtimeID)
        self.metadata = Set(metadata)
        let token = generation
        for (ordinal, source) in sources.enumerated() {
            guard let elements = access.elements(of: source.runtimeID),
                  elements.count <= ExtraButtonDiscovery.maximumElements else {
                stop(reason: "Unavailable — descriptor missing or exceeds the safe inspection limit.")
                return
            }
            let controls = ExtraButtonDiscovery.controls(elements: elements.map(\.discoveryElement), associationProven: proven)
            let collections = Set(elements.filter { $0.kind == .collection }.map {
                String(format: "Page 0x%02X · usage 0x%02X", $0.usagePage, $0.usage)
            }).sorted()
            interfaces.append(ExtraButtonInterfaceResult(
                id: source.runtimeID, label: "Interface \(source.interfaceNumber ?? ordinal + 1)",
                collections: collections, controls: controls
            ))
            let allowed = controls.filter { $0.status == .awaiting }.map(\.id)
            guard !allowed.isEmpty else { continue }
            recorders[source.runtimeID] = ExtraButtonRecorder(runtimeID: source.runtimeID, allowed: Set(allowed))
            guard access.observeExtraButtonValues(of: source.runtimeID, indexes: allowed, onValue: { [weak self] value in
                guard let self, self.generation == token, self.environmentValid() else { return }
                if self.recorders[value.runtimeID]?.accept(value) == true {
                    self.pending[value.runtimeID, default: [:]][value.elementIndex] = value.value
                }
            }, onEnd: { [weak self] in
                guard let self, self.generation == token else { return }
                self.stop(reason: "Observation ended or its queue could not keep up. Inspect again to start fresh.")
            }) else {
                stop(reason: "Unavailable — macOS could not open a filtered, non-exclusive observation.")
                return
            }
            observedIDs.insert(source.runtimeID)
        }
        isInspecting = true
        message = proven
            ? "Diagnostic only. Safe binary Button/Consumer values may be observed; native effects still happen. No remapping."
            : "Ambiguous association — metadata only. USB/receivers, missing identities and shared devices cannot be attributed safely."
        armTick()
    }

    /// Also used for settings/profile changes, sleep, closing the sheet and app shutdown. Never resumes itself.
    func stop(reason: String = "Stopped. Observations cleared; Inspect starts a new session.") {
        generation += 1
        cancelTick?()
        cancelTick = nil
        for id in observedIDs { access.stopObservingExtraButtonValues(of: id) }
        observedIDs.removeAll()
        recorders.removeAll()
        pending.removeAll()
        deviceID = nil
        interfaceIDs = []
        metadata = []
        interfaces = []
        keyboardInterfaces = 0
        isInspecting = false
        message = reason
    }

    func environmentChanged() {
        guard deviceID != nil else { return }
        _ = environmentValid()
    }

    private func environmentValid() -> Bool {
        guard let deviceID else { return false }
        guard permission() else {
            stop(reason: "Input Monitoring was lost. Observations cleared; ordinary mappings are unchanged.")
            return false
        }
        let current = settings()
        guard current.general.enabled, current.devices[deviceID]?.enabled != false,
              current.devices[deviceID]?.extraButtons.discoveryEnabled == true,
              let device = source.devices.first(where: { $0.id == deviceID }), !device.isExcluded,
              source.pointingInterfaces(ofDevice: deviceID).map(\.runtimeID) == interfaceIDs,
              Set(source.discoveryMetadata(ofDevice: deviceID)) == metadata else {
            stop(reason: "Device or settings changed. Observations cleared; Inspect starts fresh.")
            return false
        }
        return true
    }

    private func armTick() {
        cancelTick = schedule(0.25) { [weak self] in
            guard let self, self.environmentValid() else { return }
            var updated = self.interfaces
            for i in updated.indices {
                for j in updated[i].controls.indices {
                    if let value = self.pending[updated[i].id]?[updated[i].controls[j].id] {
                        updated[i].controls[j].status = .observed(value)
                    }
                }
            }
            self.pending.removeAll()
            self.interfaces = updated
            self.armTick()
        }
    }
}
