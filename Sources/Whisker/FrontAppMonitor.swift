import AppKit
import os
import WhiskerCore

/// Tracks the frontmost app (read from the event tap thread) and the order apps were used in.
final class FrontAppMonitor: @unchecked Sendable {
    private struct State {
        var frontmost = FrontmostApp()
        var history = AppSwitchHistory()
        var instance: ApplicationInstance?
        var activations: UInt64 = 0
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private var observers: [NSObjectProtocol] = []

    /// Runs on the main thread after a different app, one Whisker can identify, comes to the front.
    @MainActor var onChange: (() -> Void)?

    /// Runs on the main thread whenever any app comes to the front, including one that was already there.
    @MainActor var onActivation: (() -> Void)?

    var frontmostBundleID: String? { state.withLock { $0.frontmost.bundleID } }

    /// The app in front as a process and an activation count, so a sequence can tell that it is the same
    /// app instance it started in and that none has come forward since. Nil until an app has been seen.
    var frontmostInstance: ApplicationInstance? { state.withLock { $0.instance } }

    @MainActor
    func start() {
        let center = NSWorkspace.shared.notificationCenter
        let front = NSWorkspace.shared.frontmostApplication
        activated(bundleID: front?.bundleIdentifier, processID: front?.processIdentifier)
        observers.append(center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication
            MainActor.assumeIsolated { self?.activated(bundleID: app?.bundleIdentifier, processID: app?.processIdentifier) }
        })
        observers.append(center.addObserver(forName: NSWorkspace.didTerminateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.terminated(bundleID: (note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)?.bundleIdentifier)
        })
    }

    /// An app came to the front. One without a usable bundle identifier changes nothing, so a bypassed app
    /// stays bypassed (and any other stays handled) until an app Whisker can identify is in front.
    @MainActor
    func activated(bundleID: String?, processID: pid_t? = nil) {
        // Every activation counts for sequences, even one of an app without a bundle identifier. Without a
        // process the instance is unknown, which stops a sequence from starting rather than guessing.
        state.withLock { state in
            state.activations &+= 1
            state.instance = processID.map { ApplicationInstance(processID: $0, activation: state.activations) }
        }
        onActivation?()
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
