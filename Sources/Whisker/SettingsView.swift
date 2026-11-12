import AppKit
import SwiftUI
import UniformTypeIdentifiers
import WhiskerCore

struct SettingsView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        NavigationSplitView {
            List(SettingsPane.allCases, selection: Binding(
                get: { Optional(model.selectedPane) },
                set: { if let pane = $0 { model.selectedPane = pane } }
            )) { pane in
                Label(pane.title, systemImage: pane.symbolName).tag(pane)
            }
            .navigationSplitViewColumnWidth(min: 170, ideal: 180, max: 220)
        } detail: {
            detail
                .frame(minWidth: 480, minHeight: 420)
                .navigationTitle(model.selectedPane.title)
        }
    }

    @ViewBuilder private var detail: some View {
        switch model.selectedPane {
        case .general: GeneralPane(store: model.store, permission: model.permission, loginItem: model.loginItem)
        case .buttons: ButtonsPane(store: model.store)
        case .scrolling: ScrollingPane(store: model.store)
        case .pointer: PointerPane(store: model.store, devices: model.devices, pointer: model.pointer)
        case .applications: ApplicationsPane(store: model.store, pointer: model.pointer)
        case .devices: DevicesPane(store: model.store, devices: model.devices)
        case .updates: Form { Section { UpdatesSection() } }.formStyle(.grouped)
        case .about: AboutPane()
        }
    }
}

// MARK: - General

struct GeneralPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var permission: AccessibilityPermission
    @ObservedObject var loginItem: LoginItemController
    @StateObject private var messages = MessageState()

    var body: some View {
        Form {
            if let reason = store.readOnlyReason {
                Section { Label(reason, systemImage: "exclamationmark.triangle").foregroundStyle(.orange) }
            }
            if !store.loadIssues.isEmpty {
                Section {
                    VStack(alignment: .leading, spacing: 4) {
                        Label("Some settings were fixed when Whisker started:", systemImage: "wrench.and.screwdriver")
                        ForEach(Array(store.loadIssues.prefix(6).enumerated()), id: \.offset) { _, issue in
                            Text("• \(issue.message)").font(.footnote).foregroundStyle(.secondary)
                        }
                        Button("Dismiss") { store.dismissLoadIssues() }
                    }
                }
            }
            Section {
                Toggle("Enable Whisker", isOn: Binding(get: { store.settings.general.enabled }, set: { model.setEnabled($0) }))
                Toggle("Show Whisker in the menu bar", isOn: $store.settings.general.showMenuBarIcon)
                if !store.settings.general.showMenuBarIcon {
                    Text("Open Whisker again from Finder or Spotlight to get back to these settings.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                Toggle("Open at login", isOn: Binding(get: { loginItem.isEnabled }, set: { loginItem.setEnabled($0) }))
                if loginItem.needsApproval {
                    HStack {
                        Text("Allow Whisker in Login Items to finish turning this on.").font(.footnote)
                        Button("Open Login Items") { loginItem.openLoginItemsSettings() }
                    }
                }
                if let error = loginItem.lastError {
                    Text(error).font(.footnote).foregroundStyle(.red)
                }
            }
            Section("Permission") {
                HStack {
                    Image(systemName: permission.isTrusted ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundStyle(permission.isTrusted ? .green : .orange)
                    Text(permission.isTrusted ? "Whisker has Accessibility access." : "Whisker needs Accessibility access to change what your mouse does.")
                    Spacer()
                    if !permission.isTrusted {
                        Button("Open Accessibility Settings") { permission.openSystemSettings() }
                    }
                }
            }
            Section("Safety") {
                Toggle("Allow remapping the primary button", isOn: $store.settings.general.allowPrimaryButtonRemap)
                Text("When off, the primary button always clicks unless you hold a modifier key, so a mapping can never leave you without a working click.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("Settings File") {
                HStack {
                    Button("Import…") { importSettings() }
                    Button("Export…") { exportSettings() }
                    Spacer()
                    Button("Reset to Defaults…", role: .destructive) { resetSettings() }
                }
                if let message = messages.text {
                    Text(message).font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .formStyle(.grouped)
        .onAppear {
            permission.refresh()
            loginItem.refresh()
        }
    }

    private func importSettings() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.importSettings(from: url)
            messages.text = "Imported \(url.lastPathComponent)."
        } catch {
            messages.text = (error as? LocalizedError)?.errorDescription ?? error.localizedDescription
        }
    }

    private func exportSettings() {
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = "Whisker Settings.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try store.exportSettings(to: url)
            messages.text = "Exported to \(url.lastPathComponent)."
        } catch {
            messages.text = error.localizedDescription
        }
    }

    private func resetSettings() {
        let alert = NSAlert()
        alert.messageText = "Reset all Whisker settings?"
        alert.informativeText = "Every mapping, profile and device setting goes back to how it was when you first installed Whisker."
        alert.addButton(withTitle: "Reset")
        alert.addButton(withTitle: "Cancel")
        alert.buttons.first?.hasDestructiveAction = true
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        store.resetToDefaults()
        messages.text = "Settings reset."
    }
}

final class MessageState: ObservableObject {
    @Published var text: String?
}

// MARK: - Profile picker

/// Picks which profile the Buttons and Scrolling panes edit.
struct ProfilePicker: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore

    var body: some View {
        Picker("Profile", selection: Binding(
            get: { store.settings.profile(id: model.selectedProfileID) == nil ? Profile.defaultID : model.selectedProfileID },
            set: { model.selectedProfileID = $0 }
        )) {
            ForEach(store.settings.profiles) { profile in
                Text(Self.title(profile, in: store.settings)).tag(profile.id)
            }
        }
    }

    static func title(_ profile: Profile, in settings: WhiskerSettings) -> String {
        if profile.isDefault { return "Default (all apps and mice)" }
        return profile.name
    }
}

// MARK: - Scrolling

struct ScrollingPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore

    private static let modifierChoices: [(String, ModifierSet)] = [
        ("Off", []), ("Shift ⇧", .shift), ("Option ⌥", .option), ("Control ⌃", .control), ("Command ⌘", .command),
    ]

    var body: some View {
        let profile = model.profileBinding(model.selectedProfileID)
        let resolved = store.settings.resolvedProfile(id: profile.wrappedValue.id).scroll
        Form {
            Section {
                ProfilePicker(store: store)
            }
            if profile.wrappedValue.scroll == nil, !profile.wrappedValue.isDefault {
                Section {
                    HStack {
                        Text("This profile uses the scrolling settings it inherits.")
                        Spacer()
                        Button("Customise") { profile.wrappedValue.scroll = resolved }
                    }
                }
            } else {
                let scroll = Binding(
                    get: { profile.wrappedValue.scroll ?? .system },
                    set: { profile.wrappedValue.scroll = $0 }
                )
                Section("Wheel") {
                    Toggle("Set how far each notch scrolls", isOn: Binding(
                        get: { scroll.wrappedValue.linesPerNotch != nil },
                        set: { scroll.wrappedValue.linesPerNotch = $0 ? 3 : nil }
                    ))
                    if let lines = scroll.wrappedValue.linesPerNotch {
                        Stepper("\(lines) \(lines == 1 ? "line" : "lines") per notch", value: Binding(
                            get: { lines },
                            set: { scroll.wrappedValue.linesPerNotch = $0 }
                        ), in: ScrollMath.linesRange)
                        LabeledContent("Speed up quick spins") {
                            Slider(value: scroll.acceleration, in: ScrollMath.accelerationRange) {
                                EmptyView()
                            } minimumValueLabel: { Text("Off") } maximumValueLabel: { Text("Most") }
                        }
                    } else {
                        Text("macOS decides how far the wheel scrolls (System Settings › Mouse).")
                            .font(.footnote).foregroundStyle(.secondary)
                    }
                    Picker("Scroll sideways while holding", selection: Binding(
                        get: { scroll.wrappedValue.horizontalModifier },
                        set: { scroll.wrappedValue.horizontalModifier = $0 }
                    )) {
                        ForEach(Self.modifierChoices, id: \.1.rawValue) { Text($0.0).tag($0.1) }
                    }
                }
                speedSection(scroll)
                if !profile.wrappedValue.isDefault {
                    Section {
                        Button("Use Inherited Settings") { profile.wrappedValue.scroll = nil }
                    }
                }
            }
            Section {
                Text("Reverse the wheel direction for a single mouse in Devices. Trackpads are never changed.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    // MARK: Speed while holding keys

    private static let speedPresets: [Double] = [0.25, 0.5, 2, 3, 4, 5, 8]

    /// The presets, plus the saved speed when it isn't one of them, so the picker always has a selection.
    private static func speedChoices(including current: Double) -> [Double] {
        speedPresets.contains(current) ? speedPresets : (speedPresets + [current]).sorted()
    }

    private static func speedTitle(_ speed: Double) -> String {
        "×" + speed.formatted()
    }

    private static func axesTitle(_ axes: ScalingAxes) -> String {
        switch axes {
        case .both: "Both directions"
        case .vertical: "Up and down only"
        case .horizontal: "Left and right only"
        }
    }

    /// Half speed on a key the sideways setting isn't using.
    private static func startingScaling(avoiding sideways: ModifierSet) -> ModifierScaling {
        let key = [ModifierSet.option, .control, .shift, .command].first { $0 != sideways.withoutFunction } ?? .option
        return ModifierScaling(modifiers: key, multiplier: 0.5)
    }

    @ViewBuilder private func speedSection(_ scroll: Binding<ScrollSettings>) -> some View {
        let scaling = scroll.wrappedValue.modifierScaling
        Section("Speed while holding keys") {
            Toggle("Scroll faster or slower while holding keys", isOn: Binding(
                get: { scroll.wrappedValue.modifierScaling != nil },
                set: { scroll.wrappedValue.modifierScaling = $0 ? Self.startingScaling(avoiding: scroll.wrappedValue.horizontalModifier) : nil }
            ))
            if let scaling {
                ModifierToggles(modifiers: Binding(
                    get: { scaling.modifiers },
                    set: { scroll.wrappedValue.modifierScaling?.modifiers = $0 }
                ))
                Picker("Speed", selection: Binding(
                    get: { scaling.multiplier },
                    set: { scroll.wrappedValue.modifierScaling?.multiplier = $0 }
                )) {
                    ForEach(Self.speedChoices(including: scaling.multiplier), id: \.self) { Text(Self.speedTitle($0)).tag($0) }
                }
                Picker("Applies to", selection: Binding(
                    get: { scaling.axes },
                    set: { scroll.wrappedValue.modifierScaling?.axes = $0 }
                )) {
                    ForEach(ScalingAxes.allCases, id: \.self) { Text(Self.axesTitle($0)).tag($0) }
                }
                if let problem = scaling.problem(horizontalModifier: scroll.wrappedValue.horizontalModifier) {
                    Label(problem, systemImage: "exclamationmark.triangle").foregroundStyle(.orange)
                }
            }
            Text("Hold the keys while turning the wheel. ×0.5 scrolls half as far and ×2 twice as far. Wheel mappings on the same keys take priority, and trackpads and smooth scrolling are left alone.")
                .font(.footnote).foregroundStyle(.secondary)
        }
    }
}

// MARK: - Pointer

struct PointerPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var devices: DeviceMonitor
    @ObservedObject var pointer: PointerController

    var body: some View {
        Form {
            if let pending = pointer.pending {
                Section {
                    HStack {
                        Label("Keep this pointer speed? It changes back in a few seconds otherwise.", systemImage: "exclamationmark.triangle")
                        Spacer()
                        Button("Revert") { pointer.revertPending() }
                        Button("Keep") { pointer.confirmPending() }.keyboardShortcut(.defaultAction)
                    }
                    .id(pending.deadline)
                }
            }
            let mice = devices.devices.filter { !$0.isExcluded }
            if mice.isEmpty {
                Section { Text("No mouse is connected.").foregroundStyle(.secondary) }
            }
            ForEach(mice) { device in
                Section(device.name) { deviceSettings(device) }
            }
            Section {
                Text("Pointer settings apply while Whisker is running and go back to the system’s when it quits, or while an app you’ve bypassed is in front. Trackpads keep their own settings.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    @ViewBuilder private func deviceSettings(_ device: ConnectedDevice) -> some View {
        let binding = model.deviceBinding(device.id, name: device.name)
        Toggle("Custom pointer speed", isOn: Binding(
            get: { binding.wrappedValue.pointer != nil },
            set: { binding.wrappedValue.pointer = $0 ? PointerSettings() : nil }
        ))
        if let current = binding.wrappedValue.pointer {
            LabeledContent("Speed") {
                Slider(value: Binding(
                    get: { current.speed },
                    set: { binding.wrappedValue.pointer?.speed = $0 }
                ), in: PointerMath.speedRange) {
                    EmptyView()
                } minimumValueLabel: { Text("Slow") } maximumValueLabel: { Text("Fast") } onEditingChanged: { editing in
                    if editing {
                        startSpeed[device.id] = binding.wrappedValue.pointer
                    } else if let before = startSpeed.removeValue(forKey: device.id),
                              let after = binding.wrappedValue.pointer,
                              PointerMath.needsConfirmation(confirmed: before?.speed ?? 1, new: after.speed) {
                        pointer.beginConfirmation(deviceID: device.id, previous: before)
                    }
                }
            }
            Toggle("Linear (no acceleration)", isOn: Binding(
                get: { current.linear },
                set: { binding.wrappedValue.pointer?.linear = $0 }
            ))
            if !current.linear {
                LabeledContent("Acceleration") {
                    Slider(value: Binding(
                        get: { current.acceleration },
                        set: { binding.wrappedValue.pointer?.acceleration = $0 }
                    ), in: PointerMath.accelerationRange) {
                        EmptyView()
                    } minimumValueLabel: { Text("Less") } maximumValueLabel: { Text("More") }
                }
            }
            if pointer.unsupported.contains(device.id) {
                Text("macOS didn’t accept a pointer change for this mouse.").font(.footnote).foregroundStyle(.orange)
            }
        }
        if pointer.restoreFailures.contains(device.id) {
            Text("Whisker couldn’t put this mouse’s own pointer settings back, so its speed and acceleration may still be in use. It keeps trying, and tries again when it next starts.")
                .font(.footnote).foregroundStyle(.orange)
        }
    }

    // Speeds at the start of a slider drag, to compare against when the drag ends.
    private var startSpeed: SpeedMemo { SpeedMemo.shared }
}

/// Holds the value a slider started from; SwiftUI's `@State` isn't available in this build setup.
final class SpeedMemo {
    @MainActor static let shared = SpeedMemo()
    private var values: [String: PointerSettings?] = [:]

    subscript(id: String) -> PointerSettings?? {
        get { values[id] }
        set { values[id] = newValue }
    }

    func removeValue(forKey id: String) -> PointerSettings?? {
        values.removeValue(forKey: id)
    }
}

// MARK: - Applications

struct ApplicationsPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var pointer: PointerController

    private var appProfiles: [Profile] {
        store.settings.profiles.filter { !$0.isDefault && !$0.match.apps.contains(ProfileMatch.any) }
    }

    var body: some View {
        Form {
            Section {
                Text("Give an app its own buttons and scrolling. Anything an app profile doesn’t set comes from the profile it inherits from.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
            Section("App Profiles") {
                if appProfiles.isEmpty {
                    Text("No app profiles yet.").foregroundStyle(.secondary)
                }
                ForEach(appProfiles) { profile in
                    HStack {
                        AppIcon(bundleID: profile.match.apps.first)
                        VStack(alignment: .leading) {
                            Text(profile.name)
                            Text(subtitle(profile)).font(.caption).foregroundStyle(.secondary)
                            Toggle("Bypass Whisker in this application", isOn: bypassBinding(profile))
                                .toggleStyle(.checkbox).font(.caption)
                        }
                        Spacer()
                        Button("Edit Buttons") {
                            model.selectedProfileID = profile.id
                            model.selectedPane = .buttons
                        }
                        Button {
                            model.deleteProfile(profile.id)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.borderless)
                        .help("Delete this profile")
                    }
                }
            }
            Section {
                HStack {
                    Menu("Add Running App") {
                        ForEach(runningApps, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                                add(bundleID: app.bundleIdentifier, name: app.localizedName)
                            }
                        }
                    }
                    .fixedSize()
                    Button("Choose App…") { chooseApp() }
                }
            }
            Section("Application Bypass") {
                Text("While one of these apps is in front, Whisker leaves your buttons, wheel, scrolling and pointer speed alone, and puts them back when you switch to another app. Your profiles and the Enabled switch don’t change, and this works with or without Input Monitoring.")
                    .font(.footnote).foregroundStyle(.secondary)
                if bypassedApps.isEmpty {
                    Text("No apps are bypassed.").foregroundStyle(.secondary)
                }
                ForEach(bypassedApps, id: \.self) { id in
                    HStack {
                        AppIcon(bundleID: id)
                        VStack(alignment: .leading) {
                            Text(model.appName(forBundleID: id))
                            Text(id).font(.caption).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button {
                            model.setBypass(id, false)
                        } label: {
                            Image(systemName: "minus.circle")
                        }
                        .buttonStyle(.borderless)
                        .help("Stop bypassing this app")
                    }
                }
                HStack {
                    Menu("Bypass Running App") {
                        ForEach(bypassCandidates, id: \.bundleIdentifier) { app in
                            Button(app.localizedName ?? app.bundleIdentifier ?? "App") {
                                if let id = app.bundleIdentifier { model.setBypass(id, true) }
                            }
                        }
                    }
                    .fixedSize()
                    Button("Choose App to Bypass…") { chooseBypassedApp() }
                }
                if !pointer.restoreFailures.isEmpty {
                    Label("Whisker couldn’t put the pointer settings back for some mice, so its speed and acceleration may still be in use. It keeps trying, and tries again when it next starts.", systemImage: "exclamationmark.triangle")
                        .font(.footnote).foregroundStyle(.orange)
                }
                Text("Whisker can see which app is in front, not what a game does with its input. This isn’t raw-input mode, it doesn’t change Game Mode, and it can’t promise anti-cheat compatibility. A launcher and the game it starts can be separate apps, and which one is in front hasn’t been verified for particular games. Opening a Whisker window brings Whisker to the front, which ends the bypass until you switch back.")
                    .font(.footnote).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
    }

    private var bypassedApps: [String] {
        store.settings.general.bypassApps
            .sorted { model.appName(forBundleID: $0).localizedStandardCompare(model.appName(forBundleID: $1)) == .orderedAscending }
    }

    private var bypassCandidates: [NSRunningApplication] {
        let listed = Set(store.settings.general.bypassApps)
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !listed.contains($0.bundleIdentifier!) && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    /// True when every app the profile covers is on the bypass list.
    private func isBypassed(_ profile: Profile) -> Bool {
        let apps = profile.match.apps
        return !apps.isEmpty && apps.allSatisfy { store.settings.general.bypassApps.contains($0) }
    }

    private func bypassBinding(_ profile: Profile) -> Binding<Bool> {
        Binding(
            get: { isBypassed(profile) },
            set: { [model] on in
                for app in profile.match.apps { model.setBypass(app, on) }
            }
        )
    }

    private func chooseBypassedApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let id = Bundle(url: url)?.bundleIdentifier,
              id != Bundle.main.bundleIdentifier
        else { return }
        model.setBypass(id, true)
    }

    private func subtitle(_ profile: Profile) -> String {
        let count = profile.mappings.count
        let parent = profile.inherits.flatMap { store.settings.profile(id: $0)?.name } ?? "nothing"
        let devices = profile.match.devices.contains(ProfileMatch.any) ? "" : " · one mouse"
        let bypassed = isBypassed(profile) ? " · bypassed" : ""
        return "\(profile.match.apps.joined(separator: ", ")) · \(count) \(count == 1 ? "mapping" : "mappings") · inherits \(parent)\(devices)\(bypassed)"
    }

    private var runningApps: [NSRunningApplication] {
        let existing = Set(appProfiles.flatMap(\.match.apps))
        return NSWorkspace.shared.runningApplications
            .filter { $0.activationPolicy == .regular && $0.bundleIdentifier != nil && !existing.contains($0.bundleIdentifier!) && $0.bundleIdentifier != Bundle.main.bundleIdentifier }
            .sorted { ($0.localizedName ?? "").localizedStandardCompare($1.localizedName ?? "") == .orderedAscending }
    }

    private func chooseApp() {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.application]
        panel.directoryURL = URL(fileURLWithPath: "/Applications")
        guard panel.runModal() == .OK, let url = panel.url, let bundle = Bundle(url: url) else { return }
        let name = FileManager.default.displayName(atPath: url.path).replacingOccurrences(of: ".app", with: "")
        add(bundleID: bundle.bundleIdentifier, name: name)
    }

    private func add(bundleID: String?, name: String?) {
        guard let bundleID else { return }
        if let existing = store.settings.appProfile(bundleID: bundleID) {
            model.selectedProfileID = existing.id
        } else {
            let profile = Profile.forApp(bundleID: bundleID, name: name ?? bundleID)
            store.settings.profiles.append(profile)
            model.selectedProfileID = profile.id
        }
        model.selectedPane = .buttons
    }
}

struct AppIcon: View {
    var bundleID: String?

    var body: some View {
        let image: NSImage = {
            if let bundleID, let url = NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID) {
                return NSWorkspace.shared.icon(forFile: url.path)
            }
            return NSImage(systemSymbolName: "app", accessibilityDescription: nil) ?? NSImage()
        }()
        Image(nsImage: image).resizable().frame(width: 24, height: 24)
    }
}

// MARK: - Devices

struct DevicesPane: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject var store: SettingsStore
    @ObservedObject var devices: DeviceMonitor

    private var remembered: [(id: String, settings: DeviceSettings)] {
        let connected = Set(devices.devices.map(\.id))
        return store.settings.devices.filter { !connected.contains($0.key) }.map { ($0.key, $0.value) }.sorted { $0.0 < $1.0 }
    }

    var body: some View {
        let connected = devices.connectedDetails
        Form {
            Section("Connected") {
                if connected.isEmpty {
                    Text("No mouse is connected.").foregroundStyle(.secondary)
                }
                ForEach(connected) { details in
                    if let kind = details.excludedKind {
                        VStack(alignment: .leading, spacing: 6) {
                            LabeledContent(details.name) { Text(kind.listLabel).foregroundStyle(.secondary) }
                            DeviceDetailsDisclosure(details: details, onOpen: { devices.refreshControls() })
                        }
                    } else {
                        deviceRow(details, name: details.name, onOpen: { devices.refreshControls() })
                    }
                }
            }
            if !remembered.isEmpty {
                Section("Not Connected") {
                    ForEach(remembered, id: \.id) { entry in
                        deviceRow(
                            devices.rememberedDetails(id: entry.id, name: entry.settings.name),
                            name: entry.settings.name.isEmpty ? entry.id : entry.settings.name,
                            forget: { store.settings.devices[entry.id] = nil }
                        )
                    }
                }
            }
            Section("Telling Mice Apart") {
                LabeledContent("Input Monitoring") { Text(devices.identification.title) }
                Text(devices.identification.explanation)
                    .font(.footnote).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                switch devices.identification {
                case .listening: EmptyView()
                case .notAllowed: Button("Allow Input Monitoring…") { devices.requestIdentification() }
                case .couldNotListen: Button("Try Again") { devices.requestIdentification() }
                }
            }
        }
        .formStyle(.grouped)
    }

    /// `name` is what a new profile or first saved setting for the mouse is called; the row shows `details.name`.
    @ViewBuilder private func deviceRow(
        _ details: DeviceDetails, name: String, onOpen: @escaping () -> Void = {}, forget: (() -> Void)? = nil
    ) -> some View {
        let id = details.id
        let binding = model.deviceBinding(id, name: name)
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Toggle(isOn: binding.enabled) {
                    VStack(alignment: .leading) {
                        Text(details.name)
                        Text(details.summaryText).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Spacer()
                Button(store.settings.deviceProfile(deviceID: id) == nil ? "Make Profile" : "Edit Buttons") {
                    if let existing = store.settings.deviceProfile(deviceID: id) {
                        model.selectedProfileID = existing.id
                    } else {
                        let profile = Profile.forDevice(id: id, name: name)
                        store.settings.profiles.append(profile)
                        model.selectedProfileID = profile.id
                    }
                    model.selectedPane = .buttons
                }
                if let forget {
                    Button(action: forget) { Image(systemName: "trash") }
                        .buttonStyle(.borderless)
                        .help("Forget this mouse")
                        .accessibilityLabel("Forget \(details.name)")
                }
            }
            if binding.wrappedValue.enabled {
                Toggle("Reverse vertical scrolling", isOn: binding.wheel.invertVertical)
                Toggle("Reverse horizontal scrolling", isOn: binding.wheel.invertHorizontal)
            }
            DeviceDetailsDisclosure(details: details, onOpen: onOpen)
        }
    }
}

// MARK: - About

struct AboutPane: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 96, height: 96)
            Text(WhiskerInfo.name).font(.title)
            Text("Version \(AppInfo.version)").foregroundStyle(.secondary)
            Text("Make every button and wheel on your mouse do what you want, per app.")
                .multilineTextAlignment(.center)
            HStack(spacing: 16) {
                Link("Website", destination: WhiskerInfo.siteURL)
                Link("Source Code", destination: WhiskerInfo.repositoryURL)
            }
            Text("Free and open source under the MIT License.").font(.footnote).foregroundStyle(.secondary)
        }
        .padding(32)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
