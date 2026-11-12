import Foundation
import IOKit.hid
import WhiskerCore

/// A separate non-exclusive connection with a fixed-depth, element-filtered queue. Unlike a device-wide value
/// callback, the queue never subscribes to keyboard elements, including those in composite mouse interfaces.
final class HIDExtraButtonObservation {
    private let device: IOHIDDevice
    private let queue: IOHIDQueue
    private let sink: ExtraButtonValueSink
    private var stopped = false

    init?(listeningTo monitored: IOHIDDevice, runtimeID: Int, selected: [(Int, HIDElementDescription)],
          onValue: @escaping (ExtraButtonObservation) -> Void, onEnd: @escaping () -> Void) {
        let service = IOHIDDeviceGetService(monitored)
        guard service != IO_OBJECT_NULL, let own = IOHIDDeviceCreate(kCFAllocatorDefault, service),
              IOHIDDeviceOpen(own, IOOptionBits(kIOHIDOptionsTypeNone)) == kIOReturnSuccess else { return nil }
        guard let queue = IOHIDQueueCreate(kCFAllocatorDefault, own, 64, IOOptionBits(kIOHIDOptionsTypeNone)),
              let elements = IOHIDDeviceCopyMatchingElements(own, nil, 0) as? [IOHIDElement],
              elements.count <= ExtraButtonDiscovery.maximumElements else {
            IOHIDDeviceClose(own, 0)
            return nil
        }
        var indexes: [UInt32: Int] = [:]
        for (index, description) in selected {
            let matches = elements.filter { IOKitHIDAccess.describe($0) == description }
            guard description.discoveryElement.observationAllowed, matches.count == 1,
                  indexes[description.cookie] == nil else {
                IOHIDDeviceClose(own, 0)
                return nil
            }
            indexes[description.cookie] = index
            IOHIDQueueAddElement(queue, matches[0])
        }
        device = own
        self.queue = queue
        sink = ExtraButtonValueSink(queue: queue, runtimeID: runtimeID, indexes: indexes, onValue: onValue, onEnd: onEnd)
        let retained = Unmanaged.passRetained(sink)
        IOHIDQueueSetDispatchQueue(queue, .main)
        IOHIDQueueRegisterValueAvailableCallback(queue, { context, result, _ in
            guard let context else { return }
            Unmanaged<ExtraButtonValueSink>.fromOpaque(context).takeUnretainedValue().drain(result: result)
        }, retained.toOpaque())
        IOHIDQueueSetCancelHandler(queue) {
            withExtendedLifetime(own) {}
            retained.release()
        }
        IOHIDQueueActivate(queue)
    }

    func stop() {
        guard !stopped else { return }
        stopped = true
        sink.accepting = false
        IOHIDQueueCancel(queue)
        IOHIDDeviceClose(device, 0)
    }

    deinit { stop() }
}

private final class ExtraButtonValueSink {
    var accepting = true
    let queue: IOHIDQueue
    let runtimeID: Int
    let indexes: [UInt32: Int]
    let onValue: (ExtraButtonObservation) -> Void
    let onEnd: () -> Void

    init(queue: IOHIDQueue, runtimeID: Int, indexes: [UInt32: Int],
         onValue: @escaping (ExtraButtonObservation) -> Void, onEnd: @escaping () -> Void) {
        self.queue = queue
        self.runtimeID = runtimeID
        self.indexes = indexes
        self.onValue = onValue
        self.onEnd = onEnd
    }

    func drain(result: IOReturn) {
        guard accepting else { return }
        guard result == kIOReturnSuccess else { return end() }
        for _ in 0..<64 {
            guard accepting, let value = IOHIDQueueCopyNextValueWithTimeout(queue, 0) else { return }
            let element = IOHIDValueGetElement(value)
            guard let index = indexes[IOHIDElementGetCookie(element)],
                  IOHIDValueGetLength(value) <= MemoryLayout<Int>.size else { continue }
            onValue(ExtraButtonObservation(runtimeID: runtimeID, elementIndex: index,
                                           value: IOHIDValueGetIntegerValue(value),
                                           timestamp: IOHIDValueGetTimeStamp(value)))
        }
        // Do not monopolise the main queue if a device streams values continuously. Losing samples must not
        // look like reliable state: stop, discard the diagnostic and require another explicit start.
        if IOHIDQueueCopyNextValueWithTimeout(queue, 0) != nil { end() }
    }

    private func end() {
        accepting = false
        onEnd()
    }
}
