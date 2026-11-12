import Foundation
import Testing
import WhiskerCore
@testable import Whisker

@Suite("Auto-scroller")
struct AutoScrollerTests {
    static let anchor = PointerPoint(x: 400, y: 300)

    static func session(generation: Int = 1, anchor: PointerPoint = anchor, config: AutoScroll = AutoScroll()) -> AutoScrollSession {
        AutoScrollSession(generation: generation, key: MappingKey(.button(3)), anchor: anchor, config: config)
    }

    static func below(_ distance: Double, of point: PointerPoint = anchor) -> PointerPoint {
        PointerPoint(x: point.x, y: point.y + distance)
    }

    /// A scroller with a clock, a pointer and a post of its own. Nothing is ever posted to the system, and the
    /// test drives every tick.
    final class Harness: @unchecked Sendable {
        struct Post: Equatable {
            var pixels: ScrollPixels
            var anchor: PointerPoint
        }

        private let lock = NSLock()
        private var _now = 100.0
        private var _pointer: PointerPoint? = AutoScrollerTests.anchor
        private var _posted: [Post] = []
        private var _starts = 0
        var now: TimeInterval {
            get { lock.withLock { _now } }
            set { lock.withLock { _now = newValue } }
        }
        var pointer: PointerPoint? {
            get { lock.withLock { _pointer } }
            set { lock.withLock { _pointer = newValue } }
        }
        var posted: [Post] { lock.withLock { _posted } }
        var starts: Int { lock.withLock { _starts } }
        var scrolledVertically: Int { posted.map(\.pixels.vertical).reduce(0, +) }
        lazy var scroller = AutoScroller(
            clock: { [unowned self] in self.now },
            pointer: { [unowned self] in self.pointer },
            post: { [unowned self] pixels, anchor in self.lock.withLock { self._posted.append(Post(pixels: pixels, anchor: anchor)) } },
            startTicking: { [unowned self] _ in self.lock.withLock { self._starts += 1 } }
        )

        /// Ticks at the timer's pace. The clock ends one interval past the last tick.
        @discardableResult
        func run(for seconds: TimeInterval) -> TimeInterval {
            let begin = now
            let end = begin + seconds
            var lastTick = begin
            while now < end {
                lastTick = now
                scroller.tick()
                now += AutoScroller.tickInterval
            }
            return lastTick - begin
        }
    }

    final class Counter: @unchecked Sendable {
        private let lock = NSLock()
        private var _value = 0
        var value: Int { lock.withLock { _value } }
        func increment() { lock.withLock { _value += 1 } }
    }

    final class Flag: @unchecked Sendable {
        private let lock = NSLock()
        private var _isSet = false
        var isSet: Bool { lock.withLock { _isSet } }
        func set() { lock.withLock { _isSet = true } }
    }

    @Test func scrollsAtTheSpeedTheDistanceSetsAndAddressesTheAnchor() {
        let harness = Harness()
        harness.pointer = Self.below(100)
        harness.scroller.start(Self.session())
        let elapsed = harness.run(for: 1)

        // 100 points below with a 12 point dead zone is 88 of the 240 point ramp: 440 pixels a second, downwards.
        #expect(abs(Double(harness.scrolledVertically) + 440 * elapsed) < 2)
        #expect(harness.posted.allSatisfy { $0.anchor == Self.anchor && $0.pixels.horizontal == 0 })
        #expect(harness.posted.count > 50)
    }

    @Test func aPointerInsideTheDeadZoneScrollsNothing() {
        let harness = Harness()
        harness.pointer = Self.below(8)
        harness.scroller.start(Self.session())
        harness.run(for: 1)
        #expect(harness.posted.isEmpty)
    }

    @Test func nothingIsPostedAfterACancelAndTheTimerStopsAtItsNextTick() {
        let harness = Harness()
        harness.pointer = Self.below(150)
        harness.scroller.start(Self.session())
        harness.run(for: 0.2)
        let posted = harness.posted
        #expect(!posted.isEmpty)

        harness.scroller.cancel()
        #expect(harness.scroller.runningGeneration == nil)
        harness.run(for: 1)
        #expect(harness.posted == posted)
        #expect(harness.scroller.isIdle)
    }

    @Test func theTimerIsRequestedOnceWhateverIsStartedAndAgainAfterItWentIdle() {
        let harness = Harness()
        #expect(harness.scroller.isIdle)
        harness.scroller.start(Self.session(generation: 1))
        harness.scroller.start(Self.session(generation: 2))
        #expect(harness.starts == 1)
        #expect(!harness.scroller.isIdle)

        harness.scroller.cancel()
        harness.scroller.tick()
        #expect(harness.scroller.isIdle)
        harness.scroller.start(Self.session(generation: 3))
        #expect(harness.starts == 2)
    }

    @Test func aReplacementCountsFromNowAndAddressesItsOwnAnchor() {
        let harness = Harness()
        let other = PointerPoint(x: 900, y: 120)
        harness.pointer = Self.below(150)
        harness.scroller.start(Self.session(generation: 1))
        harness.run(for: 0.3)
        let before = harness.posted.count

        harness.now += 5
        harness.pointer = Self.below(150, of: other)
        harness.scroller.start(Self.session(generation: 2, anchor: other))
        #expect(harness.scroller.runningGeneration == 2)
        // Time that passed before the replacement is nobody's.
        harness.scroller.tick()
        #expect(harness.posted.count == before)

        harness.now += AutoScroller.tickInterval
        harness.run(for: 0.5)
        let after = harness.posted.dropFirst(before)
        #expect(!after.isEmpty)
        #expect(after.allSatisfy { $0.anchor == other })
    }

    @Test func aStalledTimerCarriesOnAtItsOwnPaceInsteadOfCatchingUp() {
        let harness = Harness()
        harness.pointer = Self.below(100)
        harness.scroller.start(Self.session())
        harness.now += 30
        harness.scroller.tick()
        // At most 0.1 s of a 440 pixel second.
        #expect(abs(harness.scrolledVertically) <= 44)
    }

    @Test func aPointerThatCantBeReadPausesScrollingAndResumesWithoutABurst() {
        let harness = Harness()
        harness.scroller.start(Self.session())
        harness.pointer = nil
        harness.run(for: 1)
        #expect(harness.posted.isEmpty)

        // The pause was spent resting on the anchor, so the first tick back owes one interval, not the whole second.
        harness.pointer = Self.below(100)
        harness.scroller.tick()
        #expect(abs(harness.scrolledVertically) <= 5)
    }

    @Test func nothingLeavesOnceACancelHasReturnedEvenWithTheTimerRunning() {
        let posts = Counter()
        let scroller = AutoScroller(
            clock: { ProcessInfo.processInfo.systemUptime },
            pointer: { Self.below(200) },
            post: { _, _ in posts.increment() },
            startTicking: { _ in }
        )
        let finished = Flag()
        let ticker = Thread {
            while !finished.isSet {
                scroller.tick()
                Thread.sleep(forTimeInterval: 0.0005)
            }
        }
        ticker.start()
        defer { finished.set() }

        for round in 1...20 {
            scroller.start(Self.session(generation: round))
            let before = posts.value
            for _ in 0..<1000 where posts.value == before { Thread.sleep(forTimeInterval: 0.002) }
            #expect(posts.value > before)
            scroller.cancel()
            let atCancel = posts.value
            Thread.sleep(forTimeInterval: 0.005)
            #expect(posts.value == atCancel)
        }
    }

    @Test func theRealTimerRunsOnlyWhileThereIsASession() {
        let posts = Counter()
        let scroller = AutoScroller(
            clock: { ProcessInfo.processInfo.systemUptime },
            pointer: { Self.below(200) },
            post: { _, _ in posts.increment() }
        )
        #expect(scroller.isIdle)
        scroller.start(Self.session())
        for _ in 0..<500 where posts.value == 0 { Thread.sleep(forTimeInterval: 0.01) }
        #expect(posts.value > 0)

        scroller.cancel()
        for _ in 0..<500 where !scroller.isIdle { Thread.sleep(forTimeInterval: 0.01) }
        #expect(scroller.isIdle)
        let atIdle = posts.value
        Thread.sleep(forTimeInterval: 0.1)
        #expect(posts.value == atIdle)
    }
}
