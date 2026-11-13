import SwiftUI
import WhiskerCore

/// What a gesture button does: an action for each way the mouse can be moved while the button is held, and one for
/// letting go without having moved far enough. Only actions a gesture can run are offered.
struct GestureEditor: View {
    @EnvironmentObject private var model: AppModel
    @Binding var gestures: ButtonGestures
    let settings: WhiskerSettings

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            ForEach(GestureDirection.allCases, id: \.self) { direction in
                GestureSlot(
                    title: direction.title, symbolName: direction.symbolName, settings: settings,
                    action: Binding(
                        get: { gestures.action(for: direction) },
                        set: { gestures.setAction($0, for: direction) }
                    )
                )
            }
            GestureSlot(title: "Tap (let go without moving)", symbolName: "cursorarrow.click", settings: settings, action: $gestures.tap)
            Stepper(
                "Picks a direction after \(gestures.threshold) units of movement",
                value: $gestures.threshold, in: ButtonGestures.thresholdRange, step: 10
            )
            .help("Measured in the movement units macOS reports for the mouse, roughly screen points, so a faster pointer speed needs less hand movement. Provisional: not yet verified on hardware.")
            if gestures.isEmpty {
                Label("Choose an action for at least one direction or for Tap. Until then the button keeps its normal behaviour.", systemImage: "info.circle")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            if !model.devices.canIdentifyDevices {
                Label("Input Monitoring is off, so Whisker cannot tell which mouse you pressed and the button keeps its normal behaviour.", systemImage: "exclamationmark.triangle")
                    .font(.footnote).foregroundStyle(.orange)
            }
            Text("Experimental. Hold the button, move the mouse and let go. The first movement that adds up to the distance above picks the direction, as long as it runs mostly one way (at least twice as far along one axis as across it); anything more diagonal does nothing. Letting go before that runs Tap. The pointer keeps moving, but the app under it sees no click or drag from this button.")
                .font(.footnote).foregroundStyle(.secondary)
            Text("Only the mouse you pressed counts, which needs Input Monitoring; another mouse moving never picks a direction. Switching app, losing the mouse, changing settings or turning Whisker off calls the gesture off. The distance and the rules are provisional and not yet verified on hardware.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

/// One direction, or the tap, of a gesture button: no action, or one a gesture can run.
private struct GestureSlot: View {
    let title: String
    let symbolName: String
    let settings: WhiskerSettings
    @Binding var action: Action?

    private static let sections = ActionMenu.sections { $0.defaultAction.allowedInGestures }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Picker(selection: Binding(
                get: { action.map(ActionChoice.init) },
                set: { choice in
                    guard choice != action.map(ActionChoice.init) else { return }
                    action = choice?.defaultAction
                }
            )) {
                Text("Nothing").tag(ActionChoice?.none)
                Divider()
                ActionChoiceItems(sections: Self.sections, tag: { ActionChoice?.some($0) })
            } label: {
                Label(title, systemImage: symbolName)
            }
            if let current = action {
                VStack(alignment: .leading, spacing: 4) {
                    ActionEditor(action: Binding(get: { current }, set: { action = $0 }), settings: settings, inGesture: true, showsKindPicker: false)
                    if let problem = WhiskerSettings.problem(withGestureAction: current) {
                        Label(problem, systemImage: "exclamationmark.triangle").font(.footnote).foregroundStyle(.orange)
                    }
                }
                .padding(.leading, 20)
            }
        }
    }
}
