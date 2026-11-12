/// The local test in Devices: what the duplicate-click filter did with one mouse's presses since the test began,
/// counted per filtered button. Counts only, never times, order or positions, so there is no click history to log
/// or save. It lives in memory while the test runs and reaches the settings window as an immutable copy.
public struct ClickFilterTally: Equatable, Sendable {
    public struct Counts: Equatable, Sendable {
        /// Presses that got past the filter, at once or after being held back briefly.
        public var accepted: Int
        /// Presses the filter dropped, together with their releases, as duplicates.
        public var filtered: Int

        public init(accepted: Int = 0, filtered: Int = 0) {
            self.accepted = accepted
            self.filtered = filtered
        }
    }

    public enum Verdict: Sendable {
        case accepted
        case filtered
    }

    /// The mouse under test.
    public let device: String
    /// Counts for each button the filter is on for, and only those.
    public private(set) var buttons: [Int: Counts]

    public init(device: String, buttons: [Int]) {
        self.device = device
        self.buttons = Dictionary(uniqueKeysWithValues: Set(buttons).map { ($0, Counts()) })
    }

    public var isEmpty: Bool { buttons.values.allSatisfy { $0 == Counts() } }

    public subscript(button: Int) -> Counts? { buttons[button] }

    /// Counts a press of a button under test; any other button is ignored.
    public mutating func record(_ verdict: Verdict, button: Int) {
        guard var counts = buttons[button] else { return }
        switch verdict {
        case .accepted: counts.accepted += 1
        case .filtered: counts.filtered += 1
        }
        buttons[button] = counts
    }

    /// Back to zero for the same mouse and buttons.
    public mutating func clear() {
        for button in buttons.keys { buttons[button] = Counts() }
    }
}
