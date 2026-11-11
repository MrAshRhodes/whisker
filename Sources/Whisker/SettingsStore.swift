import Combine
import Foundation
import WhiskerCore

/// The pointer values a device had before Whisker changed them, so they can be put back.
struct OriginalPointer: Codable, Equatable {
    /// `HIDPointerResolution` in 16.16 fixed point.
    var resolution: Int64?
    /// `HIDMouseAcceleration` in 16.16 fixed point.
    var acceleration: Int64?
}

/// Small file Whisker uses to notice it didn't quit cleanly last time.
struct RunState: Codable, Equatable {
    var cleanExit = true
    var originalPointers: [String: OriginalPointer] = [:]
}

/// Owns `settings.json`: loads it at launch (repairing what it can), saves changes shortly after they're
/// made, and imports and exports copies.
@MainActor
final class SettingsStore: ObservableObject {
    static let saveDelay: TimeInterval = 0.3

    @Published var settings: WhiskerSettings {
        didSet { if settings != oldValue { scheduleSave() } }
    }
    /// Problems fixed while loading, shown once in the settings window.
    @Published private(set) var loadIssues: [ValidationIssue] = []
    /// Set when the file belongs to a newer Whisker; nothing is written so it isn't damaged.
    @Published private(set) var readOnlyReason: String?

    let directory: URL
    var fileURL: URL { directory.appendingPathComponent("settings.json") }
    var stateURL: URL { directory.appendingPathComponent("state.json") }

    private var pendingSave: DispatchWorkItem?

    nonisolated static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
            ?? URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Library/Application Support")
        return base.appendingPathComponent("Whisker", isDirectory: true)
    }

    init(directory: URL = SettingsStore.defaultDirectory) {
        self.directory = directory
        settings = .default
        load()
    }

    func load() {
        guard let data = try? Data(contentsOf: fileURL) else {
            Log.settings.info("No settings file yet; using defaults")
            settings = .default
            return
        }
        do {
            let (loaded, issues) = try SettingsCodec.decodeRepairing(data)
            readOnlyReason = nil
            settings = loaded
            loadIssues = issues
            for issue in issues {
                Log.settings.warning("Repaired settings: \(issue.description, privacy: .public)")
            }
        } catch SettingsCodec.Failure.newerSchema(let version) {
            readOnlyReason = SettingsCodec.Failure.newerSchema(version).errorDescription
            Log.settings.error("Settings file is from a newer version (schema \(version)); not saving changes")
            settings = .default
        } catch {
            let backup = directory.appendingPathComponent("settings.unreadable-\(Self.timestamp()).json")
            try? FileManager.default.moveItem(at: fileURL, to: backup)
            Log.settings.error("Settings file unreadable, moved to \(backup.lastPathComponent, privacy: .public): \(error.localizedDescription, privacy: .public)")
            loadIssues = [ValidationIssue("settings.json", "The file couldn’t be read and was set aside as \(backup.lastPathComponent). Whisker started with default settings.")]
            settings = .default
        }
    }

    func dismissLoadIssues() {
        loadIssues = []
    }

    private func scheduleSave() {
        pendingSave?.cancel()
        let work = DispatchWorkItem { [weak self] in
            MainActor.assumeIsolated { self?.saveNow() }
        }
        pendingSave = work
        DispatchQueue.main.asyncAfter(deadline: .now() + Self.saveDelay, execute: work)
    }

    func saveNow() {
        pendingSave?.cancel()
        pendingSave = nil
        guard readOnlyReason == nil else { return }
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try SettingsCodec.encode(settings).write(to: fileURL, options: .atomic)
        } catch {
            Log.settings.error("Couldn’t save settings: \(error.localizedDescription, privacy: .public)")
        }
    }

    /// Replaces the settings with a file the user picked. The file must be valid as it is.
    func importSettings(from url: URL) throws {
        let data = try Data(contentsOf: url)
        let imported = try SettingsCodec.decodeValidated(data)
        readOnlyReason = nil
        settings = imported
        saveNow()
        Log.settings.info("Imported settings from \(url.lastPathComponent, privacy: .public)")
    }

    func exportSettings(to url: URL) throws {
        try SettingsCodec.encode(settings).write(to: url, options: .atomic)
    }

    func resetToDefaults() {
        readOnlyReason = nil
        settings = .default
    }

    // MARK: Run state

    func loadRunState() -> RunState {
        guard let data = try? Data(contentsOf: stateURL), let state = try? JSONDecoder().decode(RunState.self, from: data) else {
            return RunState()
        }
        return state
    }

    func saveRunState(_ state: RunState) {
        do {
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try JSONEncoder().encode(state).write(to: stateURL, options: .atomic)
        } catch {
            Log.app.error("Couldn’t save run state: \(error.localizedDescription, privacy: .public)")
        }
    }

    private static func timestamp() -> String {
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyyMMdd-HHmmss"
        return formatter.string(from: Date())
    }
}
