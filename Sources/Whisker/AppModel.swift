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
    let wheel: WheelController
    let engine: EventEngine

    @Published private(set) var engineRunning = false
    /// Why the latest Hold to Scroll fell back or could not start, for the Buttons pane.
    @Published private(set) var holdToScrollNote: String?
    /// The app in front while it's on the bypass list and Whisker stands aside for it. Separate from the master
    /// switch, which stays as it was and still wins. Never saved: it follows the app in front.
    @Published private(set) var bypassedApp: String?
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
        wheel = WheelController(records: runState.originalWheels)
        let frontApp = self.frontApp
        let devices = self.devices
        let synthesizer = EventSynthesizer(switchApp: { frontApp.switchApp($0) })
        engine = EventEngine(
            synthesizer: synthesizer,
            attribute: { devices.attribute($0, at: $1) },
            frontmostApp: { frontApp.frontmostBundleID },
            attributeMotion: { devices.attributeMotion(at: $0) }
        )
        engine.onHoldStatus = { [weak self] status in
            DispatchQueue.main.async { self?.holdToScrollNote = status.message }
        }
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

    /// Name of the app Whisker is standing aside for, for the menu. Nil while Whisker is switched off, because
    /// then it isn't the bypass that's keeping it out of the way.
    var bypassedAppName: String? {
        guard isEnabled, let bypassedApp else { return nil }
        return appName(forBundleID: bypassedApp)
    }

    func start() {
        let leftovers = !runState.cleanExit && !runState.originalPointers.isEmpty
        let wheelLeftovers = !runState.originalWheels.isEmpty
        runState.cleanExit = false
        store.saveRunState(runState)

        pointer.onOriginalsChange = { [weak self] originals in
            guard let self else { return }
            self.runState.originalPointers = originals
            self.store.saveRunState(self.runState)
        }
        wheel.onRecordsChange = { [weak self] records in
            guard let self else { return }
            self.runState.originalWheels = records
            self.store.saveRunState(self.runState)
        }
        pointer.revert = { [weak self] deviceID, previous in
            self?.store.settings.devices[deviceID, default: DeviceSettings()].pointer = previous
        }

        frontApp.start()
        refreshBypass(using: store.settings)
        // Set after `start()`, which reads the app already in front; the first settings update below acts on it.
        frontApp.onChange = { [weak self] in
            guard let self else { return }
            self.engine.frontmostAppChanged()
            self.refreshBypass(using: self.store.settings)
            self.applyPointers(self.store.settings)
            self.onStatusChange?()
        }
        devices.onChange = { [weak self] connected in
            guard let self else { return }
            self.applyPointers(self.store.settings, connected: connected)
            self.engine.devicesChanged(connected: Set(connected.filter { !$0.isExcluded }.map(\.id)))
        }
        devices.start()
        if leftovers {
            Log.pointer.notice("Last run didn’t quit cleanly; restoring pointer settings it changed")
            pointer.restoreLeftovers(connected: devices.devices)
        }
        if wheelLeftovers {
            Log.devices.notice("Wheel values from an earlier run are still on record; restoring them")
            wheel.restoreLeftovers(connected: devices.devices)
        }

        store.$settings
            .removeDuplicates()
            .sink { [weak self] settings in
                guard let self else { return }
                self.devices.setTrackingMotion(settings.usesMotionActions)
                self.engine.update(settings)
                self.refreshBypass(using: settings)
                self.applyPointers(settings)
                self.onStatusChange?()
            }
            .store(in: &cancellables)

        wheel.$activeDevices
            .removeDuplicates()
            .sink { [weak self] active in self?.engine.setNativeWheelActive(active) }
            .store(in: &cancellables)
        wheel.$restoreFailures
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.onStatusChange?() }
            .store(in: &cancellables)

        // `@Published` announces before it stores, so wait a turn for the menu to read the new value.
        pointer.$restoreFailures
            .dropFirst()
            .removeDuplicates()
            .receive(on: RunLoop.main)
            .sink { [weak self] _ in self?.onStatusChange?() }
            .store(in: &cancellables)

        permission.onChange = { [weak self] trusted in
            guard let self else { return }
            if trusted { self.startEngine() } else { self.stopEngine() }
        }
        if permission.isTrusted { startEngine() }
        permission.startPolling()

        let center = NSWorkspace.shared.notificationCenter
        for name in [NSWorkspace.willSleepNotification, NSWorkspace.sessionDidResignActiveNotification] {
            observers.append(center.addObserver(forName: name, object: nil, queue: .main) { [weak self] _ in
                self?.engine.releaseAll()
            })
        }
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

    /// Puts an app on the bypass list or takes it off. The settings update that follows applies it at once.
    func setBypass(_ bundleID: String, _ bypassed: Bool) {
        store.settings.general.setBypassed(bundleID, bypassed)
    }

    /// The name people know an app by, or its bundle identifier when it isn't installed.
    func appName(forBundleID bundleID: String) -> String {
        if let name = NSWorkspace.shared.runningApplications.first(where: { $0.bundleIdentifier == bundleID })?.localizedName {
            return name
        }
        guard let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) else { return bundleID }
        let name = FileManager.default.displayName(atPath: url.path)
        return name.hasSuffix(".app") ? String(name.dropLast(4)) : name
    }

    func shutdown() {
        permission.stopPolling()
        engine.stop()
        pointer.restoreAll()
        wheel.restoreAll()
        // A mouse that wouldn't take its values back keeps its record, so the next launch tries again.
        runState.originalPointers = pointer.originals
        runState.originalWheels = wheel.records
        runState.cleanExit = pointer.originals.isEmpty && wheel.records.isEmpty
        store.saveRunState(runState)
        store.saveNow()
        Log.app.info("Whisker quit")
    }

    /// Follows the app in front. Takes the settings as an argument because the store's copy is one step behind
    /// while it is publishing a change.
    private func refreshBypass(using settings: WhiskerSettings) {
        let front = frontApp.frontmostBundleID
        let app = settings.isBypassed(app: front) ? front : nil
        guard app != bypassedApp else { return }
        bypassedApp = app
        if let app {
            Log.app.info("Standing aside for \(app, privacy: .public)")
        } else {
            Log.app.info("No longer standing aside")
        }
    }

    private func applyPointers(_ settings: WhiskerSettings, connected: [ConnectedDevice]? = nil) {
        let connected = connected ?? devices.devices
        pointer.apply(settings, connected: connected, bypassed: bypassedApp != nil)
        wheel.apply(settings, connected: connected, bypassed: bypassedApp != nil)
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

