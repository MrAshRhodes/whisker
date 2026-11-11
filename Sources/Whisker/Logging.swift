import Foundation
import OSLog
import WhiskerCore

enum Log {
    static let app = Logger(subsystem: WhiskerInfo.bundleIdentifier, category: "app")
    static let events = Logger(subsystem: WhiskerInfo.bundleIdentifier, category: "events")
    static let settings = Logger(subsystem: WhiskerInfo.bundleIdentifier, category: "settings")
    static let devices = Logger(subsystem: WhiskerInfo.bundleIdentifier, category: "devices")
    static let pointer = Logger(subsystem: WhiskerInfo.bundleIdentifier, category: "pointer")
    static let permissions = Logger(subsystem: WhiskerInfo.bundleIdentifier, category: "permissions")
}
