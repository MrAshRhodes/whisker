import AppKit
import Combine
import SwiftUI
import WhiskerCore

enum SettingsPane: String, CaseIterable, Identifiable {
    case general, buttons, scrolling, pointer, applications, devices, updates, about

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .buttons: return "Buttons"
        case .scrolling: return "Scrolling"
        case .pointer: return "Pointer"
        case .applications: return "Applications"
        case .devices: return "Devices"
        case .updates: return "Updates"
        case .about: return "About"
        }
    }

    var symbolName: String {
        switch self {
        case .general: return "gearshape"
        case .buttons: return "computermouse"
        case .scrolling: return "arrow.up.and.down"
        case .pointer: return "cursorarrow.motionlines"
        case .applications: return "square.grid.2x2"
        case .devices: return "cable.connector"
        case .updates: return "arrow.down.circle"
        case .about: return "info.circle"
        }
    }
}

/// Ties the pieces together: settings flow to the event tap and the pointer; permission and devices flow back
/// to the menu and the settings window.
@MainActor
final class AppModel: ObservableObject {
    let store: SettingsStore
    let permission = AccessibilityPermission()
    let loginItem = LoginItemController()
    let devices = DeviceMonitor()
    let frontApp = FrontAppMonitor()
    let pointer: PointerController
    let engine: EventEngine

    @Published private(set) var engineRunning = false
    @Published var selectedPane: SettingsPane = .general
    @Published var selectedProfileID: String = Profile.defaultID
    /// While true the event tap lets everything through, so the settings window can see a button press.
    @Published var capturing = false {
        didSet { if capturing != oldValue { engine.setCapturing(capturing) } }
    }

    var onStatusChange: (() -> Void)?
    private var runState: RunState
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    init(store: SettingsStore? = nil) {
        let store = store ?? SettingsStore()
        self.store = store
        runState = store.loadRunState()
        pointer = PointerController(originals: runState.originalPointers)
        let frontApp = self.frontApp
        let devices = self.devices
        let synthesizer = EventSynthesizer(switchApp: { frontApp.switchApp($0) })
        engine = EventEngine(
            synthesizer: synthesizer,
            attribute: { devices.attribute($0, at: $1) },
            frontmostApp: { frontApp.frontmostBundleID }
        )
    }

    var settings: WhiskerSettings {
        get { store.settings }
        set { store.settings = newValue }
    }

    var isEnabled: Bool { store.settings.general.enabled }

    /// The profile in use for the frontmost app, for the menu.
    var activeProfileName: String {
        store.settings.matchingProfile(device: nil, app: frontApp.frontmostBundleID).name
    }

    func start() {
        let leftovers = !runState.cleanExit && !runState.originalPointers.isEmpty
        runState.cleanExit = false
        store.saveRunState(runState)

        pointer.onOriginalsChange = { [weak self] originals in
            guard let self else { return }
            self.runState.originalPointers = originals
            self.store.saveRunState(self.runState)
        }
        pointer.revert = { [weak self] deviceID, previous in
            self?.store.settings.devices[deviceID, default: DeviceSettings()].pointer = previous
        }

        frontApp.start()
        devices.onChange = { [weak self] connected in
            guard let self else { return }
            self.pointer.apply(self.store.settings, connected: connected)
        }
        devices.start()
        if leftovers {
            Log.pointer.notice("Last run didn’t quit cleanly; restoring pointer settings it changed")
            pointer.restoreLeftovers(connected: devices.devices)
        }

        store.$settings
            .removeDuplicates()
            .sink { [weak self] settings in
                guard let self else { return }
                self.engine.update(settings)
                self.pointer.apply(settings, connected: self.devices.devices)
                self.onStatusChange?()
            }
            .store(in: &cancellables)

        permission.onChange = { [weak self] trusted in
            guard let self else { return }
            if trusted { self.startEngine() } else { self.stopEngine() }
        }
        if permission.isTrusted { startEngine() }

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.engine.releaseAll()
            })
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.onStatusChange?() }
        })
        Log.app.info("Whisker \(AppInfo.version, privacy: .public) started; accessibility \(self.permission.isTrusted ? "granted" : "not granted", privacy: .public)")
    }

    func startEngine() {
        engineRunning = engine.start()
        onStatusChange?()
    }

    func stopEngine() {
        engine.stop()
        engineRunning = false
        onStatusChange?()
    }

    func setEnabled(_ enabled: Bool) {
        store.settings.general.enabled = enabled
        Log.app.info("Whisker \(enabled ? "enabled" : "disabled", privacy: .public)")
    }

    func shutdown() {
        engine.stop()
        pointer.restoreAll()
        runState.cleanExit = true
        runState.originalPointers = [:]
        store.saveRunState(runState)
        store.saveNow()
        Log.app.info("Whisker quit")
    }

    // MARK: Editing helpers

    func profileBinding(_ id: String) -> Binding<Profile> {
        Binding(
            get: { [store] in store.settings.profile(id: id) ?? store.settings.defaultProfile },
            set: { [store] in store.settings.upsert($0) }
        )
    }

    func deviceBinding(_ id: String, name: String) -> Binding<DeviceSettings> {
        Binding(
            get: { [store] in store.settings.devices[id] ?? DeviceSettings(name: name) },
            set: { [store] value in
                var value = value
                if value.name.isEmpty { value.name = name }
                store.settings.devices[id] = value
            }
        )
    }

    func deleteProfile(_ id: String) {
        guard id != Profile.defaultID else { return }
        var settings = store.settings
        settings.profiles.removeAll { $0.id == id }
        for index in settings.profiles.indices where settings.profiles[index].inherits == id {
            settings.profiles[index].inherits = Profile.defaultID
        }
        store.settings = settings
        if selectedProfileID == id { selectedProfileID = Profile.defaultID }
    }
}

