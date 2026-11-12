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
    let devices: DeviceMonitor
    /// The opt-in Input Timing sheet in Devices. Idle, and listening to no device, until the user starts a sample.
    let inputTiming: InputTimingController
    let extraButtonDiscovery: ExtraButtonDiscoveryController
    let frontApp = FrontAppMonitor()
    let pointer: PointerController
    let wheel: WheelController
    let engine: EventEngine
    private let sequences: ShortcutSequenceRunner

    @Published private(set) var engineRunning = false
    /// Why the latest Hold to Scroll fell back or could not start, for the Buttons pane.
    @Published private(set) var holdToScrollNote: String?
    /// Whether Whisker is holding the primary button down for a Click Lock, for the menu bar. Never saved.
    @Published private(set) var clickLockActive = false
    /// Whether an auto-scroll is running, for the menu bar icon. Never saved: it ends with the app.
    @Published private(set) var autoScrollActive = false
    /// The app in front while it's on the bypass list and Whisker stands aside for it. Separate from the master
    /// switch, which stays as it was and still wins. Never saved: it follows the app in front.
    @Published private(set) var bypassedApp: String?
    @Published var selectedPane: SettingsPane = .general
    @Published var selectedProfileID: String = Profile.defaultID
    /// While true the event tap lets everything through, so the settings window can see a button press.
    @Published var capturing = false {
        didSet { if capturing != oldValue { engine.setCapturing(capturing) } }
    }

    /// Mice whose duplicate-click filter is on trial, with when it switches itself off unless kept. Never saved.
    /// The length is only changed by tests.
    @Published private(set) var clickFilterTrials: [String: Date] = [:]
    private var clickFilterTimers: [String: Task<Void, Never>] = [:]
    var clickFilterTrialDuration: TimeInterval = 60
    /// The local duplicate-click test in Devices, as the event tap last reported it: counts for one mouse, kept in
    /// memory while the test runs. Never saved or logged.
    @Published private(set) var clickFilterTest: ClickFilterTally?

    /// Mice whose swapped primary and secondary buttons are on trial, with when the swap switches itself off unless
    /// kept. Never saved. The length is only changed by tests.
    @Published private(set) var swapTrials: [String: Date] = [:]
    private var swapTimers: [String: Task<Void, Never>] = [:]
    var swapTrialDuration: TimeInterval = 60

    var onStatusChange: (() -> Void)?
    private var runState: RunState
    private var cancellables: Set<AnyCancellable> = []
    private var observers: [NSObjectProtocol] = []

    init(store: SettingsStore? = nil) {
        let store = store ?? SettingsStore()
        self.store = store
        runState = store.loadRunState()
        let frontApp = self.frontApp
        // One HID access for both, so an interface's runtime id means the same thing to the monitor and to timing.
        let hidAccess = IOKitHIDAccess()
        let devices = DeviceMonitor(hidAccess: hidAccess)
        self.devices = devices
        inputTiming = InputTimingController(
            access: hidAccess, source: devices,
            permissionGranted: { DeviceMonitor.inputMonitoringAllowed },
            requestAccess: { devices.requestIdentification() }
        )
        extraButtonDiscovery = ExtraButtonDiscoveryController(
            access: hidAccess, source: devices, permission: { DeviceMonitor.inputMonitoringAllowed },
            settings: { store.settings }
        )
        let pointer = PointerController(originals: runState.originalPointers, store: store, connected: { devices.devices })
        self.pointer = pointer
        wheel = WheelController(records: runState.originalWheels)
        let sequences = ShortcutSequenceRunner(
            environment: SystemSequenceEnvironment(frontmost: { frontApp.frontmostInstance }, marker: EventSynthesizer.marker),
            stopped: { reason in
                guard reason.needsFeedback else { return }
                Log.events.notice("Shortcut sequence stopped: \(String(describing: reason), privacy: .public)")
                DispatchQueue.main.async { NSSound.beep() }
            }
        )
        self.sequences = sequences
        let synthesizer = EventSynthesizer(
            switchApp: { frontApp.switchApp($0) },
            selectPointerPreset: { deviceID, presetID in
                if case .rejected = pointer.selectPreset(presetID, on: deviceID) { NSSound.beep() }
            },
            sequences: sequences
        )
        engine = EventEngine(
            synthesizer: synthesizer,
            attribute: { devices.attribute($0, at: $1) },
            frontmostApp: { frontApp.frontmostBundleID },
            attributeMotion: { devices.attributeMotion(at: $0) }
        )
        engine.onHoldStatus = { [weak self] status in
            DispatchQueue.main.async { self?.holdToScrollNote = status.message }
        }
        engine.onClickLockChange = { [weak self] active in
            DispatchQueue.main.async {
                self?.clickLockActive = active
                self?.onStatusChange?()
            }
        }
        engine.onAutoScrollActive = { [weak self] active in
            DispatchQueue.main.async {
                self?.autoScrollActive = active
                self?.onStatusChange?()
            }
        }
        engine.onSlowPointer = { [weak self] command in
            guard let self else { return }
            self.pointer.applySlowPointer(command)
            self.engine.setSlowPointerDevices(self.pointer.slowPointerDevices)
        }
        engine.onClickFilterTest = { [weak self] test in self?.clickFilterTest = test }
        pointer.onSlowPointerAvailabilityChange = { [weak self] in
            guard let self else { return }
            self.engine.setSlowPointerDevices(self.pointer.slowPointerDevices)
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

        frontApp.start()
        refreshBypass(using: store.settings)
        // Set after `start()`, which reads the app already in front; the first settings update below acts on it.
        frontApp.onChange = { [weak self] in
            guard let self else { return }
            self.engine.frontmostAppChanged()
            self.extraButtonDiscovery.stop(reason: "Active app/profile changed. Observations cleared.")
            self.refreshBypass(using: self.store.settings)
            self.applyPointers(self.store.settings)
            self.onStatusChange?()
        }
        frontApp.onActivation = { [weak self] in self?.engine.applicationActivated() }
        devices.onChange = { [weak self] connected in
            guard let self else { return }
            self.extraButtonDiscovery.environmentChanged()
            self.pointer.devicesChanged(connected, bypassed: self.bypassedApp != nil)
            self.wheel.apply(self.store.settings, connected: connected, bypassed: self.bypassedApp != nil)
            self.engine.devicesChanged(connected: Set(connected.filter { !$0.isExcluded }.map(\.id)))
            self.engine.setSlowPointerDevices(self.pointer.slowPointerDevices)
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
                self.extraButtonDiscovery.stop(reason: "Settings/profile changed. Inspect starts a new session.")
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
                self?.engine.releaseAll(because: .sleep)
                MainActor.assumeIsolated { self?.cancelSlowPointer() }
                MainActor.assumeIsolated { self?.inputTiming.interrupt(.sleep) }
                MainActor.assumeIsolated { self?.extraButtonDiscovery.stop(reason: "Sleep or user switch. Observations cleared.") }
                MainActor.assumeIsolated { self?.stopClickFilterTest() }
            })
        }
        // An auto-scroll is anchored to a spot on a display and a Space, and a change to either leaves that spot
        // meaning something else, so it ends.
        observers.append(center.addObserver(forName: NSWorkspace.activeSpaceDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.cancelAutoScroll()
        })
        observers.append(NotificationCenter.default.addObserver(forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.cancelAutoScroll()
        })
        // Read here, never in the tap: smoothing stands aside while Reduce Motion is on, and live when it changes.
        engine.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        observers.append(center.addObserver(forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main) { [weak self] _ in
            self?.engine.setReduceMotion(NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        })
        Log.app.info("Whisker \(AppInfo.version, privacy: .public) started; accessibility \(self.permission.isTrusted ? "granted" : "not granted", privacy: .public)")
    }

    func startEngine() {
        engineRunning = engine.start()
        onStatusChange?()
    }

    func stopEngine() {
        // The permission is gone, so the release below may be refused by the system; it is still asked for once.
        engine.releaseClickLock(.permissionLoss)
        engine.stop()
        cancelSlowPointer()
        engineRunning = false
        onStatusChange?()
    }

    /// Lets go of a Click Lock from the menu bar. Does nothing when none is held.
    func releaseClickLock() {
        engine.releaseClickLock(.menu)
    }

    /// Whether a keyboard shortcut sequence is running, for the menu.
    var isSequenceRunning: Bool { sequences.isRunning }

    /// Stops a running keyboard shortcut sequence; steps already posted stay posted.
    func cancelSequence() {
        sequences.cancel(.userCancelled)
    }

    func cancelSlowPointer() {
        pointer.applySlowPointer(engine.cancelSlowPointer())
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

    /// Switches the duplicate-click filter on for the buttons given (none switches it off). Any change that leaves
    /// it on starts a trial: unless it is kept, it switches itself off after `clickFilterTrialDuration`, so a
    /// setting that eats wanted clicks can't stay on by accident.
    func setClickFilter(device id: String, name: String, buttons: [Int], interval: Double) {
        var device = store.settings.devices[id] ?? DeviceSettings(name: name)
        if device.name.isEmpty { device.name = name }
        if buttons.isEmpty {
            device.clickDebounce = nil
            store.settings.devices[id] = device
            endClickFilterTrial(id)
            return
        }
        device.clickDebounce = ClickDebounceSettings(buttons: buttons, interval: interval).normalised
        store.settings.devices[id] = device
        clickFilterTrials[id] = Date().addingTimeInterval(clickFilterTrialDuration)
        clickFilterTimers[id]?.cancel()
        let duration = clickFilterTrialDuration
        clickFilterTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.revertClickFilter(device: id)
        }
    }

    /// Keeps the filter after a trial.
    func confirmClickFilter(device id: String) {
        endClickFilterTrial(id)
    }

    /// Switches the filter off and ends its trial.
    func revertClickFilter(device id: String) {
        store.settings.devices[id]?.clickDebounce = nil
        endClickFilterTrial(id)
    }

    private func endClickFilterTrial(_ id: String) {
        clickFilterTimers[id]?.cancel()
        clickFilterTimers[id] = nil
        clickFilterTrials[id] = nil
    }

    /// Starts counting accepted and filtered presses of one mouse for the local test in Devices, from zero. Only
    /// one mouse is tested at a time. The count arrives in `clickFilterTest`.
    func startClickFilterTest(device id: String) {
        engine.setClickFilterTest(device: id)
    }

    func stopClickFilterTest() {
        engine.setClickFilterTest(device: nil)
    }

    func resetClickFilterTest() {
        engine.clearClickFilterTest()
    }

    /// Swaps a mouse's primary and secondary buttons, or puts them back. Switching it on starts a trial: unless it
    /// is kept, the swap switches itself off after `swapTrialDuration`, so a swap that gets in the way can't stay
    /// on by accident. It never switches on "Allow remapping the primary button" and does nothing while that is off.
    func setSwapPrimarySecondary(device id: String, name: String, on: Bool) {
        guard on else {
            store.settings.devices[id]?.swapPrimarySecondary = false
            endSwapTrial(id)
            return
        }
        guard store.settings.general.allowPrimaryButtonRemap else { return }
        var device = store.settings.devices[id] ?? DeviceSettings(name: name)
        if device.name.isEmpty { device.name = name }
        device.swapPrimarySecondary = true
        store.settings.devices[id] = device
        swapTrials[id] = Date().addingTimeInterval(swapTrialDuration)
        swapTimers[id]?.cancel()
        let duration = swapTrialDuration
        swapTimers[id] = Task { [weak self] in
            try? await Task.sleep(for: .seconds(duration))
            guard !Task.isCancelled else { return }
            self?.revertSwap(device: id)
        }
    }

    /// Keeps the swap after a trial.
    func confirmSwap(device id: String) {
        endSwapTrial(id)
    }

    /// Puts the buttons back and ends the trial.
    func revertSwap(device id: String) {
        store.settings.devices[id]?.swapPrimarySecondary = false
        endSwapTrial(id)
    }

    private func endSwapTrial(_ id: String) {
        swapTimers[id]?.cancel()
        swapTimers[id] = nil
        swapTrials[id] = nil
    }

    func shutdown() {
        inputTiming.shutdown()
        extraButtonDiscovery.stop()
        for id in Array(clickFilterTrials.keys) { revertClickFilter(device: id) }
        for id in Array(swapTrials.keys) { revertSwap(device: id) }
        permission.stopPolling()
        engine.stop()
        cancelSlowPointer()
        // A speed still waiting to be kept goes back first, so it isn't saved as if it had been.
        pointer.revertPending()
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
        engine.setSlowPointerDevices(pointer.slowPointerDevices)
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

