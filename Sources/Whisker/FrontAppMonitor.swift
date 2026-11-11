import AppKit
import os
import WhiskerCore

/// Tracks the frontmost app (read from the event tap thread) and the order apps were used in.
final class FrontAppMonitor: @unchecked Sendable {
    private struct State {
        var frontmost: String?
        var history = AppSwitchHistory()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var observers: [NSObjectProtocol] = []

    var frontmostBundleID: String? { state.withLock { $0.frontmost } }

    @MainActor
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        if let app = NSWorkspace.shared.frontmostApplication?.bundleIdentifier {
            state.withLock {
                $0.frontmost = app
                $0.history.activated(app)
            }
        }
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            self?.state.withLock {
                $0.frontmost = app
                $0.history.activated(app)
            }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            guard let app = (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier else { return }
            self?.state.withLock { $0.history.terminated(app) }
        })
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
