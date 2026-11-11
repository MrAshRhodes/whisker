import AppKit

// Placeholder entry point so the package builds before the app shell lands; the app shell replaces this file.
MainActor.assumeIsolated {
    let app = NSApplication.shared
    app.setActivationPolicy(.accessory)
    _ = UpdateController.shared
    app.run()
}
