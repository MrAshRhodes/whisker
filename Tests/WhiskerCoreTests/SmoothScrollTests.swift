import Foundation
import Testing
@testable import WhiskerCore

@Suite("Smooth scrolling")
struct SmoothScrollTests {
    private static let mouse = DeviceAttribution(id: "046d:c52b", exact: true)
    private static let app = "com.example.app"
    private static let context = SmoothingContext(device: mouse.id, profile: "default", app: app, flags: 0)

    /// Runs the planner on a fake clock until idle, returning every generated event and the time it came at.
    private func drain(_ planner: inout SmoothScrollPlanner, from start: TimeInterval, step: TimeInterval = 1.0 / 120) -> [(time: TimeInterval, output: SmoothScrollOutput)] {
        var out: [(TimeInterval, SmoothScrollOutput)] = []
        var now = start
        for _ in 0..<5000 where !planner.isIdle {
            if let event = planner.tick(now: now) { out.append((now, event)) }
            now += step
        }
        return out
    }

    private func total(_ events: [(time: TimeInterval, output: SmoothScrollOutput)]) -> (Int, Int) {
        (events.map(\.output.vertical).reduce(0, +), events.map(\.output.horizontal).reduce(0, +))
    }

    // MARK: Planner

    @Test func aNotchIsSpreadOverItsDurationAndConservedExactly() {
        var planner = SmoothScrollPlanner()
        #expect(planner.enqueue(vertical: -30, horizontal: 0, context: Self.context, duration: 0.12, now: 10) == .accepted)
        let events = drain(&planner, from: 10)
        #expect(total(events) == (-30, 0))
        #expect(events.count > 3)
        #expect(events.allSatisfy { $0.output.vertical <= 0 }, "no overshoot or reversal inside one stretch")
        #expect(events.last!.time - 10 <= 0.12 + 1.0 / 120 + 1e-9)
        // Nothing runs before the first tick is due and nothing is left afterwards.
        #expect(planner.pending == (0, 0))
    }

    @Test func fractionalDistanceIsCarriedNotLost() {
        var planner = SmoothScrollPlanner()
        var delivered = 0
        var now = 0.0
        // 20 notches of 2.5 px, each fully delivered before the next, are 50 px in all.
        for _ in 0..<20 {
            _ = planner.enqueue(vertical: 2.5, horizontal: 0, context: Self.context, duration: 0.04, now: now)
            delivered += total(drain(&planner, from: now)).0
            now += 1
        }
        let pending = planner.pending.vertical
        #expect(Double(delivered) + pending == 50)
        #expect(delivered == 50)
        #expect(abs(pending) < 1)
    }

    @Test func subPixelDistanceWaitsForTheNextMovement() {
        var planner = SmoothScrollPlanner()
        _ = planner.enqueue(vertical: 0.4, horizontal: 0, context: Self.context, duration: 0.1, now: 0)
        #expect(total(drain(&planner, from: 0)).0 == 0)
        #expect(planner.pending.vertical == 0.4)
        _ = planner.enqueue(vertical: 0.7, horizontal: 0, context: Self.context, duration: 0.1, now: 1)
        #expect(total(drain(&planner, from: 1)).0 == 1)
        #expect(abs(planner.pending.vertical - 0.1) < 1e-9)
    }

    @Test func rapidNotchesInOneDirectionRetargetAndConserveBothAxes() {
        var planner = SmoothScrollPlanner()
        var events: [(time: TimeInterval, output: SmoothScrollOutput)] = []
        var now = 0.0
        for _ in 0..<12 {
            #expect(planner.enqueue(vertical: -30, horizontal: 10, context: Self.context, duration: 0.12, now: now) == .accepted)
            if let event = planner.tick(now: now + 0.004) { events.append((now + 0.004, event)) }
            now += 0.03
        }
        events += drain(&planner, from: now)
        let sum = total(events)
        #expect(sum.0 == -360 && sum.1 == 120)
        #expect(events.allSatisfy { $0.output.vertical <= 0 && $0.output.horizontal >= 0 })
        #expect(planner.segmentCount == 0)
    }

    @Test func diagonalMovementStaysTogetherOnOneTimeline() {
        var planner = SmoothScrollPlanner()
        _ = planner.enqueue(vertical: 40, horizontal: -20, context: Self.context, duration: 0.1, now: 0)
        let events = drain(&planner, from: 0)
        #expect(total(events) == (40, -20))
        // Both axes progress in the same events, proportionally, never one after the other.
        var vertical = 0, horizontal = 0
        for event in events {
            vertical += event.output.vertical
            horizontal += event.output.horizontal
            #expect(abs(Double(vertical) - Double(horizontal) * -2) <= 2)
        }
    }

    @Test func aReversalQueuesBehindTheStretchUnderWayInInputOrder() {
        var planner = SmoothScrollPlanner()
        _ = planner.enqueue(vertical: -50, horizontal: 0, context: Self.context, duration: 0.1, now: 0)
        _ = planner.enqueue(vertical: 30, horizontal: 0, context: Self.context, duration: 0.1, now: 0.02)
        #expect(planner.segmentCount == 2)
        let events = drain(&planner, from: 0.0)
        #expect(total(events).0 == -20)
        // Every downward step comes before the first upward one, and the path never overshoots -50.
        let signs = events.map { $0.output.vertical.signum() }.filter { $0 != 0 }
        #expect(signs == signs.sorted(by: <))
        var position = 0
        for event in events {
            position += event.output.vertical
            #expect(position >= -50)
        }
    }

    @Test func differentContextsAreNeverMerged() {
        var planner = SmoothScrollPlanner()
        var shifted = Self.context
        shifted.flags = 0x20000
        _ = planner.enqueue(vertical: -20, horizontal: 0, context: Self.context, duration: 0.1, now: 0)
        _ = planner.enqueue(vertical: -20, horizontal: 0, context: shifted, duration: 0.1, now: 0.01)
        #expect(planner.segmentCount == 2)
        let events = drain(&planner, from: 0)
        let flags = events.map(\.output.context.flags)
        #expect(flags == flags.sorted(by: { ($0 == 0 ? 0 : 1) < ($1 == 0 ? 0 : 1) }))
        #expect(events.filter { $0.output.context.flags == 0 }.map(\.output.vertical).reduce(0, +) == -20)
        #expect(events.filter { $0.output.context.flags == 0x20000 }.map(\.output.vertical).reduce(0, +) == -20)
    }

    @Test func aSlowWorkerCatchesUpInBoundedSteps() {
        var planner = SmoothScrollPlanner()
        _ = planner.enqueue(vertical: -100, horizontal: 0, context: Self.context, duration: 0.1, now: 0)
        _ = planner.enqueue(vertical: 60, horizontal: 0, context: Self.context, duration: 0.1, now: 0.01)
        // The first tick comes a whole second late: one event carries what was due, nothing is lost.
        let first = planner.tick(now: 1)
        #expect(first?.vertical == -100)
        let second = planner.tick(now: 1.0)
        #expect(second == nil || second?.vertical == 0 || second!.vertical > 0)
        var rest = 0
        var now = 1.0
        while !planner.isIdle, now < 3 {
            now += 1.0 / 120
            rest += planner.tick(now: now)?.vertical ?? 0
        }
        #expect(-100 + (second?.vertical ?? 0) + rest == -40)
    }

    @Test func workAndMemoryAreBounded() {
        var planner = SmoothScrollPlanner()
        var refused = 0
        for index in 0..<100 {
            // Alternating directions can't merge, so the queue itself is what is bounded.
            let sign = index.isMultiple(of: 2) ? 1.0 : -1.0
            if planner.enqueue(vertical: 30 * sign, horizontal: 0, context: Self.context, duration: 0.1, now: 0) == .refused { refused += 1 }
        }
        #expect(planner.segmentCount <= SmoothScrollLimits.maxSegments)
        #expect(refused > 0)

        var big = SmoothScrollPlanner()
        #expect(big.enqueue(vertical: 1e9, horizontal: 0, context: Self.context, duration: 0.1, now: 0) == .refused)
        #expect(big.enqueue(vertical: .nan, horizontal: 0, context: Self.context, duration: 0.1, now: 0) == .refused)
        #expect(big.isIdle)

        // A late worker never emits more than the per-event bound, and one event per tick.
        var late = SmoothScrollPlanner()
        _ = late.enqueue(vertical: 3900, horizontal: -3900, context: Self.context, duration: 0.1, now: 0)
        let event = late.tick(now: 99)
        #expect(abs(event?.vertical ?? 0) <= SmoothScrollLimits.maxEventPixels)
    }

    @Test func aStretchKeepsFinishingEvenWhileTheWheelKeepsTurning() {
        var planner = SmoothScrollPlanner()
        var now = 0.0
        var most = 0
        // A steady spin: the stretch under way keeps being retargeted, but it stops absorbing past its lifetime.
        for _ in 0..<200 {
            _ = planner.enqueue(vertical: -1, horizontal: 0, context: Self.context, duration: 0.4, now: now)
            _ = planner.tick(now: now)
            most = max(most, planner.segmentCount)
            now += 0.02
        }
        #expect(most >= 2)
        #expect(most <= SmoothScrollLimits.maxSegments)
    }

    @Test func cancellingAccountsForExactlyWhatWasDropped() {
        var planner = SmoothScrollPlanner()
        _ = planner.enqueue(vertical: -50, horizontal: 20, context: Self.context, duration: 0.1, now: 0)
        _ = planner.enqueue(vertical: 30.5, horizontal: 0, context: Self.context, duration: 0.1, now: 0)
        var delivered = (0, 0)
        for time in stride(from: 0.0, through: 0.05, by: 1.0 / 120) {
            if let event = planner.tick(now: time) {
                delivered.0 += event.vertical
                delivered.1 += event.horizontal
            }
        }
        let dropped = planner.cancel()
        #expect(dropped.segments == 2)
        #expect(Double(delivered.0) + dropped.vertical == -19.5)
        #expect(Double(delivered.1) + dropped.horizontal == 20)
        #expect(planner.discarded == dropped)
        #expect(planner.isIdle && planner.pending == (0, 0))
        // Never replayed, into this context or another.
        #expect(planner.tick(now: 5) == nil)
        var other = Self.context
        other.app = "com.example.other"
        _ = planner.enqueue(vertical: -10, horizontal: 0, context: other, duration: 0.1, now: 6)
        #expect(total(drain(&planner, from: 6)).0 == -10)
        #expect(planner.cancel().isEmpty)
    }

    @Test func movementForAnotherTargetDiscardsWhatWasWaiting() {
        var planner = SmoothScrollPlanner()
        _ = planner.enqueue(vertical: -50.5, horizontal: 0, context: Self.context, duration: 0.1, now: 0)
        var other = Self.context
        other.app = "com.example.other"
        _ = planner.enqueue(vertical: -10, horizontal: 0, context: other, duration: 0.1, now: 0.02)
        #expect(planner.discarded.vertical == -50.5)
        let events = drain(&planner, from: 0.02)
        #expect(total(events).0 == -10)
        #expect(events.allSatisfy { $0.output.context.app == "com.example.other" })
    }

    @Test func aDisconnectedDeviceCancelsOnlyItsOwnWork() {
        var planner = SmoothScrollPlanner()
        _ = planner.enqueue(vertical: -50, horizontal: 0, context: Self.context, duration: 0.1, now: 0)
        #expect(planner.cancel(unlessConnected: [Self.mouse.id]).isEmpty)
        #expect(!planner.isIdle)
        #expect(planner.cancel(unlessConnected: []).vertical == -50)
        #expect(planner.isIdle)
    }

    // MARK: Event processor

    private func compiled(_ scroll: ScrollSettings, mappings: [Mapping] = [], configure: (inout WhiskerSettings) -> Void = { _ in }) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].scroll = scroll
        settings.profiles[0].mappings = mappings
        configure(&settings)
        return CompiledSettings(settings)
    }

    private func event(_ sample: ScrollSample, _ device: DeviceAttribution? = mouse, modifiers: ModifierSet = []) -> InputEvent {
        InputEvent(.scroll(sample), modifiers: modifiers, timestamp: 0, device: device, app: Self.app)
    }

    private func request(_ plan: EventPlan) -> SmoothRequest? {
        if case let .smooth(request) = plan { return request }
        return nil
    }

    @Test func smoothingIsOffUnlessAskedFor() {
        var processor = EventProcessor()
        let notch = ScrollSample(vertical: .lines(-1))
        #expect(processor.process(event(notch), settings: compiled(ScrollSettings())) == .passThrough)
        #expect(request(processor.process(event(notch), settings: compiled(ScrollSettings(smoothScrolling: true)))) != nil)
    }

    @Test func smoothingRunsAfterTransformationsAndKeepsThemExclusive() throws {
        var processor = EventProcessor()
        let scroll = ScrollSettings(
            linesPerNotch: 4, horizontalModifier: .shift,
            modifierScaling: ModifierScaling(modifiers: .option, multiplier: 2), smoothScrolling: true, smoothDuration: 200
        )
        let settings = compiled(scroll) { $0.devices[Self.mouse.id] = DeviceSettings(wheel: WheelSettings(invertVertical: true)) }
        let plain = try #require(request(processor.process(event(ScrollSample(vertical: .lines(-1))), settings: settings)))
        // Inverted (-1 → 1), then four lines, then nothing more.
        #expect(plain.sample == ScrollSample(vertical: .lines(4)))
        #expect(plain.duration == 200 && plain.changed)

        let sideways = try #require(request(processor.process(event(ScrollSample(vertical: .lines(-1)), modifiers: .shift), settings: settings)))
        #expect(sideways.sample.vertical.isZero && sideways.sample.horizontal == .lines(4) && sideways.removing == .shift)

        let scaled = try #require(request(processor.process(event(ScrollSample(vertical: .lines(-1)), modifiers: .option), settings: settings)))
        #expect(scaled.sample == ScrollSample(vertical: .lines(8)) && scaled.removing == .option)
    }

    @Test func nativeModeInterpolatesTheDistanceWithoutSoftwareAcceleration() throws {
        var processor = EventProcessor()
        var settings = WhiskerSettings()
        settings.profiles[0].scroll = ScrollSettings(linesPerNotch: 4, acceleration: 1, smoothScrolling: true)
        let native = CompiledSettings(settings, nativeWheelActive: [Self.mouse.id])
        let smooth = try #require(request(processor.process(event(ScrollSample(vertical: .lines(-3))), settings: native)))
        #expect(smooth.sample == ScrollSample(vertical: .lines(-3)) && !smooth.changed)
        #expect(smooth.unsmoothed == .passThrough)
    }

    @Test func aMappedWheelDirectionActsAndNeverAlsoScrolls() {
        var processor = EventProcessor()
        let settings = compiled(ScrollSettings(smoothScrolling: true), mappings: [Mapping(trigger: .wheel(.up), action: .none)])
        #expect(processor.process(event(ScrollSample(vertical: .lines(1))), settings: settings) == .swallow)
        let action = compiled(ScrollSettings(smoothScrolling: true), mappings: [Mapping(trigger: .wheel(.up), action: .scroll(direction: .down, lines: 2))])
        #expect(processor.process(event(ScrollSample(vertical: .lines(1))), settings: action) == .perform(.scroll(direction: .down, lines: 2), .once))
    }

    @Test func onlyConfidentlyAttributedNotchesAreSmoothed() {
        var processor = EventProcessor()
        let settings = compiled(ScrollSettings(smoothScrolling: true))
        let notch = ScrollSample(vertical: .lines(-1))
        #expect(request(processor.process(event(notch, DeviceAttribution(id: "x", exact: false)), settings: settings)) == nil)
        #expect(request(processor.process(event(notch, nil), settings: settings)) == nil)
        let smooth = ScrollSample(vertical: ScrollAxis(lines: 0, fixed: -0.3, points: -3), isContinuous: true)
        #expect(processor.process(event(smooth), settings: settings) == .passThrough)
        let coasting = ScrollSample(vertical: ScrollAxis(lines: 0, fixed: -0.3, points: -3), isContinuous: true, isMomentum: true)
        #expect(processor.process(event(coasting), settings: settings) == .passThrough)
        #expect(processor.process(event(notch, modifiers: []), settings: compiled(ScrollSettings(smoothScrolling: true)) ) != .passThrough)
    }

    @Test func bypassAndDisabledDevicesAreNeverSmoothed() {
        var processor = EventProcessor()
        let notch = ScrollSample(vertical: .lines(-1))
        let bypassed = compiled(ScrollSettings(smoothScrolling: true)) { $0.general.bypassApps = [Self.app] }
        #expect(processor.process(event(notch), settings: bypassed) == .passThrough)
        let off = compiled(ScrollSettings(smoothScrolling: true)) { $0.devices[Self.mouse.id] = DeviceSettings(enabled: false) }
        #expect(processor.process(event(notch), settings: off) == .passThrough)
    }

    @Test func theOptInSidewaysStreamKeepsItsOwnPathAndNeverSmooths() {
        var processor = EventProcessor()
        let mapping = Mapping(trigger: .wheel(.left), action: .navigate(.back), continuousInput: ContinuousWheelInput(distance: 20))
        let settings = compiled(ScrollSettings(smoothScrolling: true), mappings: [mapping])
        let thumb = ScrollSample(horizontal: ScrollAxis(lines: 0, fixed: 0.4, points: 4), isContinuous: true)
        for _ in 0..<10 {
            let plan = processor.process(event(thumb), settings: settings)
            #expect(request(plan) == nil)
        }
    }

    @Test func aMappedWheelEventWithAnotherAxisLeftOverIsNotSmoothed() {
        var processor = EventProcessor()
        let mapping = Mapping(trigger: .wheel(.left), action: .navigate(.back), continuousInput: ContinuousWheelInput(distance: 20))
        let settings = compiled(ScrollSettings(smoothScrolling: true), mappings: [mapping])
        let diagonal = ScrollSample(vertical: ScrollAxis(lines: 0, fixed: -0.4, points: -4), horizontal: ScrollAxis(lines: 0, fixed: 0.4, points: 25), isContinuous: true)
        if case .smooth = processor.process(event(diagonal), settings: settings) { Issue.record("continuous input must not be smoothed") }
    }

    // MARK: Settings

    @Test func smoothingKeysAreOptionalAndOldFilesDecodeUnchanged() throws {
        let old = Data(#"{"linesPerNotch":3,"acceleration":0.5}"#.utf8)
        let decoded = try JSONDecoder().decode(ScrollSettings.self, from: old)
        #expect(decoded == ScrollSettings(linesPerNotch: 3, acceleration: 0.5))
        #expect(!decoded.smoothScrolling)
        let rewritten = String(decoding: try JSONEncoder().encode(decoded), as: UTF8.self)
        #expect(!rewritten.contains("smooth"))

        var settings = WhiskerSettings()
        settings.profiles[0].scroll = ScrollSettings(smoothScrolling: true, smoothDuration: 250)
        settings.unknownKeys["future"] = .string("kept")
        let again = try SettingsCodec.decode(SettingsCodec.encode(settings))
        #expect(again == settings)
        #expect(again.defaultProfile.scroll?.smoothDuration == 250)
    }

    @Test func durationIsBoundedAndInheritedWithTheScrollSettings() {
        var settings = WhiskerSettings()
        settings.profiles[0].scroll = ScrollSettings(smoothScrolling: true, smoothDuration: 5000)
        settings.profiles.append(Profile(id: "child", name: "Child", match: ProfileMatch(apps: [Self.app])))
        let issues = settings.validate()
        #expect(issues.contains { $0.path.hasSuffix("scroll.smoothDuration") })
        #expect(settings.repaired().defaultProfile.scroll?.smoothDuration == ScrollMath.smoothDurationRange.upperBound)
        #expect(settings.resolvedProfile(id: "child").scroll.smoothScrolling)
    }
}
