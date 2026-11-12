import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Smooth scroller")
struct SmoothScrollerTests {
    private static let context = SmoothingContext(device: "046d:c52b", profile: "default", app: "com.example.app", flags: 0)

    final class Harness: @unchecked Sendable {
        private let lock = NSLock()
        private var _now = 100.0
        private var _posted: [SmoothScrollOutput] = []
        private var _starts = 0
        var now: TimeInterval {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
        var posted: [SmoothScrollOutput] { lock.withLock { _posted } }
        var starts: Int { lock.withLock { _starts } }
        lazy var scroller = SmoothScroller(
            clock: { [unowned self] in self.now },
            post: { [unowned self] output in self.lock.withLock { self._posted.append(output) } },
            startTicking: { [unowned self] _ in self.lock.withLock { self._starts += 1 } }
        )

        func run(for seconds: TimeInterval) {
            let end = now + seconds
            while now < end {
                scroller.tick()
                now += SmoothScroller.tickInterval
            }
        }
    }

    @Test func distanceIsDeliveredOverTimeAndTheWorkerStopsWhenIdle() {
        let harness = Harness()
        #expect(harness.scroller.enqueue(vertical: -30, horizontal: 0, context: Self.context, durationMilliseconds: 100))
        #expect(harness.starts == 1)
        // A second enqueue while the worker is already running doesn't ask for another one.
        #expect(harness.scroller.enqueue(vertical: -30, horizontal: 0, context: Self.context, durationMilliseconds: 100))
        #expect(harness.starts == 1)
        harness.run(for: 0.5)
        #expect(harness.posted.map(\.vertical).reduce(0, +) == -60)
        #expect(harness.posted.count > 3)
        #expect(harness.scroller.isIdle)
        #expect(harness.scroller.enqueue(vertical: -10, horizontal: 0, context: Self.context, durationMilliseconds: 100))
        #expect(harness.starts == 2)
    }

    @Test func nothingIsPostedAfterACancelAndTheLossIsAccounted() {
        let harness = Harness()
        _ = harness.scroller.enqueue(vertical: -100, horizontal: 40, context: Self.context, durationMilliseconds: 200)
        harness.run(for: 0.05)
        let posted = harness.posted
        let dropped = harness.scroller.cancel()
        harness.run(for: 1)
        #expect(harness.posted == posted)
        #expect(Double(posted.map(\.vertical).reduce(0, +)) + dropped.vertical == -100)
        #expect(Double(posted.map(\.horizontal).reduce(0, +)) + dropped.horizontal == 40)
        #expect(harness.scroller.discarded == dropped)
    }

    @Test func aSlowWorkerNeverGrowsTheQueuePastItsBound() {
        let harness = Harness()
        var accepted = 0
        for index in 0..<500 {
            if harness.scroller.enqueue(vertical: index.isMultiple(of: 2) ? 20 : -20, horizontal: 0, context: Self.context, durationMilliseconds: 100) { accepted += 1 }
        }
        #expect(accepted < 500)
        // What was accepted is bounded: draining delivers a bounded, finite amount.
        harness.run(for: 30)
        #expect(harness.scroller.isIdle)
        #expect(abs(harness.posted.map(\.vertical).reduce(0, +)) <= Int(SmoothScrollLimits.maxPendingPixels))
    }

    @Test func aWorkerThatNeverRunsRefusesInsteadOfSwallowing() {
        let harness = Harness()
        // No ticks at all: once the pending distance cap is reached further notches are refused (and so pass through).
        var refused = false
        for _ in 0..<1000 where !harness.scroller.enqueue(vertical: -50, horizontal: 0, context: Self.context, durationMilliseconds: 100) {
            refused = true
            break
        }
        #expect(refused)
    }
}
