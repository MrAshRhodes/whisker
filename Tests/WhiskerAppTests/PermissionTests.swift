import Testing
@testable import Whisker

@Suite("Accessibility permission")
@MainActor
struct PermissionTests {
    final class FakeTrust {
        var trusted = true
    }

    @Test func revocationAndRestorationAreReported() {
        let fake = FakeTrust()
        let permission = AccessibilityPermission(check: { fake.trusted })
        var changes: [Bool] = []
        permission.onChange = { changes.append($0) }

        permission.refresh()
        fake.trusted = false
        permission.refresh()
        permission.refresh()
        fake.trusted = true
        permission.refresh()

        #expect(changes == [false, true])
        #expect(permission.isTrusted)
    }
}
