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
            // Version 2 added the shortcutSequence action and, per device, pointer presets and the pointerPreset
            // action. A version 1 file can't contain any of them, so it already has the version 2 shape. The bump
            // makes a Whisker that predates them leave a file that uses them alone instead of failing to read it.
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
            // Best effort: failing to find unknown fields must never make a readable file unreadable.
            if let original = try? JSONDecoder().decode(JSONValue.self, from: upgraded), let known = knownJSON(of: settings) {
                settings.nestedUnknownFields = SettingsJSONShape.settings.unknownFields(in: original, known: known)
            }
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
        if let fields = settings.nestedUnknownFields {
            let known = try JSONDecoder().decode(JSONValue.self, from: data)
            data = try encoder.encode(SettingsJSONShape.settings.merging(fields, into: known))
        }
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

    /// Only unknown values are retained, never an old copy of a known setting that could undo an edit.
    indirect enum SettingsUnknownFields: Equatable, Sendable {
        case object(values: [String: JSONValue], children: [String: SettingsUnknownFields], tag: JSONValue? = nil)
        case array([JSONValue: SettingsUnknownFields])
    }

    /// The preserved fields whose objects still exist in `settings`. Dropping the rest means an object deleted and
    /// later recreated with the same identity, or an action switched to another kind and back, starts afresh.
    static func unknownFieldsInUse(by settings: WhiskerSettings) -> SettingsUnknownFields? {
        guard let fields = settings.nestedUnknownFields else { return nil }
        // Unencodable settings can't be saved either; keep everything until they can.
        guard let known = knownJSON(of: settings) else { return fields }
        return SettingsJSONShape.settings.pruning(fields, against: known)
    }

    private static func knownJSON(of settings: WhiskerSettings) -> JSONValue? {
        guard let data = try? JSONEncoder().encode(settings) else { return nil }
        return try? JSONDecoder().decode(JSONValue.self, from: data)
    }

    /// Ownership of JSON fields, not another decoder: Codable still supplies all values, defaults and errors.
    /// Include even keys omitted by encoders (nil, false or empty), so removing a setting cannot revive it.
    private indirect enum SettingsJSONShape {
        case value
        case object([String: SettingsJSONShape], omitted: JSONValue? = nil, discriminator: String? = nil)
        case dictionary(SettingsJSONShape)
        case array(SettingsJSONShape, identity: ItemIdentity)

        enum ItemIdentity {
            case fields([String])
            case chord
            /// Anonymous steps have no durable identity. Retain extras only for unique, unchanged values.
            case unchanged

            func key(for value: JSONValue) -> JSONValue? {
                guard case .object(let fields) = value else { return nil }
                switch self {
                case .fields(let keys):
                    let parts = keys.compactMap { fields[$0] }
                    return parts.count == keys.count ? .array(parts) : nil
                case .chord:
                    guard case .number(let first)? = fields["first"], case .number(let second)? = fields["second"],
                          let modifiers = fields["modifiers"] else { return nil }
                    return .array([.number(min(first, second)), .number(max(first, second)), modifiers])
                case .unchanged:
                    return value
                }
            }
        }

        static let settings = object([
            "schemaVersion": .value,
            "general": .object([
                "enabled": .value, "showMenuBarIcon": .value, "allowPrimaryButtonRemap": .value,
                "bypassApps": .value, "experimentalClickLock": .value,
            ]),
            "devices": .dictionary(device),
            "profiles": .array(profile, identity: .fields(["id"])),
        ])

        private static let device = object([
            "name": .value, "enabled": .value, "rotationDegrees": .value, "swapPrimarySecondary": .value,
            "pointer": .object(["speed": .value, "acceleration": .value, "linear": .value]),
            "wheel": .object([
                "invertVertical": .value, "invertHorizontal": .value,
                "native": .object(["enabled": .value, "speed": .value, "acceleration": .value]),
            ]),
            "clickDebounce": .object(["buttons": .value, "interval": .value]),
            "controlLabels": .array(.object(["trigger": trigger, "name": .value]), identity: .fields(["trigger"])),
            "pointerPresets": .array(.object(["id": .value, "name": .value, "speed": .value]), identity: .fields(["id"])),
            "activePointerPresetID": .value,
            "extraButtons": .object(
                ["discoveryEnabled": .value],
                omitted: .object(["discoveryEnabled": .bool(false)])
            ),
            // Already modelled as JSONValue; replacing or deleting an opaque record must win outright.
            "extraButtonMappings": .value,
        ])

        private static let profile = object([
            "id": .value, "name": .value, "inherits": .value,
            "match": .object(["devices": .value, "apps": .value]),
            "scroll": .object([
                "linesPerNotch": .value, "acceleration": .value, "horizontalModifier": .value,
                "smoothScrolling": .value, "smoothDuration": .value,
                "modifierScaling": .object(["modifiers": .value, "multiplier": .value, "axes": .value]),
            ]),
            "chords": .array(.object([
                "first": .value, "second": .value, "modifiers": .value, "action": action, "pressWindow": .value,
            ]), identity: .chord),
            "mappings": .array(mapping, identity: .fields(["trigger", "modifiers"])),
        ])

        private static let mapping = object([
            "trigger": trigger, "modifiers": .value, "action": action,
            "repeatPerNotch": .value, "continuousInput": .object(["distance": .value]),
            "gestures": .object([
                "up": action, "down": action, "left": action, "right": action, "tap": action, "threshold": .value,
            ]),
        ])

        private static let trigger = object(["type": .value, "button": .value, "direction": .value], discriminator: "type")

        private static let action = object([
            "kind": .value, "button": .value, "modifiers": .value, "keyCode": .value, "repeatWhileHeld": .value,
            "direction": .value, "lines": .value, "key": .value, "target": .value, "url": .value,
            "steps": .array(.object(["keyCode": .value, "modifiers": .value, "delayAfterMs": .value]), identity: .unchanged),
            "axes": .value, "sensitivity": .value, "invertVertical": .value, "invertHorizontal": .value,
            "deadZone": .value, "maxSpeed": .value, "device": .value, "preset": .value, "factor": .value,
        ], discriminator: "kind")

        private var omittedValue: JSONValue? {
            if case .object(_, let value, _) = self { return value }
            return nil
        }

        func unknownFields(in original: JSONValue, known: JSONValue) -> SettingsUnknownFields? {
            switch (self, original, known) {
            case let (.object(fields, _, discriminator), .object(source), .object(current)):
                // Top-level unknownKeys are already in the model's output and need no second copy here.
                let values = source.filter { fields[$0.key] == nil && current[$0.key] == nil }
                var children: [String: SettingsUnknownFields] = [:]
                for (key, shape) in fields {
                    if let original = source[key], let known = current[key] ?? shape.omittedValue {
                        children[key] = shape.unknownFields(in: original, known: known)
                    }
                }
                return values.isEmpty && children.isEmpty ? nil
                    : .object(values: values, children: children, tag: discriminator.flatMap { current[$0] })
            case let (.dictionary(shape), .object(source), .object(current)):
                var children: [String: SettingsUnknownFields] = [:]
                for (key, known) in current {
                    if let original = source[key] { children[key] = shape.unknownFields(in: original, known: known) }
                }
                return children.isEmpty ? nil : .object(values: [:], children: children)
            case let (.array(shape, identity), .array(source), .array(current)):
                // Before editing/repair, Codable preserves array order. Use its normalised identities,
                // not raw optional/default fields, and never rely on positions again after this point.
                guard source.count == current.count else { return nil }
                let identities = uniqueIdentities(in: current, identity: identity)
                var items: [JSONValue: SettingsUnknownFields] = [:]
                for index in source.indices {
                    if let id = identities[index] {
                        items[id] = shape.unknownFields(in: source[index], known: current[index])
                    }
                }
                return items.isEmpty ? nil : .array(items)
            default:
                return nil
            }
        }

        func merging(_ preserved: SettingsUnknownFields, into known: JSONValue) -> JSONValue {
            switch (self, preserved, known) {
            case let (.object(fields, _, discriminator), .object(values, children, tag), .object(known)):
                // Changing an action kind replaces the action, rather than donating its parameters to another kind.
                if let discriminator, known[discriminator] != tag { return .object(known) }
                var current = known
                for (key, value) in values where fields[key] == nil && current[key] == nil { current[key] = value }
                for (key, child) in children {
                    guard let shape = fields[key], let value = current[key] ?? shape.omittedValue else { continue }
                    current[key] = shape.merging(child, into: value)
                }
                return .object(current)
            case let (.dictionary(shape), .object(_, children, _), .object(known)):
                var current = known
                for (key, child) in children {
                    // Dictionary keys identify devices; deleted devices must not be reintroduced.
                    if let value = current[key] { current[key] = shape.merging(child, into: value) }
                }
                return .object(current)
            case let (.array(shape, identity), .array(items), .array(known)):
                let identities = uniqueIdentities(in: known, identity: identity)
                return .array(known.enumerated().map { index, value in
                    guard let id = identities[index], let child = items[id] else { return value }
                    return shape.merging(child, into: value)
                })
            default:
                return known
            }
        }

        /// What `merging` would still apply to `known`; anything else belongs to an object that is gone or replaced.
        func pruning(_ preserved: SettingsUnknownFields, against known: JSONValue) -> SettingsUnknownFields? {
            switch (self, preserved, known) {
            case let (.object(fields, _, discriminator), .object(values, children, tag), .object(current)):
                if let discriminator, current[discriminator] != tag { return nil }
                var kept: [String: SettingsUnknownFields] = [:]
                for (key, child) in children {
                    guard let shape = fields[key], let value = current[key] ?? shape.omittedValue else { continue }
                    kept[key] = shape.pruning(child, against: value)
                }
                return values.isEmpty && kept.isEmpty ? nil : .object(values: values, children: kept, tag: tag)
            case let (.dictionary(shape), .object(_, children, _), .object(current)):
                var kept: [String: SettingsUnknownFields] = [:]
                for (key, child) in children {
                    if let value = current[key] { kept[key] = shape.pruning(child, against: value) }
                }
                return kept.isEmpty ? nil : .object(values: [:], children: kept)
            case let (.array(shape, identity), .array(items), .array(current)):
                let identities = uniqueIdentities(in: current, identity: identity)
                let present = Set(current.compactMap { identity.key(for: $0) })
                var kept: [JSONValue: SettingsUnknownFields] = [:]
                for (id, child) in items where present.contains(id) {
                    // A temporarily repeated identity keeps its fields untouched until only one element remains.
                    guard let index = identities.firstIndex(of: id) else { kept[id] = child; continue }
                    kept[id] = shape.pruning(child, against: current[index])
                }
                return kept.isEmpty ? nil : .array(kept)
            default:
                return nil
            }
        }

        private func uniqueIdentities(in values: [JSONValue], identity: ItemIdentity) -> [JSONValue?] {
            let identities = values.map { identity.key(for: $0) }
            let counts = Dictionary(grouping: identities.compactMap { $0 }, by: { $0 }).mapValues(\.count)
            return identities.map { id in id.flatMap { counts[$0] == 1 ? $0 : nil } }
        }
    }
}
