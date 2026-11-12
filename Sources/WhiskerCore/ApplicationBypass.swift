import Foundation

/// The app in front, as far as Whisker can tell, and what happens when it can't tell.
///
/// An app without a bundle identifier can't be recognised, so it can't be on the bypass list either. When
/// one comes to the front the answer stays what it was: Whisker keeps standing aside for a listed app, and
/// keeps working in an unlisted one, until an app it can identify is in front. Quitting the front app, sleep
/// and switching users change nothing for the same reason; the next identifiable app decides.
public struct FrontmostApp: Equatable, Sendable {
    public private(set) var bundleID: String?

    public init(bundleID: String? = nil) {
        self.bundleID = bundleID
    }

    /// An app came to the front. A missing or empty identifier leaves the last known app in place and returns
    /// false.
    @discardableResult
    public mutating func activated(_ bundleID: String?) -> Bool {
        guard let bundleID, !bundleID.isEmpty else { return false }
        self.bundleID = bundleID
        return true
    }
}

extension WhiskerSettings {
    /// True when `app` is on the bypass list, so Whisker leaves buttons, wheel and pointer alone in it.
    /// Says nothing about the master switch, which wins on its own.
    public func isBypassed(app: String?) -> Bool {
        guard let app else { return false }
        return general.bypassApps.contains(app)
    }
}

extension GeneralSettings {
    /// Adds an app to the bypass list or takes it off. An app already listed isn't listed twice, and a blank
    /// identifier or the "any app" wildcard is ignored.
    public mutating func setBypassed(_ bundleID: String, _ bypassed: Bool) {
        let id = bundleID.trimmingCharacters(in: .whitespacesAndNewlines)
        if bypassed {
            guard !id.isEmpty, id != ProfileMatch.any, !bypassApps.contains(id) else { return }
            bypassApps.append(id)
        } else {
            bypassApps.removeAll { $0 == id }
        }
    }
}
