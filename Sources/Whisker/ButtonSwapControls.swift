import AppKit
import SwiftUI
import WhiskerCore

/// The switch that makes one mouse's primary and secondary buttons trade places, what stands in its way, and the
/// trial that puts the buttons back unless they are kept. It is shown in the mouse's Buttons settings and in Devices.
struct ButtonSwapControls: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var devices: DeviceMonitor
    let id: String
    let name: String

    var body: some View {
        let settings = store.settings
        let isOn = settings.devices[id]?.swapPrimarySecondary ?? false
        let mayTurnOn = settings.general.allowPrimaryButtonRemap
        let status = ButtonSwap.status(for: id, in: settings, canIdentifyPresses: devices.canIdentifyDevices)
        VStack(alignment: .leading, spacing: 6) {
            Toggle("Swap primary and secondary buttons", isOn: Binding(get: { isOn }, set: { turn(on: $0) }))
                .disabled(!isOn && !mayTurnOn)
                .accessibilityLabel("Swap primary and secondary buttons on \(name)")
                .accessibilityHint(!isOn && !mayTurnOn ? "Needs Allow remapping the primary button, which is off in General." : "")
            Text("Applies to this mouse only. Other buttons and clicks made with a modifier key held are not changed. How it combines with the secondary-click side in System Settings has not yet been verified, and apps that read the mouse directly may ignore the swap.")
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            if !isOn && !mayTurnOn {
                notice("Switch on “Allow remapping the primary button” in General first. Whisker never switches it on for you.") {
                    Button("Open General") { model.selectedPane = .general }
                }
            } else {
                statusView(status)
            }
            if let deadline = model.swapTrials[id] { trial(until: deadline) }
        }
    }

    @ViewBuilder private func statusView(_ status: ButtonSwapStatus) -> some View {
        switch status.phase {
        case .off:
            EmptyView()
        case .active:
            if status.mappedBy.isEmpty {
                Label("Swapping now.", systemImage: "arrow.left.arrow.right")
                    .font(.footnote).foregroundStyle(.secondary)
            } else {
                notice(
                    "Swapping, except where a profile maps the plain Primary Button or Secondary Button itself: \(Self.list(status.mappedBy)). A mapping like that says exactly what the button does, so the swap leaves both buttons to it there.",
                    warning: false
                )
            }
        case .inactive(let reason):
            inactive(reason, mappedBy: status.mappedBy)
        }
    }

    @ViewBuilder private func inactive(_ reason: ButtonSwapStatus.Reason, mappedBy: [String]) -> some View {
        switch reason {
        case .whiskerOff:
            notice("Not swapping while Whisker is switched off.")
        case .mouseOff:
            notice("Not swapping while this mouse is switched off in Devices.")
        case .primaryRemapNotAllowed:
            notice("Not swapping while “Allow remapping the primary button” is off in General. Switching it on again resumes the swap.") {
                Button("Open General") { model.selectedPane = .general }
            }
        case .cannotIdentifyPresses:
            notice("Not swapping because Whisker cannot tell which mouse you pressed. That needs Input Monitoring, and it keeps a trackpad or another mouse from being swapped by mistake.") {
                switch devices.identification {
                case .notAllowed: Button("Allow Input Monitoring…") { devices.requestIdentification() }
                case .couldNotListen: Button("Try Again") { devices.requestIdentification() }
                case .listening: EmptyView()
                }
            }
        case .buttonsMappedEverywhere:
            notice("Not swapping: every profile that applies to this mouse maps the plain Primary Button or Secondary Button itself (\(Self.list(mappedBy))), and a mapping like that wins over the swap.")
        }
    }

    private func notice(_ text: String, warning: Bool = true) -> some View {
        notice(text, warning: warning) { EmptyView() }
    }

    private func notice<Actions: View>(_ text: String, warning: Bool = true, @ViewBuilder actions: () -> Actions) -> some View {
        HStack(alignment: .firstTextBaseline) {
            Label(text, systemImage: warning ? "exclamationmark.triangle" : "info.circle")
                .font(.footnote).foregroundStyle(warning ? Color.orange : Color.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Spacer()
            actions()
        }
    }

    private func trial(until deadline: Date) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("On trial: switches itself off \(deadline, style: .relative) from now unless you keep it. Use the button that now acts as primary to click Keep, or press Return. Escape switches it off now.")
                .font(.footnote).fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("Keep") { model.confirmSwap(device: id) }
                    .keyboardShortcut(.defaultAction)
                    .accessibilityLabel("Keep swapped buttons on \(name)")
                Button("Switch Off") { model.revertSwap(device: id) }
                    .keyboardShortcut(.cancelAction)
                    .accessibilityLabel("Switch off swapped buttons on \(name)")
            }
        }
    }

    private func turn(on: Bool) {
        model.setSwapPrimarySecondary(device: id, name: name, on: on)
        guard on, model.swapTrials[id] != nil else { return }
        Self.announce("Buttons swapped on \(name) as a trial. Press Return to keep them or Escape to switch the swap off. It switches itself off in \(Int(model.swapTrialDuration)) seconds.")
    }

    private static func list(_ names: [String]) -> String {
        ListFormatter.localizedString(byJoining: names)
    }

    /// Tells VoiceOver about the trial, which would otherwise only appear as new text further down.
    private static func announce(_ message: String) {
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )
    }
}
