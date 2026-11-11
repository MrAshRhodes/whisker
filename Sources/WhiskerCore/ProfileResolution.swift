import Foundation

/// A mapping as it applies after inheritance, with where it came from.
public struct ResolvedMapping: Equatable, Sendable {
    public var mapping: Mapping
    /// Profile that defines the mapping.
    public var sourceProfileID: String
    /// True when it comes from a parent rather than the profile itself.
    public var inherited: Bool

    public init(mapping: Mapping, sourceProfileID: String, inherited: Bool) {
        self.mapping = mapping
        self.sourceProfileID = sourceProfileID
        self.inherited = inherited
    }
}

/// Everything one profile does once its parents are merged in.
public struct ResolvedProfile: Equatable, Sendable {
    public var profileID: String
    public var name: String
    public var mappings: [MappingKey: ResolvedMapping]
    public var scroll: ScrollSettings

    public init(profileID: String, name: String, mappings: [MappingKey: ResolvedMapping], scroll: ScrollSettings) {
        self.profileID = profileID
        self.name = name
        self.mappings = mappings
        self.scroll = scroll
    }

    public func mapping(_ trigger: Trigger, modifiers: ModifierSet) -> Mapping? {
        mappings[MappingKey(trigger, modifiers)]?.mapping
    }

    /// Mappings in display order: buttons by number, then wheel directions, then by modifiers.
    public var sortedMappings: [ResolvedMapping] {
        mappings.values.sorted {
            let a = $0.mapping, b = $1.mapping
            if a.trigger.sortKey != b.trigger.sortKey { return a.trigger.sortKey < b.trigger.sortKey }
            return a.modifiers.rawValue < b.modifiers.rawValue
        }
    }
}

extension WhiskerSettings {
    /// The profile that applies to a device in an app.
    ///
    /// Most specific wins: device and app, then app on any device, then device in any app, then default.
    /// Within the same level the earlier profile in the list wins.
    public func matchingProfile(device: String?, app: String?) -> Profile {
        var best: (score: Int, profile: Profile)?
        for profile in profiles where !profile.isDefault {
            guard let score = Self.matchScore(profile.match, device: device, app: app) else { continue }
            if best == nil || score > best!.score { best = (score, profile) }
        }
        return best?.profile ?? defaultProfile
    }

    static func matchScore(_ match: ProfileMatch, device: String?, app: String?) -> Int? {
        func level(_ values: [String], _ value: String?) -> Int? {
            if let value, values.contains(value) { return 1 }
            if values.contains(ProfileMatch.any) { return 0 }
            return nil
        }
        guard let deviceLevel = level(match.devices, device), let appLevel = level(match.apps, app) else { return nil }
        // App-specific beats device-specific; both beats either.
        return appLevel * 2 + deviceLevel
    }

    /// The profile chain from the furthest ancestor down to `id`. Stops at loops and missing parents.
    public func inheritanceChain(of id: String) -> [Profile] {
        var chain: [Profile] = []
        var seen = Set<String>()
        var current = profile(id: id)
        while let profile = current, seen.insert(profile.id).inserted {
            chain.insert(profile, at: 0)
            current = profile.inherits.flatMap { self.profile(id: $0) }
        }
        return chain
    }

    public func resolvedProfile(id: String) -> ResolvedProfile {
        var chain = inheritanceChain(of: id)
        if chain.isEmpty { chain = id == Profile.defaultID ? [defaultProfile] : inheritanceChain(of: Profile.defaultID) }
        if chain.isEmpty { chain = [defaultProfile] }
        let leaf = chain[chain.count - 1]
        var mappings: [MappingKey: ResolvedMapping] = [:]
        var scroll = ScrollSettings.system
        for profile in chain {
            for mapping in profile.mappings {
                mappings[mapping.key] = ResolvedMapping(mapping: mapping, sourceProfileID: profile.id, inherited: profile.id != leaf.id)
            }
            if let own = profile.scroll { scroll = own }
        }
        return ResolvedProfile(profileID: leaf.id, name: leaf.name, mappings: mappings, scroll: scroll)
    }

    public func resolvedProfile(device: String?, app: String?) -> ResolvedProfile {
        resolvedProfile(id: matchingProfile(device: device, app: app).id)
    }
}

/// Settings prepared for the event tap: profiles resolved once per settings change, then cached per
/// (device, app) so a lookup on the hot path is a dictionary read.
public final class CompiledSettings: @unchecked Sendable {
    public let settings: WhiskerSettings
    private let resolvedByID: [String: ResolvedProfile]
    private var cache: [CacheKey: String] = [:]
    private let lock = NSLock()

    private struct CacheKey: Hashable {
        var device: String?
        var app: String?
    }

    public init(_ settings: WhiskerSettings) {
        self.settings = settings
        var resolved: [String: ResolvedProfile] = [:]
        for profile in settings.profiles {
            resolved[profile.id] = settings.resolvedProfile(id: profile.id)
        }
        if resolved[Profile.defaultID] == nil {
            resolved[Profile.defaultID] = settings.resolvedProfile(id: Profile.defaultID)
        }
        resolvedByID = resolved
    }

    public var general: GeneralSettings { settings.general }

    public func profile(device: String?, app: String?) -> ResolvedProfile {
        let key = CacheKey(device: device, app: app)
        lock.lock()
        defer { lock.unlock() }
        if let id = cache[key], let profile = resolvedByID[id] { return profile }
        let id = settings.matchingProfile(device: device, app: app).id
        cache[key] = id
        return resolvedByID[id] ?? resolvedByID[Profile.defaultID]!
    }

    public func device(_ id: String?) -> DeviceSettings? {
        id.map { settings.device($0) }
    }
}
