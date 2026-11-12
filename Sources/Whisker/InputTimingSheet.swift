import AppKit
import SwiftUI
import WhiskerCore

/// Which mouse the Input Timing sheet is open for. Held by the Devices pane, which presents the sheet.
@MainActor
final class InputTimingSheetState: ObservableObject {
    @Published var isPresented = false
    @Published private(set) var deviceID = ""
    @Published private(set) var deviceName = ""

    func present(deviceID: String, name: String) {
        self.deviceID = deviceID
        deviceName = name
        isPresented = true
    }
}

/// A short, opt-in count of when one mouse's HID reports reach Whisker. Nothing is read until Start, and
/// everything is discarded when the sheet closes. What the numbers mean and don't mean is `WhiskerCore`'s wording.
struct InputTimingSheet: View {
    @ObservedObject var timing: InputTimingController
    let deviceID: String
    let deviceName: String
    let onClose: () -> Void

    private let duration = InputTimingDefaults.sampleDuration

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 2) {
                Text("Input Timing").font(.title3.bold())
                Text(deviceName).font(.subheadline).foregroundStyle(.secondary).lineLimit(2)
            }
            Text("Counts how often this mouse's reports reach Whisker over about \(Int(duration)) seconds. It's a diagnostic, not a speed test.")
                .font(.callout).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            Divider()
            content
            Divider()
            Text(InputTimingWording.caveat)
                .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            buttons
        }
        .padding(20)
        .frame(width: 520)
        .onAppear { timing.sheetOpened() }
        .onDisappear { timing.sheetClosed() }
        // Allowing Input Monitoring happens in System Settings; coming back is how this finds out.
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            timing.prepare()
        }
    }

    // MARK: States

    @ViewBuilder private var content: some View {
        switch timing.state {
        case .idle:
            VStack(alignment: .leading, spacing: 8) {
                Text("Press Start, then move the mouse in steady circles for about \(Int(duration)) seconds. Don't click or scroll.")
                Text("While sampling, Whisker uses Input Monitoring to receive this mouse's reports. It records only when each report arrives, not what is in it, and discards everything when you close this window.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .needsPermission:
            VStack(alignment: .leading, spacing: 8) {
                Label("Input Monitoring is off.", systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Whisker needs it to receive this mouse's reports for the sample, and only while you are sampling. After allowing it, come back to this window.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        case .unavailable(let reason):
            Label(reason.text, systemImage: "exclamationmark.triangle")
                .foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
        case .sampling(let elapsed, let reportCount):
            sampling(elapsed: elapsed, reportCount: reportCount)
        case .finished(let result):
            finished(result)
        case .interrupted(let reason):
            VStack(alignment: .leading, spacing: 6) {
                Label(reason.text, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                Text("Nothing was kept.").font(.footnote).foregroundStyle(.secondary)
            }
            .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func sampling(elapsed: TimeInterval, reportCount: Int) -> some View {
        let seconds = min(max(elapsed, 0), duration)
        return VStack(alignment: .leading, spacing: 8) {
            Text("Move the mouse in steady circles now. Don't click or scroll.")
            ProgressView(value: seconds, total: duration)
                .accessibilityLabel("Sampling progress")
                .accessibilityValue("\(Int(seconds)) of \(Int(duration)) seconds")
            HStack {
                Text("\(Int(seconds)) of \(Int(duration)) seconds")
                Spacer()
                Text(reportCount == 1 ? "1 report so far" : "\(reportCount) reports so far")
            }
            .font(.footnote.monospacedDigit()).foregroundStyle(.secondary)
        }
    }

    private func finished(_ result: InputTimingCaptureResult) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Sampled for \(Int(result.duration.rounded())) seconds.").font(.callout).foregroundStyle(.secondary)
            ForEach(Array(result.streams.enumerated()), id: \.offset) { _, stream in
                GroupBox {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(InputTimingPresentation.figures(for: stream.summary).enumerated()), id: \.offset) { _, line in
                            Text(line)
                        }
                        ForEach(Array(InputTimingPresentation.notes(for: stream.summary).enumerated()), id: \.offset) { _, line in
                            Text(line).font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                } label: {
                    Text(stream.label).font(.headline)
                }
                .accessibilityElement(children: .combine)
            }
            if result.streams.count > 1 {
                Text("Each interface and report is shown apart. Their figures aren't added together.")
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    // MARK: Buttons

    @ViewBuilder private var buttons: some View {
        HStack {
            switch timing.state {
            case .idle:
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Start") { timing.start(deviceID: deviceID) }.keyboardShortcut(.defaultAction)
            case .needsPermission:
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Allow Input Monitoring…") { timing.requestPermission() }.keyboardShortcut(.defaultAction)
            case .unavailable, .interrupted:
                Button("Close", action: onClose).keyboardShortcut(.cancelAction)
                Spacer()
                Button("Try Again") { timing.start(deviceID: deviceID) }.keyboardShortcut(.defaultAction)
            case .sampling:
                Button("Cancel") { timing.cancel() }.keyboardShortcut(.cancelAction)
                Spacer()
            case .finished:
                Button("Run Again") { timing.start(deviceID: deviceID) }
                Spacer()
                Button("Done", action: onClose).keyboardShortcut(.defaultAction)
            }
        }
    }
}
