import Foundation
import IOKit.hid
import os

/// Listens to one HID interface's input reports to note when each arrived, for input timing (#13).
///
/// It opens the interface itself, on a connection of its own, so closing it can never disturb the device
/// monitor's. The open is not exclusive: the monitor, the system and other apps keep receiving the interface's
/// input. Report contents are never read (the callback ignores the buffer macOS fills in), nothing is written
/// to the device and no property is set on it. Create and stop it on the main thread; only the report callback
/// runs elsewhere.
final class HIDReportObservation {
    /// A plain open: without the seize bit, so other clients keep receiving the device's input.
    static let openOptions = IOOptionBits(kIOHIDOptionsTypeNone)

    private let device: IOHIDDevice
    private let sink: HIDReportSink
    private var stopped = false

    /// Nil when the interface can't be opened: it has gone, or macOS refuses.
    init?(listeningTo monitored: IOHIDDevice, onReport: @escaping @Sendable (HIDReportTiming) -> Void) {
        let service = IOHIDDeviceGetService(monitored)
        guard service != IO_OBJECT_NULL, let own = IOHIDDeviceCreate(kCFAllocatorDefault, service),
              IOHIDDeviceOpen(own, Self.openOptions) == kIOReturnSuccess
        else { return nil }
        device = own
        let sink = HIDReportSink(onReport: onReport)
        self.sink = sink

        // macOS fills this in with each report. Nothing reads it, but it has to exist until the device is cancelled.
        let declared = IOHIDDeviceGetProperty(own, kIOHIDMaxInputReportSizeKey as CFString) as? Int ?? 0
        let length = min(max(declared, 64), 1 << 16)
        let buffer = UnsafeMutablePointer<UInt8>.allocate(capacity: length)
        buffer.initialize(repeating: 0, count: length)

        IOHIDDeviceSetDispatchQueue(own, DispatchQueue(label: "io.github.mrashrhodes.whisker.hid-report-timing", qos: .userInitiated))
        // Callbacks have to be registered before the device is activated.
        IOHIDDeviceRegisterInputReportWithTimeStampCallback(own, buffer, length, { context, result, _, type, reportID, _, _, timestamp in
            guard let context, result == kIOReturnSuccess, type == kIOHIDReportTypeInput else { return }
            Unmanaged<HIDReportSink>.fromOpaque(context).takeUnretainedValue().deliver(reportID: Int(reportID), timestampTicks: timestamp)
        }, Unmanaged.passUnretained(sink).toOpaque())
        // The device, the buffer and the sink are only released once macOS says nothing can call back any more.
        let retained = Unmanaged.passRetained(own)
        IOHIDDeviceSetCancelHandler(own) {
            withExtendedLifetime(sink) {}
            buffer.deallocate()
            retained.release()
        }
        IOHIDDeviceActivate(own)
    }

    /// Stops listening, closes the connection and drops anything still on its way. Safe to repeat.
    func stop() {
        guard !stopped else { return }
        stopped = true
        sink.stop()
        _ = IOHIDDeviceClose(device, Self.openOptions)
        IOHIDDeviceCancel(device)
    }

    deinit { stop() }
}

/// Hands each report's arrival to `onReport` until stopped. The lock only keeps a report that was already on
/// its way from reaching the receiver after `stop()`; the receiver closes its own gate as well.
private final class HIDReportSink: @unchecked Sendable {
    private let accepting = OSAllocatedUnfairLock(initialState: true)
    private let onReport: @Sendable (HIDReportTiming) -> Void

    init(onReport: @escaping @Sendable (HIDReportTiming) -> Void) {
        self.onReport = onReport
    }

    func stop() {
        accepting.withLock { $0 = false }
    }

    func deliver(reportID: Int, timestampTicks: UInt64) {
        guard accepting.withLock({ $0 }) else { return }
        onReport(HIDReportTiming(reportID: reportID, timestampTicks: timestampTicks))
    }
}
