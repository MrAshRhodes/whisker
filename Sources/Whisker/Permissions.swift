import AppKit
import ApplicationServices
import ServiceManagement

/// Whether Whisker may watch and change mouse events (Privacy & Security › Accessibility).
@MainActor
final class AccessibilityPermission: ObservableObject {
    static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    @Published private(set) var isTrusted: Bool
    private var timer: Timer?
    private let check: () -> Bool
    var onChange: ((Bool) -> Void)?

    init(check: @escaping () -> Bool = { AXIsProcessTrusted() }) {
        self.check = check
        isTrusted = check()
    }

    func refresh() {
        let trusted = check()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        Log.permissions.info("Accessibility access \(trusted ? "granted" : "revoked", privacy: .public)")
        onChange?(trusted)
    }

    /// Checks every second for as long as Whisker runs, so access granted or taken away in System Settings
    /// starts or stops the event tap straight away.
    func startPolling() {
        guard timer == nil else { return }
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    func stopPolling() {
        timer?.invalidate()
        timer = nil
    }

    func openSystemSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
        startPolling()
    }
}

/// "Open at login", backed by the system's login items (the source of truth, so it isn't stored in settings).
@MainActor
final class LoginItemController: ObservableObject {
    @Published private(set) var isEnabled = false
    @Published private(set) var needsApproval = false
    @Published private(set) var lastError: String?

    init() {
        refresh()
    }

    func refresh() {
        let status = SMAppService.mainApp.status
        isEnabled = status == .enabled
        needsApproval = status == .requiresApproval
    }

    func setEnabled(_ enabled: Bool) {
        do {
            if enabled {
                try SMAppService.mainApp.register()
            } else {
                try SMAppService.mainApp.unregister()
            }
            lastError = nil
        } catch {
            lastError = error.localizedDescription
            Log.app.error("Login item change failed: \(error.localizedDescription, privacy: .public)")
        }
        refresh()
    }

    func openLoginItemsSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
