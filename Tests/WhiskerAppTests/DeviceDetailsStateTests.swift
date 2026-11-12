import Testing
@testable import Whisker

@Suite("Device details state")
@MainActor
struct DeviceDetailsStateTests {
    @Test func closingTheDetailsHidesTheSerialNumberAgain() {
        let state = DeviceDetailsState()
        #expect(!state.isOpen && !state.showsSerial)

        state.setOpen(true)
        state.toggleSerial()
        #expect(state.isOpen && state.showsSerial)

        state.setOpen(false)
        #expect(!state.isOpen && !state.showsSerial)

        state.setOpen(true)
        #expect(!state.showsSerial)
    }
}
