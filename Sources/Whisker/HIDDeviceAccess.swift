import Foundation
import IOKit.hid
import WhiskerCore

/// One element of a HID device's descriptor, as much as the callers so far need.
struct HIDElementDescription: Hashable {
    var kind: HIDElementKind
    var usagePage: Int
    var usage: Int
    var logicalMin: Int
    var logicalMax: Int
    /// The report the element is part of; 0 when the device doesn't use report ids.
    var reportID = 0
    /// Usage of the top-level collection the element sits in (0 when macOS doesn't say), so a mouse's reports
    /// can be told from a keyboard's on the same interface.
    var topLevelUsagePage = 0
    var topLevelUsage = 0
    var cookie: UInt32 = 0
    var hasKeyboardCollection = false
    var isArray = false

    var discoveryElement: ExtraButtonElement {
        ExtraButtonElement(kind: kind, page: usagePage, usage: usage, minimum: logicalMin, maximum: logicalMax,
                           reportID: reportID, topPage: topLevelUsagePage, topUsage: topLevelUsage,
                           keyboardCollection: hasKeyboardCollection, isArray: isArray)
    }
}

/// When one input report arrived, as the HID stack stamped it. Deliberately nothing else about the report:
/// its bytes are never read, so the seam can't leak what was typed or clicked.
struct HIDReportTiming: Equatable, Sendable {
    var reportID: Int
    /// Mach absolute time, as `mach_absolute_time()` counts it; 0 when macOS gave none.
    var timestampTicks: UInt64
}

/// The small seam between Whisker and an opened HID device: describe what it declares, and read values from it.
///
/// It is read-only by construction (there is no way to write a report or property through it) and it opens
/// nothing exclusively. Battery status uses it today; input timing (#13) and extra-button discovery (#25) are
/// meant to reach devices through the same seam, so they get a fake for tests as well.
///
/// Everything but `readValues` and `observeReports`' `onReport` runs on the main thread. `runtimeID` identifies
/// one connection of one device: it is never reused, so a late result can be matched to the connection it was
/// asked of.
protocol HIDDeviceAccess: AnyObject {
    /// Remembers a device that appeared and gives it a runtime id.
    func register(_ device: IOHIDDevice) -> Int
    /// Forgets a device that went away.
    func forget(runtimeID: Int)
    /// The elements the device declares, in a stable order; nil when macOS describes nothing.
    func elements(of runtimeID: Int) -> [HIDElementDescription]?
    /// Reads the current value of the elements at `indexes` (into `elements(of:)`) away from the main thread
    /// and the event tap, then calls `completion` on the main thread with one value per index, nil for any that
    /// couldn't be read. Never calls back synchronously after the device was forgotten.
    func readValues(of runtimeID: Int, indexes: [Int], completion: @escaping ([Int?]) -> Void)
    /// Starts listening for the input reports of one interface, handing `onReport` only when each arrived (see
    /// `HIDReportTiming`), never their contents. The device is opened non-exclusively on its own connection, so
    /// whoever else listens to it, Whisker's device monitor included, is unaffected. Returns false when it can't
    /// be opened or is already being observed.
    ///
    /// `onReport` runs on a HID queue, not the main thread, once per report, at whatever rate the mouse sends:
    /// keep it tiny. `onEnd` runs once on the main thread, and only when the device is forgotten while still
    /// observed; `stopObservingReports` never calls it. Nothing is delivered once either has happened.
    func observeReports(of runtimeID: Int, onReport: @escaping @Sendable (HIDReportTiming) -> Void, onEnd: @escaping () -> Void) -> Bool
    /// Stops listening and releases the connection. Safe to repeat, and to call for a device never observed.
    func stopObservingReports(of runtimeID: Int)
    /// A bounded queue containing only the explicitly selected safe Button/Consumer elements. Main-thread
    /// callbacks include releases; no report callback, get-report request or keyboard stream is installed.
    func observeExtraButtonValues(of runtimeID: Int, indexes: [Int],
                                  onValue: @escaping (ExtraButtonObservation) -> Void, onEnd: @escaping () -> Void) -> Bool
    func stopObservingExtraButtonValues(of runtimeID: Int)
}

extension HIDDeviceAccess {
    // Defaults so an implementation that only describes and reads (a test fake, say) doesn't have to listen.
    func observeReports(of runtimeID: Int, onReport: @escaping @Sendable (HIDReportTiming) -> Void, onEnd: @escaping () -> Void) -> Bool { false }
    func stopObservingReports(of runtimeID: Int) {}
    func observeExtraButtonValues(of runtimeID: Int, indexes: [Int],
                                  onValue: @escaping (ExtraButtonObservation) -> Void, onEnd: @escaping () -> Void) -> Bool { false }
    func stopObservingExtraButtonValues(of runtimeID: Int) {}
}

/// IOKit's implementation. Reads go to a utility queue because reading a feature element can block.
final class IOKitHIDAccess: HIDDeviceAccess {
    private var devices: [Int: IOHIDDevice] = [:]
    private var elementCache: [Int: [IOHIDElement]] = [:]
    private var observations: [Int: (observation: HIDReportObservation, onEnd: () -> Void)] = [:]
    private var valueObservations: [Int: (observation: HIDExtraButtonObservation, onEnd: () -> Void)] = [:]
    private var nextID = 0
    private let queue = DispatchQueue(label: "io.github.mrashrhodes.whisker.hid-read", qos: .utility)

    func register(_ device: IOHIDDevice) -> Int {
        nextID += 1
        devices[nextID] = device
        return nextID
    }

    func forget(runtimeID: Int) {
        devices[runtimeID] = nil
        elementCache[runtimeID] = nil
        if let ended = valueObservations.removeValue(forKey: runtimeID) {
            ended.observation.stop()
            DispatchQueue.main.async(execute: ended.onEnd)
        }
        if let ended = observations.removeValue(forKey: runtimeID) {
            ended.observation.stop()
            DispatchQueue.main.async(execute: ended.onEnd)
        }
    }

    func elements(of runtimeID: Int) -> [HIDElementDescription]? {
        guard let device = devices[runtimeID],
              let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
        else { return nil }
        elementCache[runtimeID] = elements
        return elements.map(Self.describe)
    }

    static func describe(_ element: IOHIDElement) -> HIDElementDescription {
        let top = Self.topLevelCollection(of: element)
        return HIDElementDescription(
            kind: HIDElementKind(ioKitType: Int(IOHIDElementGetType(element).rawValue)),
            usagePage: Int(IOHIDElementGetUsagePage(element)), usage: Int(IOHIDElementGetUsage(element)),
            logicalMin: IOHIDElementGetLogicalMin(element), logicalMax: IOHIDElementGetLogicalMax(element),
            reportID: Int(IOHIDElementGetReportID(element)),
            topLevelUsagePage: top.page, topLevelUsage: top.usage,
            cookie: IOHIDElementGetCookie(element), hasKeyboardCollection: keyboardAncestor(of: element),
            isArray: IOHIDElementIsArray(element)
        )
    }

    private static func keyboardAncestor(of element: IOHIDElement) -> Bool {
        var current = element
        for _ in 0..<16 {
            let page = IOHIDElementGetUsagePage(current), usage = IOHIDElementGetUsage(current)
            if page == 0x07 || (page == 1 && [6, 7].contains(usage)) { return true }
            guard let parent = IOHIDElementGetParent(current) else { return false }
            current = parent
        }
        return true
    }

    /// The usage of the outermost collection an element belongs to. (0, 0) when the chain doesn't end in a
    /// collection or is implausibly deep, which reads as "not pointing" and so is never timed.
    private static func topLevelCollection(of element: IOHIDElement) -> (page: Int, usage: Int) {
        var current = element
        for _ in 0..<16 {
            guard let parent = IOHIDElementGetParent(current) else {
                guard IOHIDElementGetType(current) == kIOHIDElementTypeCollection else { return (0, 0) }
                return (Int(IOHIDElementGetUsagePage(current)), Int(IOHIDElementGetUsage(current)))
            }
            current = parent
        }
        return (0, 0)
    }

    func observeReports(of runtimeID: Int, onReport: @escaping @Sendable (HIDReportTiming) -> Void, onEnd: @escaping () -> Void) -> Bool {
        guard observations[runtimeID] == nil, let device = devices[runtimeID],
              let observation = HIDReportObservation(listeningTo: device, onReport: onReport)
        else { return false }
        observations[runtimeID] = (observation, onEnd)
        return true
    }

    func stopObservingReports(of runtimeID: Int) {
        observations.removeValue(forKey: runtimeID)?.observation.stop()
    }

    func observeExtraButtonValues(of runtimeID: Int, indexes: [Int],
                                  onValue: @escaping (ExtraButtonObservation) -> Void, onEnd: @escaping () -> Void) -> Bool {
        guard valueObservations[runtimeID] == nil, let device = devices[runtimeID],
              let cached = elementCache[runtimeID], !indexes.isEmpty,
              cached.count <= ExtraButtonDiscovery.maximumElements,
              indexes.allSatisfy({ cached.indices.contains($0) && Self.describe(cached[$0]).discoveryElement.observationAllowed }),
              let observation = HIDExtraButtonObservation(
                listeningTo: device, runtimeID: runtimeID,
                selected: indexes.map { ($0, Self.describe(cached[$0])) }, onValue: onValue, onEnd: onEnd)
        else { return false }
        valueObservations[runtimeID] = (observation, onEnd)
        return true
    }

    func stopObservingExtraButtonValues(of runtimeID: Int) {
        valueObservations.removeValue(forKey: runtimeID)?.observation.stop()
    }

    func readValues(of runtimeID: Int, indexes: [Int], completion: @escaping ([Int?]) -> Void) {
        guard let device = devices[runtimeID], let cached = elementCache[runtimeID] else {
            DispatchQueue.main.async { completion(indexes.map { _ -> Int? in nil }) }
            return
        }
        let targets: [IOHIDElement?] = indexes.map { cached.indices.contains($0) ? cached[$0] : nil }
        queue.async {
            let values: [Int?] = targets.map { element in
                guard let element else { return nil }
                // The API needs somewhere to put the value; it replaces this placeholder on success.
                let placeholder = IOHIDValueCreateWithIntegerValue(kCFAllocatorDefault, element, 0, 0)
                var value = Unmanaged<IOHIDValue>.passUnretained(placeholder)
                guard IOHIDDeviceGetValue(device, element, &value) == kIOReturnSuccess else { return nil }
                return withExtendedLifetime(placeholder) { IOHIDValueGetIntegerValue(value.takeUnretainedValue()) }
            }
            DispatchQueue.main.async { completion(values) }
        }
    }
}
