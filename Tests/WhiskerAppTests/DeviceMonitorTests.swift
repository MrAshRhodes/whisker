import Combine
import Foundation
import Testing
@testable import Whisker
@testable import WhiskerCore

@Suite("Device monitor")
@MainActor
struct DeviceMonitorTests {
    @Test func recentInputIsPublishedOnceAndNeverReachesTheEventPath() {
        let monitor = DeviceMonitor()
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        var published = 0
        let subscription = monitor.$recentInput.dropFirst().sink { _ in published += 1 }
        defer { subscription.cancel() }

        monitor.recordInput(from: "046d:c52b", at: 10)
        monitor.recordInput(from: "046d:c52b", at: 11)
        monitor.recordInput(from: "046d:c52b", at: 12)

        #expect(monitor.recentInput == ["046d:c52b"])
        #expect(published == 1)
        #expect(changes == 0)
        #expect(monitor.attribute(.button(0), at: 12.001) == nil)
    }

    @Test func inputGoesStaleAfterTheWindowUntilTheDeviceReportsAgain() {
        let monitor = DeviceMonitor()
        monitor.recordInput(from: "a", at: 100)
        monitor.publishRecent(at: 100 + AttributionEvidence.window - 1)
        #expect(monitor.recentInput == ["a"])

        monitor.publishRecent(at: 100 + AttributionEvidence.window)
        #expect(monitor.recentInput.isEmpty)

        monitor.recordInput(from: "a", at: 200)
        #expect(monitor.recentInput == ["a"])
    }

    @Test func aDeviceThatLeavesIsForgottenUntilItReportsAgain() {
        let monitor = DeviceMonitor()
        monitor.recordInput(from: "a", at: 100)
        monitor.recordInput(from: "b", at: 101)

        monitor.pruneEvidence(keeping: ["b"], at: 102)
        #expect(monitor.recentInput == ["b"])

        // It reconnects: its earlier input doesn't come back.
        monitor.pruneEvidence(keeping: ["a", "b"], at: 103)
        #expect(monitor.recentInput == ["b"])
        monitor.recordInput(from: "a", at: 104)
        #expect(monitor.recentInput == ["a", "b"])
    }

    @Test func readingControlsAgainPublishesNothingWhenNothingChanged() {
        let monitor = DeviceMonitor()
        var changes = 0
        monitor.onChange = { _ in changes += 1 }
        var published = 0
        let subscription = monitor.objectWillChange.sink { published += 1 }
        defer { subscription.cancel() }

        monitor.refreshControls()
        monitor.refreshControls()

        #expect(published == 0)
        #expect(changes == 0)
    }
}
