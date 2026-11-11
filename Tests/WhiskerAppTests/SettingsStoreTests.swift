import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Settings store", .serialized)
@MainActor
struct SettingsStoreTests {
    /// A fresh folder inside the package's .build directory.
    static func makeDirectory() throws -> URL {
        let packageRoot = URL(fileURLWithPath: #filePath).deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        let directory = packageRoot.appendingPathComponent(".build/test-tmp/\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        return directory
    }

    static func setPermissions(_ mode: Int, _ url: URL) throws {
        try FileManager.default.setAttributes([.posixPermissions: mode], ofItemAtPath: url.path)
    }

    static func changedSettings() -> WhiskerSettings {
        var settings = WhiskerSettings()
        settings.general.enabled = false
        return settings
    }

    @Test func missingFileStartsWithDefaultsAndSaves() throws {
        let directory = try Self.makeDirectory()
        defer { try? FileManager.default.removeItem(at: directory) }
        let store = SettingsStore(directory: directory)
        #expect(store.readOnlyReason == nil)
        store.settings = Self.changedSettings()
        store.saveNow()
        #expect(FileManager.default.fileExists(atPath: store.fileURL.path))
    }

    @Test func unreadableFileIsNeverOverwritten() throws {
        let directory = try Self.makeDirectory()
        let file = directory.appendingPathComponent("settings.json")
        let original = Data("{\"precious\": true}".utf8)
        try original.write(to: file)
        try Self.setPermissions(0o000, file)
        defer {
            try? Self.setPermissions(0o644, file)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SettingsStore(directory: directory)
        store.settings = Self.changedSettings()
        store.saveNow()

        #expect(store.readOnlyReason != nil)
        try Self.setPermissions(0o644, file)
        #expect(try Data(contentsOf: file) == original)
    }

    @Test func damagedFileThatCantBeSetAsideIsKept() throws {
        let directory = try Self.makeDirectory()
        let file = directory.appendingPathComponent("settings.json")
        let original = Data("not json".utf8)
        try original.write(to: file)
        try Self.setPermissions(0o555, directory)
        defer {
            try? Self.setPermissions(0o755, directory)
            try? FileManager.default.removeItem(at: directory)
        }

        let store = SettingsStore(directory: directory)
        store.settings = Self.changedSettings()
        store.saveNow()

        #expect(store.readOnlyReason != nil)
        #expect(try Data(contentsOf: file) == original)
    }
}
