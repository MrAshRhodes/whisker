import SwiftUI
import WhiskerCore

struct ExtraButtonDiscoverySheet: View {
    @ObservedObject var discovery: ExtraButtonDiscoveryController
    @Binding var settings: DeviceSettings
    let deviceID: String
    let deviceName: String
    let requestPermission: () -> Void
    let onClose: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Extra Button Discovery").font(.title2.bold())
            Text(deviceName).font(.headline)
            Text("Diagnostic only, not button remapping. Native actions still happen. No vendor adapter, model, firmware or transport has been verified on hardware.")
                .foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Toggle("Enable discovery for this mouse", isOn: $settings.extraButtons.discoveryEnabled)
            Text("Needs Input Monitoring even with one mouse. Only selected mouse Button/Consumer elements can be observed; keyboard interfaces remain metadata-only. Nothing is written to the device or saved from this session.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Text(discovery.message).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Inspect") { discovery.start(deviceID: deviceID) }
                    .disabled(!settings.extraButtons.discoveryEnabled || discovery.isInspecting || !settings.enabled)
                Button("Stop and Clear") { discovery.stop() }.disabled(!discovery.isInspecting)
                Button("Allow Input Monitoring…", action: requestPermission)
            }
            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    if discovery.isInspecting {
                        Text("\(discovery.keyboardInterfaces) related keyboard interfaces — metadata only")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    ForEach(discovery.interfaces) { interface in
                        VStack(alignment: .leading, spacing: 6) {
                            Text(interface.label).font(.headline)
                            ForEach(interface.collections, id: \.self) { collection in
                                Text("Collection: \(collection)").font(.caption.monospaced())
                            }
                            if interface.controls.isEmpty {
                                Text("No Button/Consumer controls described. This is not evidence that no extra controls exist.")
                                    .foregroundStyle(.secondary)
                            }
                            ForEach(interface.controls) { control in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text("\(control.identity.namespace):\(control.identity.control)")
                                        .font(.caption.monospaced()).textSelection(.enabled)
                                    Text(control.status.label).font(.callout).monospacedDigit()
                                }
                                .accessibilityElement(children: .combine)
                            }
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            Text("Primary-button values, keyboard/keypad streams, non-binary or ambiguous controls are never observed. Stage 2 vendor remapping is unavailable.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            HStack { Spacer(); Button("Done", action: onClose).keyboardShortcut(.cancelAction) }
        }
        .padding(24).frame(width: 650, height: 640)
        .onAppear { discovery.stop(reason: "Off. Enable discovery, then choose Inspect.") }
        .onDisappear { discovery.stop() }
        .onChange(of: settings.extraButtons.discoveryEnabled) { _, _ in discovery.stop() }
    }
}
