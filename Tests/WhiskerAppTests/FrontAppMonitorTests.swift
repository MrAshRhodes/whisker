import Testing
@testable import Whisker

@Suite("Front app monitor")
@MainActor
struct FrontAppMonitorTests {
    static let game = "com.example.game"
    static let notes = "com.example.notes"

    @Test func reportsTheAppInFrontWhenItChanges() {
        let monitor = FrontAppMonitor()
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.activated(bundleID: Self.game)
        monitor.activated(bundleID: Self.game)
        #expect(monitor.frontmostBundleID == Self.game)
        #expect(changes == 1)

        monitor.activated(bundleID: Self.notes)
        #expect(monitor.frontmostBundleID == Self.notes)
        #expect(changes == 2)
    }

    @Test func anAppWithoutAnIdentifierChangesNothing() {
        let monitor = FrontAppMonitor()
        monitor.activated(bundleID: Self.game)
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.activated(bundleID: nil)
        monitor.activated(bundleID: "")

        #expect(monitor.frontmostBundleID == Self.game)
        #expect(changes == 0)
    }

    @Test func aQuittingAppDoesNotChangeTheAppInFront() {
        let monitor = FrontAppMonitor()
        monitor.activated(bundleID: Self.notes)
        monitor.activated(bundleID: Self.game)
        var changes = 0
        monitor.onChange = { changes += 1 }

        monitor.terminated(bundleID: Self.game)
        monitor.terminated(bundleID: Self.notes)
        monitor.terminated(bundleID: nil)

        #expect(monitor.frontmostBundleID == Self.game)
        #expect(changes == 0)
    }
}
