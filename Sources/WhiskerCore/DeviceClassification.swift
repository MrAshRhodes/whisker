import Foundation

/// HID usage numbers the classifier and the controls summary care about (HID Usage Tables).
public enum HIDUsage {
    public static let genericDesktopPage = 0x01
    public static let pointer = 0x01
    public static let mouse = 0x02
    public static let keyboard = 0x06
    public static let keypad = 0x07
    /// Generic Desktop: the vertical wheel.
    public static let wheel = 0x38
    public static let buttonPage = 0x09
    public static let consumerPage = 0x0C
    /// Consumer: AC Pan, the horizontal wheel.
    public static let acPan = 0x238
}

/// One HID interface as the system reports it. A physical device often has several: a gaming mouse adds a
/// keyboard interface for macros, a keyboard adds a mouse interface for mouse keys, a receiver has both.
public struct HIDInterfaceInfo: Hashable, Sendable {
    public var vendorID: Int
    public var productID: Int
    public var serial: String?
    public var product: String?
    public var transport: String?
    /// Where the physical device is attached; every interface of one device shares it. Nil or 0 when unknown.
    public var locationID: Int?
    /// The USB interface number, when the interface comes from USB.
    public var interfaceNumber: Int?
    public var primaryUsagePage: Int
    public var primaryUsage: Int

    public init(
        vendorID: Int, productID: Int, serial: String? = nil, product: String? = nil, transport: String? = nil,
        locationID: Int? = nil, interfaceNumber: Int? = nil, primaryUsagePage: Int, primaryUsage: Int
    ) {
        self.vendorID = vendorID
        self.productID = productID
        self.serial = serial
        self.product = product
        self.transport = transport
        self.locationID = locationID
        self.interfaceNumber = interfaceNumber
        self.primaryUsagePage = primaryUsagePage
        self.primaryUsage = primaryUsage
    }

    public var identity: DeviceIdentity { DeviceIdentity(vendorID: vendorID, productID: productID, serial: serial) }

    /// The interface is a mouse or pointer first, not just something that also reports pointer usages.
    public var isPointing: Bool {
        primaryUsagePage == HIDUsage.genericDesktopPage && (primaryUsage == HIDUsage.mouse || primaryUsage == HIDUsage.pointer)
    }

    public var isKeyboard: Bool {
        primaryUsagePage == HIDUsage.genericDesktopPage && (primaryUsage == HIDUsage.keyboard || primaryUsage == HIDUsage.keypad)
    }

    /// Groups the interfaces of one physical device.
    public var physicalKey: String {
        if let locationID, locationID != 0 { return "location:\(locationID)" }
        return "identity:\(identity.id)"
    }
}

/// A physical pointing device worth listing, built from its HID interfaces.
public struct PointingDevice: Hashable, Sendable, Identifiable {
    public var id: String
    /// What the lists show: the product name, or one made from the ids when the device has none.
    public var name: String
    public var vendorID: Int
    public var productID: Int
    public var serial: String?
    public var transport: String?
    /// Trackpads and touch mice: listed, but Whisker leaves them alone.
    public var excludedKind: ExcludedDeviceKind?
    public var isExcluded: Bool { excludedKind != nil }
    /// `HIDInterfaceInfo.physicalKey` of every device that makes up this entry.
    public var physicalKeys: Set<String>
    /// The product name the device reported, trimmed; nil when it reported none or a blank one.
    public var productName: String?
}

public enum PointingDeviceClassifier {
    /// The physical devices that are mice, trackballs, tablets or trackpads, sorted by name.
    ///
    /// A device counts when one of its interfaces is primarily a mouse or pointer, unless the device as a whole
    /// is a keyboard (see `isKeyboard`). Interfaces are grouped by location first, then by identity.
    public static func pointingDevices(from interfaces: [HIDInterfaceInfo]) -> [PointingDevice] {
        let groups = Dictionary(grouping: interfaces, by: \.physicalKey)
        var byID: [String: PointingDevice] = [:]
        // Sorted, so a shared identity always shows the details of the same device instead of whichever came first.
        for (key, group) in groups.sorted(by: { $0.key < $1.key }) {
            guard let pointing = group.filter(\.isPointing).min(by: lead), !isKeyboard(group) else { continue }
            let identity = pointing.identity
            if var existing = byID[identity.id] {
                existing.physicalKeys.insert(key)
                byID[identity.id] = existing
                continue
            }
            byID[identity.id] = PointingDevice(
                id: identity.id,
                name: DeviceIdentity.displayName(product: pointing.product, vendorID: pointing.vendorID, productID: pointing.productID),
                vendorID: pointing.vendorID, productID: pointing.productID, serial: identity.serial,
                transport: pointing.transport,
                excludedKind: DeviceIdentity.excludedKind(transport: pointing.transport, product: pointing.product, vendorID: pointing.vendorID),
                physicalKeys: [key],
                productName: DeviceIdentity.productName(pointing.product)
            )
        }
        return byID.values.sorted {
            let order = $0.name.localizedStandardCompare($1.name)
            return order == .orderedSame ? $0.id < $1.id : order == .orderedAscending
        }
    }

    /// True for a keyboard that also has a mouse interface (for mouse keys or a built-in pointing stick):
    /// its first interface is a keyboard. Gaming mice put the mouse first and macro keyboards after it.
    /// Wireless receivers often lead with a keyboard too, so anything named like a receiver still counts as a mouse.
    public static func isKeyboard(_ interfaces: [HIDInterfaceInfo]) -> Bool {
        // Without interface numbers (Bluetooth, for one) there's no order to go by, so a mouse gets the benefit of the doubt.
        guard let first = interfaces.min(by: lead), first.isKeyboard, first.interfaceNumber != nil else { return false }
        return !looksLikeReceiver(first.product)
    }

    public static func looksLikeReceiver(_ product: String?) -> Bool {
        let name = product?.lowercased() ?? ""
        return ["receiver", "dongle", "unifying", "lightspeed", "bolt"].contains { name.contains($0) }
    }

    /// Lowest interface number first; interfaces without one go last.
    static func lead(_ a: HIDInterfaceInfo, _ b: HIDInterfaceInfo) -> Bool {
        switch (a.interfaceNumber, b.interfaceNumber) {
        case let (x?, y?): return x != y ? x < y : a.primaryUsage < b.primaryUsage
        case (.some, .none): return true
        case (.none, .some): return false
        case (.none, .none): return a.primaryUsage < b.primaryUsage
        }
    }
}
