import Testing
@testable import Whisker
@testable import WhiskerCore

@Suite("Slow pointer controller")
@MainActor
struct SlowPointerControllerTests {
    typealias Fixtures = PointerControllerTests

    @MainActor final class Rig {
        let hardware = Fixtures.FakeHardware()
        let store = DetachedSettings(Fixtures.settings())
        var connected = [Fixtures.device, Fixtures.other]
        var sessions: [String: UInt64] = [:]
        lazy var controller = PointerController(hardware: hardware, store: store, connected: { [unowned self] in self.connected })

        init() {
            hardware.services[Fixtures.id] = [1]
            hardware.services[Fixtures.otherID] = [2]
            controller.apply(store.settings, connected: connected)
        }

        func send(_ generation: UInt64, _ factors: [String: Double]) {
            sessions = sessions.filter { factors[$0.key] != nil }
            for id in factors.keys where sessions[id] == nil { sessions[id] = generation }
            controller.applySlowPointer(SlowPointerCommand(generation: generation, factors: factors, sessions: sessions))
        }

        var resolution: Int64? { hardware.values[Fixtures.id]?.resolution }
    }

    @Test func overlayPreservesSettingsAccelerationAndOtherMiceAndRestoresLatestBaseline() {
        let rig = Rig()
        let saved = rig.store.settings
        let acceleration = rig.hardware.values[Fixtures.id]?.acceleration
        rig.send(1, [Fixtures.id: 0.5])
        #expect(rig.resolution == Fixtures.resolution(0.5))
        #expect(rig.store.settings == saved)
        #expect(rig.hardware.values[Fixtures.id]?.acceleration == acceleration)
        #expect(rig.hardware.values[Fixtures.otherID] == nil)

        #expect(rig.controller.selectPreset("fast", on: Fixtures.id) == .applied)
        #expect(rig.resolution == Fixtures.resolution(0.75))
        rig.send(2, [:])
        #expect(rig.resolution == Fixtures.resolution(1.5))
        #expect(rig.controller.pending == nil)
        #expect(rig.store.settings.devices[Fixtures.id]?.activePointerPresetID == "fast")
        rig.send(1, [Fixtures.id: 0.5])
        #expect(rig.resolution == Fixtures.resolution(1.5))
    }

    @Test func failedApplyRollsBackAndFailedRestoreRetainsRecoveryAndReportsIt() {
        let rig = Rig()
        rig.hardware.answers = [.partial, .accept]
        rig.send(1, [Fixtures.id: 0.5])
        #expect(rig.controller.slowPointerFactors.isEmpty)
        #expect(rig.resolution == Fixtures.resolution(1))
        #expect(rig.controller.notice != nil)
        rig.send(2, [:])
        rig.send(3, [Fixtures.id: 0.5])
        rig.hardware.answers = [.refuse]
        rig.send(4, [:])
        #expect(rig.resolution == Fixtures.resolution(0.5))
        #expect(rig.controller.restoreFailures == [Fixtures.id])
        #expect(rig.controller.originals[Fixtures.id] == Fixtures.FakeHardware.native)
        #expect(rig.controller.notice != nil)
        rig.controller.apply(rig.store.settings, connected: rig.connected)
        #expect(rig.resolution == Fixtures.resolution(1))
        #expect(rig.controller.restoreFailures.isEmpty)
    }

    @Test func partialApplyAndRollbackFailureNeverLoseOriginals() {
        let rig = Rig()
        rig.hardware.answers = [.partial, .refuse]
        rig.send(1, [Fixtures.id: 0.5])
        #expect(rig.controller.slowPointerFactors.isEmpty)
        #expect(rig.controller.restoreFailures == [Fixtures.id])
        #expect(rig.controller.originals[Fixtures.id] == Fixtures.FakeHardware.native)
        rig.hardware.refuses = true
        rig.controller.restoreAll()
        #expect(rig.controller.originals[Fixtures.id] == Fixtures.FakeHardware.native)
        rig.hardware.refuses = false
        rig.controller.restoreLeftovers(connected: rig.connected)
        #expect(rig.hardware.values[Fixtures.id] == Fixtures.FakeHardware.native)
    }

    @Test func newHoldAfterFailedApplyWorksEvenWhenQueuedEndWasCoalesced() {
        let rig = Rig()
        rig.hardware.answers = [.partial, .accept]
        rig.send(1, [Fixtures.id: 0.5])
        #expect(rig.controller.slowPointerFactors.isEmpty)
        // Generation 2 ended the hold, but only the new generation-3 start reached the main queue.
        rig.controller.applySlowPointer(SlowPointerCommand(generation: 3, factors: [Fixtures.id: 0.4], sessions: [Fixtures.id: 3]))
        #expect(rig.resolution == Fixtures.resolution(0.4))
        #expect(rig.controller.slowPointerFactors == [Fixtures.id: 0.4])
    }

    @Test func bypassDisableRemovalAndReplacementCannotReviveOldHolds() {
        for interruption in 0..<4 {
            let rig = Rig()
            rig.send(1, [Fixtures.id: 0.5])
            switch interruption {
            case 0:
                rig.controller.apply(rig.store.settings, connected: rig.connected, bypassed: true)
                rig.controller.apply(rig.store.settings, connected: rig.connected)
            case 1:
                rig.store.settings.general.enabled = false
                rig.controller.apply(rig.store.settings, connected: rig.connected)
                rig.store.settings.general.enabled = true
                rig.controller.apply(rig.store.settings, connected: rig.connected)
            case 2:
                rig.connected.removeAll { $0.id == Fixtures.id }
                rig.hardware.services[Fixtures.id] = nil
                rig.controller.devicesChanged(rig.connected)
                rig.connected.append(Fixtures.device)
                rig.hardware.services[Fixtures.id] = [3]
                rig.controller.devicesChanged(rig.connected)
            default:
                rig.hardware.services[Fixtures.id] = [3]
                rig.controller.devicesChanged(rig.connected)
            }
            #expect(rig.controller.slowPointerFactors.isEmpty)
            rig.send(2, [Fixtures.id: 0.5])
            #expect(rig.resolution == Fixtures.resolution(1))
            rig.send(3, [:])
            rig.send(4, [Fixtures.id: 0.5])
            #expect(rig.resolution == Fixtures.resolution(0.5))
        }
    }

    @Test func missingBaselineExcludedAmbiguousAndUnconfirmedTargetsAreUnavailable() {
        let rig = Rig()
        #expect(rig.controller.slowPointerDevices == [Fixtures.id])
        rig.send(1, [Fixtures.otherID: 0.5])
        #expect(rig.hardware.values[Fixtures.otherID] == nil)
        #expect(rig.controller.slowPointerFactors.isEmpty)
        _ = rig.controller.selectPreset("turbo", on: Fixtures.id)
        rig.send(2, [Fixtures.id: 0.5])
        #expect(rig.resolution == Fixtures.resolution(4))
        #expect(rig.controller.slowPointerFactors.isEmpty)
        rig.controller.revertPending()
        var ambiguous = Fixtures.device
        ambiguous.physicalKeys = ["first", "second"]
        rig.connected = [ambiguous]
        #expect(rig.controller.slowPointerDevices.isEmpty)
        rig.connected = [PointingDevice(id: Fixtures.id, name: "Touch", vendorID: 1, productID: 2, serial: nil, transport: "USB", excludedKind: .touchMouse, physicalKeys: ["touch"])]
        #expect(rig.controller.slowPointerDevices.isEmpty)
    }

    @Test func availabilityRefreshesWhenEditingAndConfirmationFinishWithoutSettingsChanges() {
        let rig = Rig()
        var available: Set<String> = []
        rig.controller.onSlowPointerAvailabilityChange = { available = rig.controller.slowPointerDevices }
        defer { rig.controller.onSlowPointerAvailabilityChange = nil }
        rig.controller.beginSpeedEdit(on: Fixtures.id)
        #expect(available.isEmpty)
        rig.controller.endSpeedEdit()
        #expect(available == [Fixtures.id])
        _ = rig.controller.selectPreset("turbo", on: Fixtures.id)
        #expect(available.isEmpty)
        rig.controller.confirmPending()
        #expect(available == [Fixtures.id])
    }
}
