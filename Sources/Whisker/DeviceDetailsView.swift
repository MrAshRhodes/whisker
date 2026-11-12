import SwiftUI
import WhiskerCore

/// Whether one device's details are open and whether its serial number is showing. Closing the details hides
/// the serial number again, so it's only on screen while someone is looking at it.
final class DeviceDetailsState: ObservableObject {
    @Published private(set) var isOpen = false
    @Published private(set) var showsSerial = false

    func setOpen(_ open: Bool) {
        isOpen = open
        if !open { showsSerial = false }
    }

    func toggleSerial() {
        showsSerial.toggle()
    }
}

/// A read-only "Details" disclosure for a device in the Devices pane: who it is, what it reports and how sure
/// Whisker is about which clicks come from it. Opening it changes no setting and never asks for Input
/// Monitoring; `onOpen` is for re-reading what the device reports.
struct DeviceDetailsDisclosure: View {
    let details: DeviceDetails
    var onOpen: () -> Void = {}
    // `@State` needs the SwiftUI macro plugin, which Command Line Tools builds lack.
    @StateObject private var state = DeviceDetailsState()

    var body: some View {
        DisclosureGroup(isExpanded: Binding(
            get: { state.isOpen },
            set: { open in
                state.setOpen(open)
                if open { onOpen() }
            }
        )) {
            DeviceDetailsRows(details: details, state: state)
                .padding(.top, 4)
        } label: {
            Text("Details").accessibilityLabel("Details for \(details.name)")
        }
    }
}

/// What a device's details say, one labelled row each. Every state is spelled out in words, never by colour alone.
struct DeviceDetailsRows: View {
    let details: DeviceDetails
    @ObservedObject var state: DeviceDetailsState

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            row("Product name", details.productNameText)
            row("Connection", details.transportText)
            row("Vendor ID", details.vendorIDText)
            row("Product ID", details.productIDText)
            serialRow
            row("Input Monitoring", details.identification.title)
            row("Attribution", details.attribution.title)
            footnote(details.attribution.explanation)
            row("Reported buttons", details.controlsButtonsText)
            row("Reported wheels", details.controlsWheelsText)
            footnote(DeviceDetails.controlsCaveat)
            ForEach(details.notes, id: \.self) { footnote($0.text) }
        }
    }

    private var serialRow: some View {
        LabeledContent("Serial number") {
            HStack(spacing: 8) {
                Text(state.showsSerial ? (details.serialValue ?? details.serialText) : details.serialText)
                    .textSelection(.enabled)
                if details.serialValue != nil {
                    Button(state.showsSerial ? "Hide" : "Show") { state.toggleSerial() }
                        .accessibilityLabel(state.showsSerial ? "Hide serial number" : "Show serial number")
                }
            }
        }
    }

    private func row(_ title: String, _ value: String) -> some View {
        LabeledContent(title) { Text(value).multilineTextAlignment(.trailing) }
            .accessibilityElement(children: .combine)
    }

    private func footnote(_ text: String) -> some View {
        Text(text).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
    }
}
