import Foundation

/// One HID interface as chord attribution sees it. `token` names this connection of this interface and is never
/// reused, unlike `deviceID`, which is a model-level settings key two identical mice can share.
public struct ChordConnectionInfo: Equatable, Sendable {
    public var token: UInt64
    public var deviceID: String
    public var vendorID: Int
    public var productID: Int
    public var transport: String?
    public var locationID: Int?
    public var excluded: Bool

    public init(token: UInt64, deviceID: String, vendorID: Int, productID: Int, transport: String?, locationID: Int?,
                excluded: Bool = false) {
        self.token = token
        self.deviceID = deviceID
        self.vendorID = vendorID
        self.productID = productID
        self.transport = transport
        self.locationID = locationID
        self.excluded = excluded
    }

    var isBluetooth: Bool { transport?.lowercased().contains("bluetooth") == true }
    var hasLocation: Bool { (locationID ?? 0) != 0 }
}

/// Why a connection can or can't form chords. Anything but `eligible` fails open: its presses are never held back.
public enum ChordEligibility: Equatable, Sendable {
    case eligible
    /// Trackpads and touch mice are left alone.
    case excluded
    /// USB mice and receivers: one receiver connection can carry presses from several mice, so it is not trusted.
    case notBluetooth
    /// Without a location the connection can't be told from another of the same model.
    case noLocation
    /// Another connected mouse is the same model, so two physical mice could be combined.
    case sameModel

    public var explanation: String {
        switch self {
        case .eligible: "Two-button chords are available."
        case .excluded: "Whisker leaves this device alone."
        case .notBluetooth: "Chords need a Bluetooth connection; USB mice and receivers pass presses through unchanged."
        case .noLocation: "macOS doesn't identify this connection, so presses pass through unchanged."
        case .sameModel: "Another connected mouse is the same model, so chords are off for both."
        }
    }
}

public enum ChordConnectionPolicy {
    /// Conservative on purpose: only a Bluetooth interface with a location, alone among the connected non-excluded
    /// devices of its model, is trusted to be one physical mouse.
    public static func eligibility(of info: ChordConnectionInfo, among all: [ChordConnectionInfo]) -> ChordEligibility {
        guard !info.excluded else { return .excluded }
        guard info.isBluetooth else { return .notBluetooth }
        guard info.hasLocation else { return .noLocation }
        let sameModel = all.filter { !$0.excluded && $0.vendorID == info.vendorID && $0.productID == info.productID }
        if sameModel.contains(where: { !$0.hasLocation }) { return .sameModel }
        guard Set(sameModel.compactMap(\.locationID)).count == 1 else { return .sameModel }
        return .eligible
    }

    /// The best answer per listed device id; a device is eligible when one of its interfaces is.
    public static func eligibility(byDevice all: [ChordConnectionInfo]) -> [String: ChordEligibility] {
        var result: [String: ChordEligibility] = [:]
        for info in all {
            let eligibility = Self.eligibility(of: info, among: all)
            if result[info.deviceID] != .eligible { result[info.deviceID] = eligibility }
        }
        return result
    }
}

/// The physical connection a Quartz button event came from, and the listed device that connection belongs to.
public struct ChordSource: Equatable, Sendable {
    public var connection: ChordConnection
    public var deviceID: String

    public init(connection: ChordConnection, deviceID: String) {
        self.connection = connection
        self.deviceID = deviceID
    }
}

/// Matches a Quartz button transition to the one HID connection that reported the same transition just before it.
///
/// Unlike `DeviceAttributor`, it records releases as well as presses, keeps reports per connection rather than per
/// model, never infers "the only mouse", and consumes each report once. Anything ambiguous answers nil.
public struct ChordAttributor: Sendable {
    public static let window: TimeInterval = 0.03
    public static let capacity = 64

    private struct Key: Hashable, Sendable {
        var token: UInt64
        var button: Int
    }

    private struct Transition: Sendable {
        var key: Key
        var down: Bool
        var time: TimeInterval
        var consumed = false
    }

    private var transitions: [Transition] = []
    private var held: Set<Key> = []
    private var connections: [UInt64: ChordConnectionInfo] = [:]
    private var eligible: Set<UInt64> = []

    public init() {}

    /// Replaces what is known about the connected interfaces. Reports from a connection that has gone are forgotten.
    public mutating func update(connections infos: [ChordConnectionInfo]) {
        connections = Dictionary(infos.map { ($0.token, $0) }, uniquingKeysWith: { _, latest in latest })
        eligible = Set(infos.filter { ChordConnectionPolicy.eligibility(of: $0, among: infos) == .eligible }.map(\.token))
        transitions.removeAll { connections[$0.key.token] == nil }
        held = held.filter { connections[$0.token] != nil }
    }

    /// A HID button value changed. Repeated values are not transitions and are ignored.
    public mutating func record(token: UInt64, button: Int, down: Bool, at time: TimeInterval) {
        guard time.isFinite else { return }
        let key = Key(token: token, button: button)
        if down {
            guard held.insert(key).inserted else { return }
        } else {
            guard held.remove(key) != nil else { return }
        }
        transitions.append(Transition(key: key, down: down, time: time))
        if transitions.count > Self.capacity { transitions.removeFirst(transitions.count - Self.capacity) }
    }

    /// The connection behind a Quartz press or release of `button` at `time`: only when exactly one connection
    /// reported that transition within the window and that connection is eligible. The report is used up.
    public mutating func attribute(button: Int, down: Bool, at time: TimeInterval) -> ChordSource? {
        guard time.isFinite else { return nil }
        let matches = transitions.indices.filter {
            let transition = transitions[$0]
            return !transition.consumed && transition.key.button == button && transition.down == down
                && abs(time - transition.time) <= Self.window
        }
        let tokens = Set(matches.map { transitions[$0].key.token })
        guard tokens.count == 1, let token = tokens.first, eligible.contains(token), let info = connections[token],
              let first = matches.first else { return nil }
        transitions[first].consumed = true
        return ChordSource(connection: ChordConnection(token: token), deviceID: info.deviceID)
    }
}
