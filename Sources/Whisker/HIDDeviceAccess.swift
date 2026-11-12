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
}

/// The small seam between Whisker and an opened HID device: describe what it declares, and read values from it.
///
/// It is read-only by construction (there is no way to write a report or property through it) and it opens
/// nothing exclusively. Battery status uses it today; input timing (#13) and extra-button discovery (#25) are
/// meant to reach devices through the same seam, so they get a fake for tests as well.
///
/// Everything but `readValues` runs on the main thread. `runtimeID` identifies one connection of one device: it
/// is never reused, so a late result can be matched to the connection it was asked of.
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
}

/// IOKit's implementation. Reads go to a utility queue because reading a feature element can block.
final class IOKitHIDAccess: HIDDeviceAccess {
    private var devices: [Int: IOHIDDevice] = [:]
    private var elementCache: [Int: [IOHIDElement]] = [:]
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
    }

    func elements(of runtimeID: Int) -> [HIDElementDescription]? {
        guard let device = devices[runtimeID],
              let elements = IOHIDDeviceCopyMatchingElements(device, nil, IOOptionBits(kIOHIDOptionsTypeNone)) as? [IOHIDElement]
        else { return nil }
        elementCache[runtimeID] = elements
        return elements.map {
            HIDElementDescription(
                kind: HIDElementKind(ioKitType: Int(IOHIDElementGetType($0).rawValue)),
                usagePage: Int(IOHIDElementGetUsagePage($0)), usage: Int(IOHIDElementGetUsage($0)),
                logicalMin: IOHIDElementGetLogicalMin($0), logicalMax: IOHIDElementGetLogicalMax($0)
            )
        }
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
