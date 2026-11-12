import Foundation

public struct ExtraButtonSettings: Equatable, Sendable, Codable {
    public var discoveryEnabled: Bool

    public init(discoveryEnabled: Bool = false) {
        self.discoveryEnabled = discoveryEnabled
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        discoveryEnabled = try c.decodeIfPresent(Bool.self, forKey: .discoveryEnabled) ?? false
    }
}

/// Separate from Trigger and CGEvent button numbers. Descriptor identities are diagnostic, not remappable.
public struct ExtraControlIdentity: Equatable, Hashable, Sendable, Codable {
    public var namespace: String
    public var control: String

    public init(namespace: String, control: String) {
        self.namespace = namespace
        self.control = control
    }
}

public struct ExtraButtonElement: Equatable, Sendable {
    public var kind: HIDElementKind
    public var page: Int
    public var usage: Int
    public var minimum: Int
    public var maximum: Int
    public var reportID: Int
    public var topPage: Int
    public var topUsage: Int
    public var keyboardCollection: Bool
    public var isArray: Bool

    public init(kind: HIDElementKind, page: Int, usage: Int, minimum: Int = 0, maximum: Int = 1,
                reportID: Int = 0, topPage: Int = 1, topUsage: Int = 2,
                keyboardCollection: Bool = false, isArray: Bool = false) {
        self.kind = kind
        self.page = page
        self.usage = usage
        self.minimum = minimum
        self.maximum = maximum
        self.reportID = reportID
        self.topPage = topPage
        self.topUsage = topUsage
        self.keyboardCollection = keyboardCollection
        self.isArray = isArray
    }

    public var identity: ExtraControlIdentity {
        ExtraControlIdentity(namespace: "hid.generic", control: "report:\(reportID)/page:\(page)/usage:\(usage)")
    }

    public var observationAllowed: Bool {
        kind == .input && [0x09, 0x0C].contains(page) && (1...0xFFFF).contains(usage)
            && !(page == 0x09 && usage == 1) && minimum == 0 && maximum == 1
            && (0...255).contains(reportID) && topPage == 1 && [1, 2].contains(topUsage)
            && !keyboardCollection && !isArray
    }
}

public enum ExtraButtonStatus: Equatable, Sendable {
    case awaiting, observed(Int), unsupported, ambiguous

    public var label: String {
        switch self {
        case .awaiting: return "Not yet observed"
        case .observed(let value): return value == 0 ? "Observed — released" : "Observed — pressed"
        case .unsupported: return "Unsupported — metadata only"
        case .ambiguous: return "Ambiguous — metadata only"
        }
    }
}

public struct ExtraButtonControl: Equatable, Sendable, Identifiable {
    /// Connection-local descriptor index, never a saved control identity.
    public var id: Int
    public var identity: ExtraControlIdentity
    public var page: Int
    public var usage: Int
    public var status: ExtraButtonStatus
}

public enum ExtraButtonDiscovery {
    public static let maximumElements = 512
    public static let maximumObservations = 128

    /// USB descriptors cannot establish which paired mouse sent a receiver's values. Until a documented
    /// association exists, only a single, uniquely identified direct Bluetooth pointing interface can listen.
    public static func associationProven(device: PointingDevice, metadata: [HIDInterfaceInfo]) -> Bool {
        guard !device.isExcluded, device.physicalKeys.count == 1, device.serial != nil,
              device.transport?.lowercased() == "bluetooth" else { return false }
        let pointing = metadata.filter(\.isPointing)
        return pointing.count == 1 && pointing[0].identity.id == device.id
            && pointing[0].transport?.lowercased() == "bluetooth"
            && device.physicalKeys.contains(pointing[0].physicalKey)
    }

    public static func controls(elements: [ExtraButtonElement], associationProven: Bool) -> [ExtraButtonControl] {
        guard elements.count <= maximumElements else { return [] }
        let counts = Dictionary(grouping: elements.filter { [0x09, 0x0C].contains($0.page) }, by: \.identity)
        return elements.enumerated().compactMap { index, element in
            guard [0x09, 0x0C].contains(element.page), element.kind != .collection else { return nil }
            let status: ExtraButtonStatus
            if !element.observationAllowed { status = .unsupported }
            else if !associationProven || counts[element.identity, default: []].count != 1 { status = .ambiguous }
            else { status = .awaiting }
            return ExtraButtonControl(id: index, identity: element.identity, page: element.page, usage: element.usage, status: status)
        }
    }
}

public struct ExtraButtonObservation: Equatable, Sendable {
    public var runtimeID: Int
    public var elementIndex: Int
    public var value: Int
    public var timestamp: UInt64

    public init(runtimeID: Int, elementIndex: Int, value: Int, timestamp: UInt64) {
        self.runtimeID = runtimeID
        self.elementIndex = elementIndex
        self.value = value
        self.timestamp = timestamp
    }
}

/// Diagnostic state only: never produces actions, synthesised input or inferred releases.
public struct ExtraButtonRecorder: Sendable {
    public private(set) var observations: [ExtraButtonObservation] = []
    private var latest: [Int: ExtraButtonObservation] = [:]
    private var runtimeID: Int
    private var allowed: Set<Int>

    public init(runtimeID: Int, allowed: Set<Int>) {
        self.runtimeID = runtimeID
        self.allowed = Set(allowed.prefix(ExtraButtonDiscovery.maximumElements))
    }

    @discardableResult public mutating func accept(_ observation: ExtraButtonObservation) -> Bool {
        guard observation.runtimeID == runtimeID, allowed.contains(observation.elementIndex),
              observation.value == 0 || observation.value == 1, observation.timestamp > 0 else { return false }
        if let previous = latest[observation.elementIndex] {
            guard observation.timestamp > previous.timestamp else { return false }
            latest[observation.elementIndex] = observation
            guard previous.value != observation.value else { return false }
        } else {
            latest[observation.elementIndex] = observation
        }
        observations.append(observation)
        if observations.count > ExtraButtonDiscovery.maximumObservations { observations.removeFirst() }
        return true
    }
}
