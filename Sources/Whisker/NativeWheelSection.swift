import SwiftUI
import WhiskerCore

/// Native wheel settings for each connected mouse, shown in the Scrolling pane. Nothing is offered unless
/// Whisker can read the mouse's current value and put it back.
struct NativeWheelSection: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var devices: DeviceMonitor
    @ObservedObject var wheel: WheelController

    var body: some View {
        let mice = devices.devices.filter { !$0.isExcluded }
        Section {
            Text("Ask a mouse’s own driver to change its wheel speed or acceleration instead of Whisker rewriting scroll events. It is off until you turn it on for a mouse. Some mice ignore these settings, and Whisker can’t check whether the wheel really scrolls differently; if it doesn’t, switch it off. Not yet verified on hardware.")
                .font(.footnote).foregroundStyle(.secondary)
            if mice.isEmpty {
                Text("No mouse is connected.").foregroundStyle(.secondary)
            }
        } header: {
            Text("Native wheel settings")
        }
        ForEach(mice) { device in
            deviceSection(device)
        }
    }

    @ViewBuilder private func deviceSection(_ device: ConnectedDevice) -> some View {
        let binding = model.deviceBinding(device.id, name: device.name)
        let native = binding.wheel.native
        let enabled = native.wrappedValue?.enabled ?? false
        Section(device.name) {
            Toggle("Use this mouse’s own wheel settings", isOn: Binding(
                get: { enabled },
                set: { on in
                    if on {
                        var settings = native.wrappedValue ?? NativeWheelSettings()
                        settings.enabled = true
                        native.wrappedValue = settings
                    } else {
                        native.wrappedValue?.enabled = false
                    }
                }
            ))
            if enabled {
                controlRow("Speed", control: .speed, device: device.id, value: Binding(
                    get: { native.wrappedValue?.speed },
                    set: { native.wrappedValue?.speed = $0 }
                ), range: NativeWheelMath.speedRange, start: 1, format: { "×" + $0.formatted(.number.precision(.fractionLength(0...2))) })
                controlRow("Acceleration", control: .acceleration, device: device.id, value: Binding(
                    get: { native.wrappedValue?.acceleration },
                    set: { native.wrappedValue?.acceleration = $0 }
                ), range: NativeWheelMath.accelerationRange, start: 0.5, format: { $0.formatted(.number.precision(.fractionLength(0...2))) })
            }
            modeRow(device.id)
            if wheel.restoreFailures.contains(device.id) {
                Label("Whisker couldn’t put this mouse’s original wheel values back. It keeps them on record and tries again.", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
            }
            HStack {
                Button("Restore system values") {
                    native.wrappedValue?.enabled = false
                    wheel.restoreLeftovers(connected: devices.devices)
                }
                .disabled(!enabled && !wheel.activeDevices.contains(device.id) && !wheel.restoreFailures.contains(device.id))
                Text("Switches native settings off and puts back the values the mouse had.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
    }

    @ViewBuilder private func controlRow(
        _ title: String, control: NativeWheelControl, device: String, value: Binding<Double?>,
        range: ClosedRange<Double>, start: Double, format: @escaping (Double) -> String
    ) -> some View {
        let status = wheel.status(of: control, device: device)
        let usable = status == .available || status == .active || { if case .failed = status { return true } else { return false } }()
        VStack(alignment: .leading, spacing: 4) {
            Toggle(title, isOn: Binding(
                get: { value.wrappedValue != nil },
                set: { value.wrappedValue = $0 ? start : nil }
            ))
            .disabled(!usable && value.wrappedValue == nil)
            if let current = value.wrappedValue {
                HStack {
                    Slider(value: Binding(get: { current }, set: { value.wrappedValue = $0 }), in: range)
                    Text(format(current)).monospacedDigit().frame(width: 50, alignment: .trailing)
                }
            }
            Text(Self.describe(status)).font(.footnote).foregroundStyle(Self.isProblem(status) ? .orange : .secondary)
        }
    }

    @ViewBuilder private func modeRow(_ id: String) -> some View {
        let scroll = store.settings.resolvedProfile(device: id, app: nil).scroll
        let mode = ScrollModeResolver.mode(scroll: scroll, nativeActive: wheel.activeDevices.contains(id))
        switch mode {
        case .native:
            Label("Native mode is active. Lines per notch and acceleration are paused for this mouse; your saved values are kept.", systemImage: "gearshape.2")
        case .software:
            Label("Software scrolling is active: Whisker rewrites this mouse’s scroll events.", systemImage: "slider.horizontal.3")
        case .system:
            Label("macOS decides how far this mouse scrolls.", systemImage: "gearshape")
        }
    }

    static func describe(_ status: WheelControlStatus?) -> String {
        switch status {
        case nil: return "Not checked yet."
        case .available: return "Available. Whisker can read and restore this value."
        case .active: return "Applied. Whether the mouse responds can’t be checked."
        case .unavailable(let issue): return "Unavailable. " + issue.message
        case .failed(let issue): return "Failed. " + issue.message
        }
    }

    static func isProblem(_ status: WheelControlStatus?) -> Bool {
        switch status {
        case .failed: return true
        default: return false
        }
    }
}
