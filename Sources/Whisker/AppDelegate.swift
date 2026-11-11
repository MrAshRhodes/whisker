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
        model.start()
        refreshStatusItem()
        onboardingWindow.onClose = { [model] in model.permission.stopPolling() }
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
        button.toolTip = active ? "Whisker" : model.engineRunning ? "Whisker (off)" : "Whisker needs Accessibility access"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()
        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled(_:)), keyEquivalent: "")
        enabled.target = self
        enabled.state = model.isEnabled ? .on : .off
        menu.addItem(enabled)
        if model.permission.isTrusted {
            let profile = NSMenuItem(title: "Profile: \(model.activeProfileName)", action: nil, keyEquivalent: "")
            profile.isEnabled = false
            menu.addItem(profile)
        } else {
            let grant = NSMenuItem(title: "Grant Accessibility Access…", action: #selector(showOnboarding), keyEquivalent: "")
            grant.target = self
            menu.addItem(grant)
        }
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

    @objc private func showOnboarding() {
        model.permission.refresh()
        model.permission.startPolling()
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
