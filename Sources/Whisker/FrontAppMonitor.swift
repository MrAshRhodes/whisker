import AppKit
import os
import WhiskerCore

/// Tracks the frontmost app (read from the event tap thread) and the order apps were used in.
final class FrontAppMonitor: @unchecked Sendable {
    private struct State {
        var frontmost = FrontmostApp()
        var history = AppSwitchHistory()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var observers: [NSObjectProtocol] = []

    /// Runs on the main thread after a different app, one Whisker can identify, comes to the front.
    @MainActor var onChange: (() -> Void)?

    var frontmostBundleID: String? { state.withLock { $0.frontmost.bundleID } }

    @MainActor
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        activated(bundleID: NSWorkspace.shared.frontmostApplication?.bundleIdentifier)
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier
            MainActor.assumeIsolated { self?.activated(bundleID: app) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.terminated(bundleID: (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier)
        })
    }

    /// An app came to the front. One without a usable bundle identifier changes nothing, so a bypassed app
    /// stays bypassed (and any other stays handled) until an app Whisker can identify is in front.
    @MainActor
    func activated(bundleID: String?) {
        let changed = state.withLock { state -> Bool in
            let before = state.frontmost
            guard state.frontmost.activated(bundleID), let app = state.frontmost.bundleID else { return false }
            state.history.activated(app)
            return state.frontmost != before
        }
        if changed { onChange?() }
    }

    /// An app quit. Which app is in front doesn't change until another one comes forward, so only the
    /// switching history does.
    func terminated(bundleID: String?) {
        guard let bundleID, !bundleID.isEmpty else { return }
        state.withLock { $0.history.terminated(bundleID) }
    }

    /// Brings the previously used (or least recently used) app forward.
    @MainActor
    func switchApp(_ direction: AppSwitchDirection) {
        let running = NSWorkspace.shared.runningApplications.filter { $0.activationPolicy == .regular }
        let ids = Set(running.compactMap(\.bundleIdentifier))
        guard let target = state.withLock({ $0.history.target(direction, running: ids) }),
              let app = running.first(where: { $0.bundleIdentifier == target })
        else {
            NSSound.beep()
            return
        }
        app.activate()
    }
}
