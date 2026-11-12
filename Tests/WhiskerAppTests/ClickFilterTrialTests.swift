import Combine
import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Duplicate-click filter trial and local test", .serialized)
@MainActor
struct ClickFilterTrialTests {
    static let mouse = "046d:c52b"

    private func makeModel() throws -> (AppModel, URL) {
        let directory = try SettingsStoreTests.makeDirectory()
        return (AppModel(store: SettingsStore(directory: directory)), directory)
    }

    private func filter(_ model: AppModel) -> ClickDebounceSettings? {
        model.store.settings.devices[Self.mouse]?.clickDebounce
    }

    /// What `start()` does with settings, without the event tap, device monitoring or permission polling.
    private func followSettings(_ model: AppModel) -> AnyCancellable {
        model.store.$settings.removeDuplicates().sink { model.engine.update($0) }
    }

    private func switchOn(_ model: AppModel) {
        model.setClickFilter(device: Self.mouse, name: "Mouse", buttons: [3], interval: 0.05)
    }

    /// Waits for the main actor to run a timer or a copy from the event tap, which have no hook of their own to wait on.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    // MARK: Trial

    @Test func switchingOnStartsATrialAndKeepingEndsItButNotTheFilter() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.clickFilterTrialDuration = 0.05
        switchOn(model)
        #expect(filter(model) == ClickDebounceSettings(buttons: [3], interval: 0.05))
        #expect(model.store.settings.devices[Self.mouse]?.name == "Mouse")
        #expect(model.clickFilterTrials[Self.mouse] != nil)
        model.confirmClickFilter(device: Self.mouse)
        #expect(model.clickFilterTrials.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(filter(model) != nil)
    }

    @Test func anUnkeptFilterSwitchesItselfOff() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.clickFilterTrialDuration = 0.05
        switchOn(model)
        #expect(await waitUntil { model.clickFilterTrials.isEmpty })
        #expect(filter(model) == nil)
    }

    @Test func turningItOffOrClearingTheButtonsRemovesTheFilterAndItsTrial() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        switchOn(model)
        model.revertClickFilter(device: Self.mouse)
        #expect(filter(model) == nil)
        #expect(model.clickFilterTrials.isEmpty)

        switchOn(model)
        model.setClickFilter(device: Self.mouse, name: "Mouse", buttons: [], interval: 0.05)
        #expect(filter(model) == nil)
        #expect(model.clickFilterTrials.isEmpty)
    }

    @Test func quittingSwitchesFiltersOnTrialOff() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        switchOn(model)
        model.shutdown()
        #expect(filter(model) == nil)
        #expect(model.clickFilterTrials.isEmpty)
    }

    // MARK: Local test

    @Test func theLocalTestStartsResetsAndStopsOnlyWhileTheFilterIsOn() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let following = followSettings(model)
        defer { following.cancel() }
        let fresh = ClickFilterTally(device: Self.mouse, buttons: [3])
        model.startClickFilterTest(device: Self.mouse)
        try await Task.sleep(for: .milliseconds(50))
        #expect(model.clickFilterTest == nil)

        switchOn(model)
        model.startClickFilterTest(device: Self.mouse)
        #expect(await waitUntil { model.clickFilterTest == fresh })
        model.resetClickFilterTest()
        model.stopClickFilterTest()
        #expect(await waitUntil { model.clickFilterTest == nil })

        model.startClickFilterTest(device: Self.mouse)
        #expect(await waitUntil { model.clickFilterTest == fresh })
        model.revertClickFilter(device: Self.mouse)
        #expect(await waitUntil { model.clickFilterTest == nil })
    }

    @Test func aTrialThatRunsOutEndsTheLocalTest() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        let following = followSettings(model)
        defer { following.cancel() }
        model.clickFilterTrialDuration = 0.3
        switchOn(model)
        model.startClickFilterTest(device: Self.mouse)
        #expect(await waitUntil { model.clickFilterTest != nil })
        #expect(await waitUntil { model.clickFilterTest == nil })
        #expect(filter(model) == nil)
    }
}
