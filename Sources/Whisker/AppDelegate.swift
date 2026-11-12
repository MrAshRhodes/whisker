import AppKit
import SwiftUI
import WhiskerCore

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate, NSMenuDelegate {
    private let model = AppModel()
    private var statusItem: NSStatusItem?
    private lazy var settingsWindow: HostingWindowController = HostingWindowController(title: "Whisker Settings", size: NSSize(width: 760, height: 540), resizable: true) { [model] in
        SettingsView().environmentObject(model)
    }
    private lazy var onboardingWindow: HostingWindowController = HostingWindowController(title: "Welcome to Whisker", size: NSSize(width: 520, height: 460), resizable: false) { [model, weak self] in
        OnboardingView(onFinish: { self?.onboardingWindow.close() }).environmentObject(model)
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        _ = UpdateController.shared
        NSApp.mainMenu = makeMainMenu()
        model.onStatusChange = { [weak self] in self?.refreshStatusItem() }
        model.pointer.onAttention = { [weak self] in self?.showPointerSettings() }
        model.start()
        refreshStatusItem()
        if !model.permission.isTrusted {
            showOnboarding()
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        model.shutdown()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        showSettings(nil)
        return false
    }

    /// Shown while a window is open: the app menu, and Edit so text fields get copy and paste.
    private func makeMainMenu() -> NSMenu {
        let main = NSMenu()
        let appMenu = NSMenu(title: "Whisker")
        let about = NSMenuItem(title: "About Whisker", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        appMenu.addItem(about)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = UpdateController.shared
        appMenu.addItem(updates)
        appMenu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        appMenu.addItem(settings)
        appMenu.addItem(.separator())
        appMenu.addItem(NSMenuItem(title: "Hide Whisker", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h"))
        appMenu.addItem(NSMenuItem(title: "Quit Whisker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
        let appItem = NSMenuItem()
        appItem.submenu = appMenu
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(NSMenuItem(title: "Undo", action: Selector(("undo:")), keyEquivalent: "z"))
        edit.addItem(NSMenuItem(title: "Redo", action: Selector(("redo:")), keyEquivalent: "Z"))
        edit.addItem(.separator())
        edit.addItem(NSMenuItem(title: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x"))
        edit.addItem(NSMenuItem(title: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c"))
        edit.addItem(NSMenuItem(title: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v"))
        edit.addItem(NSMenuItem(title: "Select All", action: #selector(NSText.selectAll(_:)), keyEquivalent: "a"))
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        let window = NSMenu(title: "Window")
        window.addItem(NSMenuItem(title: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w"))
        window.addItem(NSMenuItem(title: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m"))
        let windowItem = NSMenuItem()
        windowItem.submenu = window
        main.addItem(windowItem)
        NSApp.windowsMenu = window
        return main
    }

    // MARK: Status item

    private func refreshStatusItem() {
        guard model.store.settings.general.showMenuBarIcon else {
            if let statusItem { NSStatusBar.system.removeStatusItem(statusItem) }
            statusItem = nil
            return
        }
        if statusItem == nil {
            let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
            let menu = NSMenu()
            menu.delegate = self
            item.menu = menu
            statusItem = item
        }
        guard let button = statusItem?.button else { return }
        let image = NSImage(systemSymbolName: "computermouse", accessibilityDescription: "Whisker")
        image?.isTemplate = true
        button.image = image
        let active = model.isEnabled && model.engineRunning
        button.appearsDisabled = !active
        var tip = active ? "Whisker" : model.engineRunning ? "Whisker (off)" : "Whisker needs Accessibility access"
        if active, let app = model.bypassedAppName { tip = "Whisker (bypassed for \(app))" }
        if !model.pointer.restoreFailures.isEmpty { tip += "\nPointer settings couldn’t be restored" }
        if !model.wheel.restoreFailures.isEmpty { tip += "\nWheel settings couldn’t be restored" }
        button.toolTip = tip
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.state = model.isEnabled ? .on : .off
        menu.addItem(enabled)
        if let app = model.bypassedAppName {
            let bypassed = NSMenuItem(title: "Bypassed for \(app)", action: nil, keyEquivalent: "")
            bypassed.isEnabled = false
            menu.addItem(bypassed)
        } else if model.permission.isTrusted {
            let profile = NSMenuItem(title: "Profile: \(model.activeProfileName)", action: nil, keyEquivalent: "")
            profile.isEnabled = false
            menu.addItem(profile)
        }
        if !model.permission.isTrusted {
            let grant = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(showOnboarding), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
        addPointerItems(to: menu)
        if !model.pointer.restoreFailures.isEmpty {
            let warning = NSMenuItem(title: "Pointer settings couldn’t be restored…", action: #selector(showPointerSettings), keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
        }
        if !model.wheel.restoreFailures.isEmpty {
            let warning = NSMenuItem(title: "Wheel settings couldn’t be restored…", action: #selector(showWheelSettings), keyEquivalent: "")
            warning.target = self
            menu.addItem(warning)
        }
        let cancel = NSMenuItem(title: "Cancel Sequence", action: model.isSequenceRunning ? #selector(cancelSequence) : nil, keyEquivalent: "")
        cancel.target = self
        menu.addItem(cancel)
        menu.addItem(.separator())
        let settings = NSMenuItem(title: "Settings…", action: #selector(showSettings(_:)), keyEquivalent: ",")
        settings.target = self
        menu.addItem(settings)
        let updates = NSMenuItem(title: "Check for Updates…", action: #selector(UpdateController.checkForUpdates(_:)), keyEquivalent: "")
        updates.target = UpdateController.shared
        menu.addItem(updates)
        let about = NSMenuItem(title: "About Whisker", action: #selector(showAbout), keyEquivalent: "")
        about.target = self
        menu.addItem(about)
        menu.addItem(.separator())
        menu.addItem(NSMenuItem(title: "Quit Whisker", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q"))
    }

    /// What a pointer speed menu item stands for.
    private struct PointerChoice {
        var deviceID: String
        var presetID: String?
    }

    /// A speed change waiting to be kept or reverted, and a submenu for each mouse that has saved speed presets.
    private func addPointerItems(to menu: NSMenu) {
        let pointer = model.pointer
        let settings = model.store.settings
        var items: [NSMenuItem] = []
        if let pending = pointer.pending {
            let mouse = settings.devices[pending.deviceID]?.name ?? ""
            let speed = pending.proposed.pointer.map { PointerMath.speedLabel($0.speed) } ?? "the system speed"
            items.append(NSMenuItem(title: "\(mouse.isEmpty ? "This mouse" : mouse) is at \(speed). Keep it?", action: nil, keyEquivalent: ""))
            items.append(pointerItem("Keep Pointer Speed", #selector(keepPointerSpeed)))
            items.append(pointerItem("Revert Pointer Speed", #selector(revertPointerSpeed)))
            items.append(pointerItem("Use System Settings", #selector(useSystemPointerSpeed(_:)), choice: PointerChoice(deviceID: pending.deviceID)))
        }
        var seen = Set<String>()
        for device in model.devices.devices where !device.isExcluded && seen.insert(device.id).inserted {
            guard let saved = settings.devices[device.id], !saved.pointerPresets.isEmpty else { continue }
            items.append(pointerSubmenuItem(for: device, saved: saved))
        }
        guard !items.isEmpty else { return }
        menu.addItem(.separator())
        items.forEach(menu.addItem)
    }

    private func pointerItem(_ title: String, _ action: Selector, choice: PointerChoice? = nil) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: action, keyEquivalent: "")
        item.target = self
        item.representedObject = choice
        return item
    }

    /// "Pointer Speed — MX Master", with a row per preset, "Custom" while the speed matches none of them, and
    /// Use System Settings. A row that can't be used right now is greyed out and says why in its tooltip.
    private func pointerSubmenuItem(for device: ConnectedDevice, saved: DeviceSettings) -> NSMenuItem {
        let submenu = NSMenu()
        submenu.autoenablesItems = false
        for preset in saved.pointerPresets {
            let refusal = model.pointer.refusal(forPreset: preset.id, on: device.id)
            let row = pointerItem(preset.label, #selector(selectPointerPreset(_:)), choice: PointerChoice(deviceID: device.id, presetID: preset.id))
            row.state = saved.activePointerPreset?.id == preset.id ? .on : .off
            row.isEnabled = refusal == nil
            row.toolTip = refusal?.message(device: device.name)
            submenu.addItem(row)
        }
        if saved.pointer != nil, saved.activePointerPreset == nil {
            let custom = NSMenuItem(title: "Custom", action: nil, keyEquivalent: "")
            custom.state = .on
            custom.isEnabled = false
            submenu.addItem(custom)
        }
        submenu.addItem(.separator())
        let system = pointerItem("Use System Settings", #selector(useSystemPointerSpeed(_:)), choice: PointerChoice(deviceID: device.id))
        system.state = saved.pointer == nil ? .on : .off
        system.isEnabled = saved.pointer != nil
        submenu.addItem(system)

        let item = NSMenuItem(title: "Pointer Speed — \(device.name)", action: nil, keyEquivalent: "")
        item.submenu = submenu
        return item
    }

    @objc private func selectPointerPreset(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PointerChoice, let presetID = choice.presetID else { return }
        if case .rejected = model.pointer.selectPreset(presetID, on: choice.deviceID) { NSSound.beep() }
    }

    @objc private func useSystemPointerSpeed(_ sender: NSMenuItem) {
        guard let choice = sender.representedObject as? PointerChoice else { return }
        model.pointer.useSystemSettings(on: choice.deviceID)
    }

    @objc private func keepPointerSpeed() {
        model.pointer.confirmPending()
    }

    @objc private func revertPointerSpeed() {
        model.pointer.revertPending()
    }

    @objc private func cancelSequence() {
        model.cancelSequence()
    }

    @objc private func toggleEnabled(_ sender: Any?) {
        model.setEnabled(!model.isEnabled)
    }

    @objc func showSettings(_ sender: Any?) {
        settingsWindow.show()
    }

    @objc private func showAbout() {
        model.selectedPane = .about
        settingsWindow.show()
    }

    @objc private func showPointerSettings() {
        model.selectedPane = .pointer
        settingsWindow.show()
    }

    @objc private func showWheelSettings() {
        model.selectedPane = .scrolling
        settingsWindow.show()
    }

    @objc private func showOnboarding() {
        model.permission.refresh()
        onboardingWindow.show()
    }
}

/// A window around a SwiftUI view. While any of these is open Whisker shows in the Dock and app switcher,
/// so the window can be found again; with none open it goes back to being a menu bar app.
@MainActor
final class HostingWindowController: NSObject, NSWindowDelegate {
    private static var openCount = 0

    private let title: String
    private let size: NSSize
    private let resizable: Bool
    private let makeView: () -> AnyView
    private var window: NSWindow?
    var onClose: (() -> Void)?

    init<Content: View>(title: String, size: NSSize, resizable: Bool, content: @escaping () -> Content) {
        self.title = title
        self.size = size
        self.resizable = resizable
        makeView = { AnyView(content()) }
    }

    func show() {
        if window == nil {
            var style: NSWindow.StyleMask = [.titled, .closable, .miniaturizable]
            if resizable { style.insert(.resizable) }
            let window = NSWindow(contentRect: NSRect(origin: .zero, size: size), styleMask: style, backing: .buffered, defer: false)
            let hosting = NSHostingController(rootView: makeView())
            hosting.sizingOptions = resizable ? [.minSize] : [.preferredContentSize]
            window.contentViewController = hosting
            window.title = title
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.setContentSize(size)
            window.center()
            self.window = window
            Self.openCount += 1
            NSApp.setActivationPolicy(.regular)
        }
        NSApp.activate()
        window?.makeKeyAndOrderFront(nil)
    }

    func close() {
        window?.close()
    }

    func windowWillClose(_ notification: Notification) {
        window = nil
        Self.openCount = max(0, Self.openCount - 1)
        if Self.openCount == 0 { NSApp.setActivationPolicy(.accessory) }
        onClose?()
    }
}
