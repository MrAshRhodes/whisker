import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Button swap trial", .serialized)
@MainActor
struct ButtonSwapTrialTests {
    static let mouse = "046d:c52b"

    private func makeModel(allowPrimary: Bool = true) throws -> (AppModel, URL) {
        let directory = try SettingsStoreTests.makeDirectory()
        let model = AppModel(store: SettingsStore(directory: directory))
        model.store.settings.general.allowPrimaryButtonRemap = allowPrimary
        return (model, directory)
    }

    private func swapped(_ model: AppModel, _ id: String = mouse) -> Bool {
        model.store.settings.devices[id]?.swapPrimarySecondary ?? false
    }

    /// Waits for the main actor to run the trial's timer, which has no hook of its own to wait on.
    private func waitUntil(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<200 {
            if condition() { return true }
            try? await Task.sleep(for: .milliseconds(10))
        }
        return condition()
    }

    @Test func doesNothingWhileThePrimaryButtonMayNotBeRemapped() throws {
        let (model, directory) = try makeModel(allowPrimary: false)
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setSwapPrimarySecondary(device: Self.mouse, name: "Mouse", on: true)
        #expect(!swapped(model))
        #expect(model.swapTrials.isEmpty)
        #expect(!model.store.settings.general.allowPrimaryButtonRemap)
    }

    @Test func switchingOnStartsATrialAndRemembersTheName() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setSwapPrimarySecondary(device: Self.mouse, name: "Logitech Mouse", on: true)
        #expect(swapped(model))
        #expect(model.store.settings.devices[Self.mouse]?.name == "Logitech Mouse")
        #expect(model.swapTrials[Self.mouse] != nil)
    }

    @Test func keepingEndsTheTrialButNotTheSwap() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.swapTrialDuration = 0.05
        model.setSwapPrimarySecondary(device: Self.mouse, name: "Mouse", on: true)
        model.confirmSwap(device: Self.mouse)
        #expect(model.swapTrials.isEmpty)
        try await Task.sleep(for: .milliseconds(200))
        #expect(swapped(model))
    }

    @Test func switchingOffAndRevertingPutTheButtonsBack() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setSwapPrimarySecondary(device: Self.mouse, name: "Mouse", on: true)
        model.setSwapPrimarySecondary(device: Self.mouse, name: "Mouse", on: false)
        #expect(!swapped(model))
        #expect(model.swapTrials.isEmpty)

        model.setSwapPrimarySecondary(device: Self.mouse, name: "Mouse", on: true)
        model.revertSwap(device: Self.mouse)
        #expect(!swapped(model))
        #expect(model.swapTrials.isEmpty)
    }

    @Test func anUnconfirmedSwapSwitchesItselfOff() async throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.swapTrialDuration = 0.05
        model.setSwapPrimarySecondary(device: Self.mouse, name: "Mouse", on: true)
        #expect(await waitUntil { model.swapTrials.isEmpty })
        #expect(!swapped(model))
    }

    @Test func trialsAreIndependentPerMouse() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setSwapPrimarySecondary(device: Self.mouse, name: "Mouse", on: true)
        model.setSwapPrimarySecondary(device: "05ac:0304", name: "Other", on: true)
        model.revertSwap(device: "05ac:0304")
        #expect(swapped(model))
        #expect(model.swapTrials[Self.mouse] != nil)
        #expect(!swapped(model, "05ac:0304"))
    }

    @Test func quittingPutsTrialSwapsBack() throws {
        let (model, directory) = try makeModel()
        defer { try? FileManager.default.removeItem(at: directory) }
        model.setSwapPrimarySecondary(device: Self.mouse, name: "Mouse", on: true)
        model.shutdown()
        #expect(!swapped(model))
        #expect(model.swapTrials.isEmpty)
    }
}
