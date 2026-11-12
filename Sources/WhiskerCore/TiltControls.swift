import Foundation

// Discovery of tilt-wheel controls. Whisker can only observe what macOS delivers: a numbered button, or a
// horizontal scroll report. It never assumes which one a given mouse uses and never turns a scroll into a button.

/// What a single scroll event says, read the same way for recording and for the event tap.
public enum ScrollClassification: Equatable, Sendable {
    case noMovement
    /// Coasting after the wheel or fingers let go.
    case momentum
    /// Smooth scrolling: a trackpad or a free-spinning wheel, not a notch.
    case continuous
    /// Movement on both axes in one event.
    case mixedAxis
    /// A wheel notch with a fractional or pixel distance but no whole line.
    case fractionalOnly
    case notch(WheelDirection)
}

extension ScrollSample {
    public var classification: ScrollClassification {
        if isZero { return .noMovement }
        if isMomentum { return .momentum }
        if isContinuous { return .continuous }
        if !vertical.isZero, !horizontal.isZero { return .mixedAxis }
        let axis = vertical.isZero ? horizontal : vertical
        if axis.lines == 0 { return .fractionalOnly }
        return direction.map(ScrollClassification.notch) ?? .noMovement
    }
}

/// One thing seen while the user performed a control.
public enum ControlObservation: Equatable, Sendable {
    case buttonDown(Int)
    case scroll(ScrollSample)
}

/// Why an observed control can't become a mapping.
public enum UnusableControl: Equatable, Sendable {
    case noInput
    case verticalWheel
    case continuousScrolling
    case momentumScrolling
    case fractionalScrolling
    case mixedAxes
    /// Different buttons, or a button and scrolling, for one action.
    case conflicting

    public var explanation: String {
        switch self {
        case .noInput:
            return "Nothing was detected. Some controls don't send anything macOS passes on to apps, so Whisker can't map them."
        case .verticalWheel:
            return "That moved the wheel up or down, which is ordinary vertical scrolling rather than a tilt."
        case .continuousScrolling:
            return "That arrived as smooth scrolling, like a trackpad or a free-spinning wheel, not as a button or a wheel notch. Whisker can't map it as a button."
        case .momentumScrolling:
            return "That was coasting after a scroll rather than a deliberate input, so it can't be mapped."
        case .fractionalScrolling:
            return "That scrolled by a fraction of a line, not a whole wheel notch, so it can't be mapped reliably."
        case .mixedAxes:
            return "That scrolled up or down and sideways at once, so there's no single direction to map."
        case .conflicting:
            return "That produced more than one kind of input (different buttons, or a button and scrolling). Try again with a single, clean press or tilt."
        }
    }
}

/// What a recorded control turned out to be.
public enum ControlCandidate: Equatable, Sendable {
    case button(Int)
    case horizontalScroll(WheelDirection)
    case unusable(UnusableControl)

    /// The trigger to preview and save; nil when there's only an explanation.
    public var trigger: Trigger? {
        switch self {
        case .button(let number): return .button(number)
        case .horizontalScroll(let direction): return .wheel(direction)
        case .unusable: return nil
        }
    }

    public var explanation: String {
        switch self {
        case .button(let number):
            return "macOS reported \(Trigger.buttonTitle(number)). It stays an ordinary button mapping, with a normal press and release."
        case .horizontalScroll(let direction):
            return "macOS reported horizontal scrolling (\(direction.title)), not a button. A \(direction.title) mapping also matches any other horizontal scrolling from the same mouse, so it can't be limited to the tilt alone. A tilt sends no button release, so it runs once per tilt, never as a held click."
        case .unusable(let reason):
            return reason.explanation
        }
    }
}

public enum TiltClassifier {
    /// Reduces everything seen during one prompt to a candidate. A single clean result is needed: any noise or
    /// disagreement gives an explanation, never a guess.
    public static func classify(_ observations: [ControlObservation]) -> ControlCandidate {
        guard !observations.isEmpty else { return .unusable(.noInput) }
        var buttons = Set<Int>()
        var notches = Set<WheelDirection>()
        var problems: [UnusableControl] = []
        for observation in observations {
            switch observation {
            case .buttonDown(let number):
                buttons.insert(number)
            case .scroll(let sample):
                switch sample.classification {
                case .noMovement: break
                case .momentum: problems.append(.momentumScrolling)
                case .continuous: problems.append(.continuousScrolling)
                case .mixedAxis: problems.append(.mixedAxes)
                case .fractionalOnly: problems.append(.fractionalScrolling)
                case .notch(let direction): notches.insert(direction)
                }
            }
        }
        let scrolled = !notches.isEmpty || !problems.isEmpty
        if !buttons.isEmpty, scrolled { return .unusable(.conflicting) }
        if buttons.count > 1 { return .unusable(.conflicting) }
        if let button = buttons.first { return .button(button) }
        if let problem = problems.first { return .unusable(problem) }
        guard let direction = notches.first, notches.count == 1 else {
            return .unusable(notches.isEmpty ? .noInput : .conflicting)
        }
        return direction.isVertical ? .unusable(.verticalWheel) : .horizontalScroll(direction)
    }
}

/// The three controls the guided flow asks for.
public enum TiltStep: Int, CaseIterable, Sendable {
    case tiltLeft, tiltRight, wheelPress

    /// The name offered for a confirmed control.
    public var suggestedLabel: String {
        switch self {
        case .tiltLeft: return "Wheel tilt left"
        case .tiltRight: return "Wheel tilt right"
        case .wheelPress: return "Wheel press"
        }
    }

    public var prompt: String {
        switch self {
        case .tiltLeft: return "Tilt the wheel left once."
        case .tiltRight: return "Tilt the wheel right once."
        case .wheelPress: return "Press the wheel down once, without tilting."
        }
    }
}

/// Cross-checks the three results so one control can't be offered under two names.
public enum TiltReview {
    public static func duplicateProblem(_ results: [TiltStep: ControlCandidate], for step: TiltStep) -> String? {
        guard let trigger = results[step]?.trigger else { return nil }
        for other in TiltStep.allCases where other != step {
            if results[other]?.trigger == trigger {
                return "\(trigger.title) was also seen for “\(other.suggestedLabel)”, so Whisker can't tell them apart."
            }
        }
        return nil
    }
}

// MARK: - Device attribution

/// Which device the flow can name, and whether a hardware label may be attached to it.
public enum TiltDeviceAttribution: Equatable, Sendable {
    /// Exactly one eligible device sent input recently and its identity isn't shared.
    case exact(id: String, name: String)
    /// A guess (for example the only connected mouse). Shown, but never given a label.
    case inferred(id: String, name: String)
    case unknown(String)

    public static func resolve(_ details: [DeviceDetails]) -> TiltDeviceAttribution {
        let connected = details.filter { $0.isConnected && $0.excludedKind == nil }
        let recent = connected.filter { $0.attribution == .recentInput }
        if recent.count == 1, let device = recent.first { return .exact(id: device.id, name: device.name) }
        if recent.count > 1 { return .unknown("More than one mouse sent input recently, so Whisker can't tell which one you used.") }
        let inferred = connected.filter { $0.attribution == .inferredFromOnlyMouse }
        if inferred.count == 1, let device = inferred.first { return .inferred(id: device.id, name: device.name) }
        if connected.isEmpty { return .unknown("No eligible mouse is connected.") }
        return .unknown("Whisker can't tell which mouse you used.")
    }

    public var deviceID: String? {
        switch self {
        case .exact(let id, _), .inferred(let id, _): return id
        case .unknown: return nil
        }
    }

    /// Only an exact attribution may carry a hardware label or a device-specific profile.
    public var allowsLabels: Bool {
        if case .exact = self { return true }
        return false
    }

    public var summary: String {
        switch self {
        case .exact(_, let name): return "\(name) · confidence: exact (it sent input just now)"
        case .inferred(_, let name): return "\(name) · confidence: inferred (the only eligible mouse); not used to label controls"
        case .unknown(let reason): return "Device not identified. \(reason) You can still record triggers; no hardware label is saved."
        }
    }
}

// MARK: - Labels

/// A confirmed, user-visible name for one control on one device. Metadata only: it never changes how the
/// trigger matches or what it is allowed to do.
public struct ControlLabel: Equatable, Sendable, Codable {
    public static let maxLength = 40

    public var trigger: Trigger
    public var name: String

    public init(trigger: Trigger, name: String) {
        self.trigger = trigger
        self.name = name
    }

    /// The name tidied for storage, or nil when nothing usable is left.
    public static func normalised(_ name: String) -> String? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        return String(trimmed.prefix(maxLength))
    }
}

extension DeviceSettings {
    public func controlLabel(for trigger: Trigger) -> String? {
        controlLabels.first { $0.trigger == trigger }?.name
    }

    /// Sets or replaces a label; an empty name removes it.
    public mutating func setControlLabel(_ name: String, for trigger: Trigger) {
        controlLabels.removeAll { $0.trigger == trigger }
        if let name = ControlLabel.normalised(name) { controlLabels.append(ControlLabel(trigger: trigger, name: name)) }
    }
}
