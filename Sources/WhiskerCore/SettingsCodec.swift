import Foundation

/// Reading and writing the settings file, including upgrades from older schema versions.
public enum SettingsCodec {
    public enum Failure: Error, Equatable, LocalizedError {
        /// Not JSON, or JSON of the wrong shape.
        case unreadable(String)
        /// Written by a newer Whisker; opening it here could lose settings.
        case newerSchema(Int)
        /// Readable, but breaks the rules in `WhiskerSettings.validate()`.
        case invalid([ValidationIssue])

        public var errorDescription: String? {
            switch self {
            case .unreadable(let detail):
                return "The file isn’t a Whisker settings file. \(detail)"
            case .newerSchema(let version):
                return "These settings were saved by a newer version of Whisker (schema \(version)). Update Whisker to use them."
            case .invalid(let issues):
                let list = issues.prefix(5).map { "• \($0.message)" }.joined(separator: "\n")
                let more = issues.count > 5 ? "\n…and \(issues.count - 5) more." : ""
                return "The settings file has problems:\n\(list)\(more)"
            }
        }
    }

    /// Upgrades a decoded JSON object from `version` to `version + 1`.
    static func upgrade(_ json: inout [String: Any], from version: Int) throws {
        switch version {
        case 0:
            // Files written before the schema was versioned. Their sections already have the version 1
            // shape; anything missing takes its default when decoded, and an empty file gets the default profile.
            if json["profiles"] == nil { json["profiles"] = [] as [Any] }
        case 1:
            // Version 2 only adds the shortcutSequence action, which a version 1 file can't contain. The bump
            // makes a Whisker that predates it leave a file that uses one alone instead of failing to read it.
            break
        default:
            throw Failure.unreadable("No upgrade from schema \(version).")
        }
    }

    /// Decodes settings, upgrading older files. Doesn't validate; see `decodeValidated` and `decodeRepairing`.
    public static func decode(_ data: Data) throws -> WhiskerSettings {
        guard let object = try? JSONSerialization.jsonObject(with: data), var json = object as? [String: Any] else {
            throw Failure.unreadable("It doesn’t contain a JSON object.")
        }
        let version = (json["schemaVersion"] as? NSNumber)?.intValue ?? 0
        guard version <= WhiskerSettings.currentSchemaVersion else { throw Failure.newerSchema(version) }
        guard version >= 0 else { throw Failure.unreadable("Schema version \(version) is not valid.") }
        try migrate(&json, from: version)
        do {
            let upgraded = try JSONSerialization.data(withJSONObject: json)
            var settings = try JSONDecoder().decode(WhiskerSettings.self, from: upgraded)
            if settings.profiles.isEmpty { settings.profiles = [.makeDefault()] }
            return settings
        } catch let error as DecodingError {
            throw Failure.unreadable(describe(error))
        }
    }

    static func migrate(_ json: inout [String: Any], from version: Int) throws {
        var current = version
        while current < WhiskerSettings.currentSchemaVersion {
            try upgrade(&json, from: current)
            current += 1
            json["schemaVersion"] = current
        }
    }

    /// For imports: the file must already be valid.
    public static func decodeValidated(_ data: Data) throws -> WhiskerSettings {
        let settings = try decode(data)
        let issues = settings.validate()
        guard issues.isEmpty else { throw Failure.invalid(issues) }
        return settings
    }

    /// For the app's own file at launch: anything broken is fixed and reported rather than rejected.
    public static func decodeRepairing(_ data: Data) throws -> (settings: WhiskerSettings, issues: [ValidationIssue]) {
        try decode(data).repairedWithIssues()
    }

    public static func encode(_ settings: WhiskerSettings) throws -> Data {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        var data = try encoder.encode(settings)
        data.append(0x0A)
        return data
    }

    private static func describe(_ error: DecodingError) -> String {
        func path(_ context: DecodingError.Context) -> String {
            let joined = context.codingPath.map { $0.intValue.map { "[\($0)]" } ?? ".\($0.stringValue)" }.joined()
            return joined.hasPrefix(".") ? String(joined.dropFirst()) : joined
        }
        switch error {
        case .dataCorrupted(let context): return "\(path(context)): \(context.debugDescription)"
        case .keyNotFound(let key, let context): return "\(path(context)): missing “\(key.stringValue)”."
        case .typeMismatch(_, let context), .valueNotFound(_, let context): return "\(path(context)): \(context.debugDescription)"
        @unknown default: return error.localizedDescription
        }
    }
}
