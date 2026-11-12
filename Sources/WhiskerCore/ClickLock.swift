import Foundation

/// Why a Click Lock ended. Every reason means exactly one release of the held button, except where the
/// user's own press is the release: the next assigned press, or a press of the primary button.
public enum ClickLockEnd: String, CaseIterable, Sendable {
    /// The next press of an assigned trigger, the way the lock is meant to end.
    case assignedPress
    /// An ordinary press of the primary button, from any mouse. It goes through unchanged afterwards.
    case physicalPrimaryPress
    /// A press of a button mapped to click the primary button, or of the button that acts as the primary one on a
    /// mouse with swapped buttons. A second press of the primary button would collide with the held one, so the lock
    /// lets go instead and the press is used up doing it.
    case mappedPrimaryClick
    case disabled
    case permissionLoss
    case deviceDisconnected
    case tapInterrupted
    case sleep
    case quit
    case applicationChanged
    case profileChanged
    case settingsChanged
    case capture
    /// The “Release Click Lock” menu command.
    case menu
}

/// The one synthetic primary-button hold Whisker may own at a time.
///
/// This is deliberately separate from the buttons a trigger holds: it outlives the trigger's release. It records who
/// began the lock and under which context, and it is idempotent: a second `end` does nothing, so no cleanup path can
/// ask for a second release. It is never saved and never restored.
public struct ClickLock: Equatable, Sendable {
    public struct Owner: Equatable, Sendable {
        /// The mouse whose press began the lock, as the tap attributed it. Nil when it could not tell.
        public var device: DeviceAttribution?
        /// The assigned button that began the lock.
        public var trigger: Int
        /// The button held down on the user's behalf. Always the primary button for now.
        public var target: Int
        /// The app in front when the lock began.
        public var app: String?
        public var profile: String
        /// Changes every time a lock begins or ends, so work queued for an earlier lock can tell it is stale.
        public var generation: UInt64
    }

    public private(set) var owner: Owner?
    /// Why the most recent lock ended, for diagnostics.
    public private(set) var lastEnd: ClickLockEnd?
    private var generation: UInt64 = 0

    public init() {}

    public var isActive: Bool { owner != nil }

    /// Starts a lock, or returns nil because one already exists: only one is ever owned.
    public mutating func begin(device: DeviceAttribution?, trigger: Int, app: String?, profile: String) -> Owner? {
        guard owner == nil else { return nil }
        generation &+= 1
        let started = Owner(device: device, trigger: trigger, target: 0, app: app, profile: profile, generation: generation)
        owner = started
        lastEnd = nil
        return started
    }

    /// Ends the lock. Returns the owner when there was one, which means the caller must post the one release.
    @discardableResult
    public mutating func end(_ reason: ClickLockEnd) -> Owner? {
        guard let ended = owner else { return nil }
        owner = nil
        generation &+= 1
        lastEnd = reason
        return ended
    }

    /// Whether `generation` belongs to the lock that is on now.
    public func isCurrent(_ generation: UInt64) -> Bool {
        owner?.generation == generation
    }
}
