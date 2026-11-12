import Foundation

/// Scroll distance on one axis, in the three units a scroll event carries.
public struct ScrollAxis: Equatable, Sendable {
    /// Whole lines (`scrollWheelEventDeltaAxis`).
    public var lines: Int
    /// Fractional lines (`scrollWheelEventFixedPtDeltaAxis`).
    public var fixed: Double
    /// Pixels (`scrollWheelEventPointDeltaAxis`).
    public var points: Double

    public init(lines: Int = 0, fixed: Double = 0, points: Double = 0) {
        self.lines = lines
        self.fixed = fixed
        self.points = points
    }

    public static let zero = ScrollAxis()

    public var isZero: Bool { lines == 0 && fixed == 0 && points == 0 }

    /// +1, -1 or 0, taking the first unit that has a value.
    public var sign: Int {
        if lines != 0 { return lines > 0 ? 1 : -1 }
        if fixed != 0 { return fixed > 0 ? 1 : -1 }
        if points != 0 { return points > 0 ? 1 : -1 }
        return 0
    }

    public var negated: ScrollAxis { ScrollAxis(lines: -lines, fixed: -fixed, points: -points) }

    public static func lines(_ count: Int) -> ScrollAxis {
        ScrollAxis(lines: count, fixed: Double(count), points: Double(count) * ScrollMath.pointsPerLine)
    }
}

/// One scroll event. Vertical positive is up (away from you), horizontal positive is left.
public struct ScrollSample: Equatable, Sendable {
    public var vertical: ScrollAxis
    public var horizontal: ScrollAxis
    /// Smooth scrolling from a trackpad or free-spinning wheel rather than wheel notches.
    public var isContinuous: Bool
    /// Coasting after the fingers or wheel let go. Also counts as continuous, but never starts anything.
    public var isMomentum: Bool

    public init(vertical: ScrollAxis = .zero, horizontal: ScrollAxis = .zero, isContinuous: Bool = false, isMomentum: Bool = false) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.isContinuous = isContinuous || isMomentum
        self.isMomentum = isMomentum
    }

    /// The single wheel direction of a notch, or nil when there's no movement.
    public var direction: WheelDirection? {
        let v = vertical.sign, h = horizontal.sign
        if v != 0 { return v > 0 ? .up : .down }
        if h != 0 { return h > 0 ? .left : .right }
        return nil
    }

    public var isZero: Bool { vertical.isZero && horizontal.isZero }
}

public enum InputKind: Equatable, Sendable {
    case buttonDown(Int)
    case buttonUp(Int)
    case buttonDragged(Int)
    case scroll(ScrollSample)
}

/// A mouse event as the event tap sees it, stripped down to what decides how to handle it.
public struct InputEvent: Equatable, Sendable {
    public var kind: InputKind
    public var modifiers: ModifierSet
    /// Seconds, monotonic.
    public var timestamp: TimeInterval
    public var device: DeviceAttribution?
    /// Bundle identifier of the frontmost app.
    public var app: String?
    /// Where the pointer is, when the event carries a position.
    public var location: PointerPoint?
    /// Relative movement. Only read while a hold needs it, so most events leave it nil.
    public var motion: PointerMotion?
    /// The device the movement came from. Unlike `device` it is never inferred from there being one mouse: it is
    /// nil unless the movement was attributed to exactly one non-excluded device.
    public var motionDevice: DeviceAttribution?

    public init(
        _ kind: InputKind, modifiers: ModifierSet = [], timestamp: TimeInterval = 0, device: DeviceAttribution? = nil, app: String? = nil,
        location: PointerPoint? = nil, motion: PointerMotion? = nil, motionDevice: DeviceAttribution? = nil
    ) {
        self.kind = kind
        self.modifiers = modifiers
        self.timestamp = timestamp
        self.device = device
        self.app = app
        self.location = location
        self.motion = motion
        self.motionDevice = motionDevice
    }
}

public enum ActionPhase: Equatable, Sendable {
    /// The trigger went down; the action holds until `.up` (clicks, repeating keys).
    case down
    /// The trigger came up.
    case up
    /// Fire once.
    case once
}

/// What the event tap should do with an event.
public enum EventPlan: Equatable, Sendable {
    /// Let the event through untouched.
    case passThrough
    /// Drop the event.
    case swallow
    /// Drop the event and perform the action.
    case perform(Action, ActionPhase)
    /// Rewrite a drag so it carries the button (and modifiers) the held button is mapped to.
    case dragAs(button: Int, modifiers: ModifierSet)
    /// Rewrite a drag as plain pointer movement, so the pointer still moves while a mapped button is held.
    case dragAsMove
    /// Rewrite the scroll distances, removing modifier flags that only served to change the axis.
    case scroll(ScrollSample, removing: ModifierSet)
    /// Drop the movement, scroll by these pixels and put the pointer back on `anchor`.
    case holdScroll(ScrollPixels, anchor: PointerPoint)
    /// Perform the action and let the rest of the scroll event through: the mapped axis is already taken out
    /// of the sample. A zero sample means nothing is left to deliver.
    case performWithScroll(Action, ActionPhase, remaining: ScrollSample)
}

/// Decides, for each mouse event, whether to pass it, drop it or turn it into an action.
///
/// Holds the little state needed across events: which buttons are held as what, when the wheel last fired
/// a mapping (so a spin of the wheel counts as one press), recent notch times for acceleration, and the
/// distance left over from scaling the wheel.
public struct EventProcessor: Sendable {
    /// Notches closer together than this belong to the same burst and fire a wheel mapping once.
    public static let wheelBurstGap: TimeInterval = 0.13

    private var held: [Int: Action] = [:]
    /// Buttons still physically down whose press Whisker swallowed before it stood aside for an app. The
    /// app never saw them go down, so it mustn't see them go up or drag either.
    private var orphaned: Set<Int> = []
    private var lastWheelEvent: [MappingKey: TimeInterval] = [:]
    private var notchTimes: [TimeInterval] = []
    private var scaler = ScrollScaler()
    private var hold: HoldScrollSession?
    private var idleHoldStatus: HoldScrollStatus = .idle
    private var horizontalStream = HorizontalStream()

    public init() {}

    /// Buttons currently held as a mapped action.
    public var heldButtons: [Int: Action] { held }

    /// Whether a hold-to-scroll is in progress and wants the movement details of drag events.
    public var isHolding: Bool { hold != nil }

    /// How the latest hold-to-scroll went, for diagnostics. A fall-back is kept until the next press.
    public var holdStatus: HoldScrollStatus {
        guard let hold else { return idleHoldStatus }
        return hold.fallback.map { .fellBack($0) } ?? .scrolling
    }

    public mutating func process(_ event: InputEvent, settings: CompiledSettings) -> EventPlan {
        switch event.kind {
        case .buttonDown(let button): return buttonDown(button, event, settings)
        case .buttonUp(let button): return buttonUp(button)
        case .buttonDragged(let button): return dragged(button, event, settings)
        case .scroll(let sample): return scroll(sample, event, settings)
        }
    }

    /// Lets go of everything held, returning the actions to finish (e.g. release a synthetic click).
    /// Called when Whisker is turned off, the Mac sleeps or the app quits.
    public mutating func releaseAll() -> [(button: Int, action: Action)] {
        let released = held.sorted { $0.key < $1.key }.filter { $0.value.followsTrigger }.map { (button: $0.key, action: $0.value) }
        held.removeAll()
        orphaned.removeAll()
        endHold(cancelled: true)
        lastWheelEvent.removeAll()
        notchTimes.removeAll()
        scaler.reset()
        horizontalStream.reset()
        return released
    }

    /// Forgets partly recognised wheel movement, e.g. when settings change.
    public mutating func resetScrollRecognition() {
        horizontalStream.reset()
    }

    /// Like `releaseAll()`, for the moment Whisker stands aside for an app. Buttons still down keep being
    /// swallowed (and their drags become plain movement) until they come up, so the app only ever sees
    /// button events whose press it saw.
    public mutating func releaseAllForBypass() -> [(button: Int, action: Action)] {
        let buttons = orphaned.union(held.keys)
        let released = releaseAll()
        orphaned = buttons
        return released
    }

    /// Ends an in-progress hold-to-scroll without waiting for its button (the app in front changed, the mouse
    /// went away…). The button is still down, so it stays swallowed and its movement stays plain pointer movement
    /// until it comes up.
    public mutating func cancelHold() {
        endHold(cancelled: false)
    }

    /// Cancels the hold when the device that started it is no longer among `connected`.
    public mutating func cancelHold(unlessConnected connected: Set<String>) {
        guard let hold, !connected.contains(hold.device) else { return }
        endHold(cancelled: false)
    }

    private mutating func endHold(cancelled releaseButton: Bool) {
        guard let session = hold else { return }
        hold = nil
        idleHoldStatus = session.fallback.map { .fellBack($0) } ?? .idle
        // After a full release nothing is held any more, but the physical button may still be down.
        if releaseButton { orphaned.insert(session.button) }
    }

    // MARK: Buttons

    private func isActive(_ event: InputEvent, _ settings: CompiledSettings) -> Bool {
        guard settings.general.enabled, !settings.isBypassed(app: event.app) else { return false }
        if let id = event.device?.id, settings.settings.devices[id]?.enabled == false { return false }
        return true
    }

    private func lookup(_ trigger: Trigger, _ event: InputEvent, _ settings: CompiledSettings, exactOnly: Bool) -> Mapping? {
        let profile = settings.profile(device: event.device?.id, app: event.app)
        let modifiers = event.modifiers.withoutFunction
        if let mapping = profile.mapping(trigger, modifiers: modifiers) { return mapping }
        if !exactOnly, !modifiers.isEmpty { return profile.mapping(trigger, modifiers: []) }
        return nil
    }

    private mutating func buttonDown(_ button: Int, _ event: InputEvent, _ settings: CompiledSettings) -> EventPlan {
        // A down without an up (missed event): finish the old one first by treating it as released.
        held[button] = nil
        orphaned.remove(button)
        if hold?.button == button { endHold(cancelled: false) }
        guard isActive(event, settings) else { return .passThrough }
        guard let mapping = lookup(.button(button), event, settings, exactOnly: false) else { return .passThrough }
        // The primary button with no modifiers is the way back if a mapping goes wrong.
        if button == 0, mapping.modifiers.isEmpty, !settings.general.allowPrimaryButtonRemap { return .passThrough }
        let action = mapping.action
        if action == .passthrough { return .passThrough }
        if case .holdToScroll(let config) = action { return beginHold(button, config, event) }
        held[button] = action
        if action == .none { return .swallow }
        return .perform(action, action.followsTrigger ? .down : .once)
    }

    private mutating func beginHold(_ button: Int, _ config: HoldScroll, _ event: InputEvent) -> EventPlan {
        // Attribution has to be exact and the position known, or the hold can't be kept to one device.
        guard let device = event.device, device.exact, let anchor = event.location, config.isValid else {
            idleHoldStatus = .unavailable
            return .passThrough
        }
        held[button] = .holdToScroll(config)
        // One hold at a time: a second hold button is swallowed and does nothing.
        if hold == nil {
            hold = HoldScrollSession(button: button, device: device.id, app: event.app, anchor: anchor, config: config)
            idleHoldStatus = .idle
        }
        return .swallow
    }

    private mutating func buttonUp(_ button: Int) -> EventPlan {
        if hold?.button == button { endHold(cancelled: false) }
        guard let action = held.removeValue(forKey: button) else {
            return orphaned.remove(button) != nil ? .swallow : .passThrough
        }
        return action.followsTrigger ? .perform(action, .up) : .swallow
    }

    private mutating func dragged(_ button: Int, _ event: InputEvent, _ settings: CompiledSettings) -> EventPlan {
        guard let action = held[button] else { return orphaned.contains(button) ? .dragAsMove : .passThrough }
        if hold?.button == button {
            guard isActive(event, settings), hold?.app == event.app else {
                endHold(cancelled: false)
                return .dragAsMove
            }
            return hold!.motion(event)
        }
        if case let .click(target, modifiers) = action { return .dragAs(button: target, modifiers: modifiers) }
        return .dragAsMove
    }

    // MARK: Wheel

    private mutating func scroll(_ sample: ScrollSample, _ event: InputEvent, _ settings: CompiledSettings) -> EventPlan {
        guard isActive(event, settings) else { return .passThrough }
        let isNotch = !sample.isContinuous
        var sample = sample
        var fired: Action?
        var consumed = false

        // The mapped horizontal part of smooth scrolling goes first; what's left carries on below.
        if sample.isContinuous, !sample.isMomentum, !sample.horizontal.isZero {
            switch continuousHorizontal(sample.horizontal, event, settings) {
            case .passThrough: break
            case .consume(let action):
                fired = action
                consumed = true
                sample.horizontal = .zero
            }
        }

        if isNotch, let direction = sample.direction,
           let mapping = lookup(.wheel(direction), event, settings, exactOnly: true),
           mapping.action != .passthrough {
            return wheelMapping(mapping, at: event.timestamp)
        }

        var rewritten = sample
        var removing: ModifierSet = []
        var changed = consumed

        // Inverting needs to know the device, so it only applies when the event is clearly from a mouse.
        if let attribution = event.device, attribution.exact || isNotch {
            let wheel = settings.settings.device(attribution.id).wheel
            if wheel.invertVertical, !rewritten.vertical.isZero {
                rewritten.vertical = rewritten.vertical.negated
                changed = true
            }
            if wheel.invertHorizontal, !rewritten.horizontal.isZero {
                rewritten.horizontal = rewritten.horizontal.negated
                changed = true
            }
        }

        guard isNotch else { return finish(rewritten, changed: changed, fired: fired, removing: []) }

        let resolved = settings.profile(device: event.device?.id, app: event.app)
        let scroll = resolved.scroll
        let horizontalModifier = scroll.horizontalModifier.withoutFunction
        if !horizontalModifier.isEmpty, event.modifiers.isSuperset(of: horizontalModifier), !rewritten.vertical.isZero {
            rewritten.horizontal = rewritten.vertical
            rewritten.vertical = .zero
            removing = horizontalModifier
            changed = true
        }

        if let base = scroll.linesPerNotch {
            notchTimes.append(event.timestamp)
            notchTimes.removeAll { event.timestamp - $0 > ScrollMath.rateWindow }
            let rate = ScrollMath.notchRate(times: notchTimes, now: event.timestamp)
            let lines = ScrollMath.effectiveLines(base: base, acceleration: scroll.acceleration, rate: rate)
            if rewritten.vertical.sign != 0 { rewritten.vertical = .lines(rewritten.vertical.sign * lines) }
            if rewritten.horizontal.sign != 0 { rewritten.horizontal = .lines(rewritten.horizontal.sign * lines) }
            changed = true
        }

        // Scaling comes last, on the distance and direction the app would otherwise receive. Only the modifiers
        // it used up are removed, so a held key that did nothing here still reaches the app.
        let device = event.device?.id
        let scaling = scroll.usableModifierScaling
        if let scaled = scaler.scale(rewritten, by: scaling, held: event.modifiers, device: device, profile: resolved.profileID, at: event.timestamp),
           let scaling {
            if scaled.isZero { return .swallow }
            rewritten = scaled
            removing.formUnion(scaling.modifiers.withoutFunction)
            changed = true
        }

        return finish(rewritten, changed: changed, fired: fired, removing: removing)
    }

    private func finish(_ sample: ScrollSample, changed: Bool, fired: Action?, removing: ModifierSet) -> EventPlan {
        if let fired { return .performWithScroll(fired, .once, remaining: sample) }
        guard changed else { return .passThrough }
        return sample.isZero ? .swallow : .scroll(sample, removing: removing)
    }

    private enum ContinuousOutcome {
        case passThrough
        /// The horizontal movement is taken; `Action` is set when it fires now.
        case consume(Action?)
    }

    /// Smooth horizontal scrolling for a Scroll Left/Right mapping that opted in. Only an exactly attributed
    /// device qualifies, so ambiguous input and anything that might not be a mouse is left alone.
    private mutating func continuousHorizontal(_ axis: ScrollAxis, _ event: InputEvent, _ settings: CompiledSettings) -> ContinuousOutcome {
        guard let device = event.device, device.exact else {
            horizontalStream.reset()
            return .passThrough
        }
        let profile = settings.profile(device: device.id, app: event.app).profileID
        // Pixels are the only unit used, so a sample without them can't be measured and is left alone.
        guard axis.points != 0 else { return .passThrough }
        let direction: WheelDirection = axis.points > 0 ? .left : .right
        guard let mapping = lookup(.wheel(direction), event, settings, exactOnly: true),
              mapping.action != .passthrough, let continuous = mapping.continuousInput else {
            horizontalStream.cancel(device: device.id, profile: profile)
            return .passThrough
        }
        let outcome = horizontalStream.feed(
            points: axis.points, direction: direction, modifiers: event.modifiers.withoutFunction,
            distance: continuous.effectiveDistance, device: device.id, profile: profile, at: event.timestamp
        )
        guard outcome == .fire, mapping.action != .none else { return .consume(nil) }
        return .consume(mapping.action)
    }

    private mutating func wheelMapping(_ mapping: Mapping, at time: TimeInterval) -> EventPlan {
        let key = mapping.key
        if mapping.action == .none { return .swallow }
        if case .scroll = mapping.action { return .perform(mapping.action, .once) }
        if mapping.repeatPerNotch { return .perform(mapping.action, .once) }
        let last = lastWheelEvent[key]
        lastWheelEvent[key] = time
        if let last, time - last >= 0, time - last < Self.wheelBurstGap { return .swallow }
        return .perform(mapping.action, .once)
    }
}
