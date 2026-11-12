import Foundation
import Testing
@testable import WhiskerCore

@Suite("Auto-scroll")
struct AutoScrollTests {
    private static let ball = DeviceAttribution(id: "046d:c52b", exact: true)
    private static let anchor = PointerPoint(x: 400, y: 300)
    private static let elsewhere = PointerPoint(x: 900, y: 120)
    private static let app = "com.example.app"

    private func compiled(_ config: AutoScroll = AutoScroll(), configure: (inout WhiskerSettings) -> Void = { _ in }) -> CompiledSettings {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .button(3), action: .autoScroll(config))]
        configure(&settings)
        return CompiledSettings(settings)
    }

    private func press(_ button: Int = 3, at location: PointerPoint? = anchor) -> InputEvent {
        InputEvent(.buttonDown(button), device: Self.ball, app: Self.app, location: location)
    }

    private func release(_ button: Int = 3) -> InputEvent {
        InputEvent(.buttonUp(button), device: Self.ball, app: Self.app)
    }

    private func wheel(_ sample: ScrollSample) -> InputEvent {
        InputEvent(.scroll(sample), device: Self.ball, app: Self.app)
    }

    private func pointer(below dy: Double = 0, right dx: Double = 0) -> PointerPoint {
        PointerPoint(x: Self.anchor.x + dx, y: Self.anchor.y + dy)
    }

    private func driver(_ config: AutoScroll = AutoScroll()) -> AutoScrollDriver {
        AutoScrollDriver(session: AutoScrollSession(generation: 1, key: MappingKey(.button(3)), anchor: Self.anchor, config: config), now: 0)
    }

    /// Asks the driver every `steps` seconds (cycling through them) until `end`, with the pointer held where it is.
    private func run(_ driver: inout AutoScrollDriver, at pointer: PointerPoint, until end: TimeInterval, every steps: [TimeInterval]) -> (pixels: ScrollPixels, elapsed: TimeInterval) {
        var now = 0.0
        var total = ScrollPixels()
        var index = 0
        while now < end {
            now += steps[index % steps.count]
            index += 1
            let pixels = driver.advance(pointer: pointer, now: now)
            total.vertical += pixels.vertical
            total.horizontal += pixels.horizontal
        }
        return (total, now)
    }

    // MARK: Speed from distance

    @Test func speedRisesEvenlyFromTheEdgeOfTheDeadZoneAndStopsAtTheMaximum() {
        let config = AutoScroll(deadZone: 20, maxSpeed: 1000)
        func vertical(_ dy: Double) -> Double { config.velocity(from: Self.anchor, to: pointer(below: dy)).vertical }
        #expect(vertical(0) == 0)
        #expect(vertical(20) == 0)
        #expect(vertical(20 + AutoScroll.rampDistance / 2) == -500)
        #expect(vertical(20 + AutoScroll.rampDistance) == -1000)
        #expect(vertical(20_000) == -1000)
    }

    @Test func belowAndRightScrollDownAndRightAndAboveAndLeftTheOtherWay() {
        let config = AutoScroll(axes: .twoAxis)
        #expect(config.velocity(from: Self.anchor, to: pointer(below: 100)).vertical < 0)
        #expect(config.velocity(from: Self.anchor, to: pointer(below: -100)).vertical > 0)
        #expect(config.velocity(from: Self.anchor, to: pointer(right: 100)).horizontal < 0)
        #expect(config.velocity(from: Self.anchor, to: pointer(right: -100)).horizontal > 0)
        let diagonal = config.velocity(from: Self.anchor, to: pointer(below: 100, right: -100))
        #expect(diagonal.vertical < 0)
        #expect(diagonal.horizontal > 0)
    }

    @Test func verticalOnlyIgnoresTheSidewaysOffset() {
        let sideways = pointer(right: 500)
        #expect(AutoScroll(axes: .vertical).velocity(from: Self.anchor, to: sideways) == AutoScrollVelocity())
        #expect(AutoScroll(axes: .twoAxis).velocity(from: Self.anchor, to: sideways).horizontal < 0)
        let both = pointer(below: 80, right: 500)
        #expect(AutoScroll(axes: .vertical).velocity(from: Self.anchor, to: both).horizontal == 0)
        #expect(AutoScroll(axes: .vertical).velocity(from: Self.anchor, to: both).vertical < 0)
    }

    @Test func limitsAreInclusiveAndNonNumbersAreNeverValid() {
        let valid = [AutoScroll(deadZone: 4, maxSpeed: 100), AutoScroll(deadZone: 120, maxSpeed: 6000), AutoScroll()]
        let invalid = [
            AutoScroll(deadZone: 3.9), AutoScroll(deadZone: 120.1), AutoScroll(maxSpeed: 99), AutoScroll(maxSpeed: 6001),
            AutoScroll(deadZone: .nan), AutoScroll(maxSpeed: .infinity),
        ]
        let validResults = valid.map { $0.isValid }
        let invalidResults = invalid.map { $0.isValid }
        #expect(validResults == [true, true, true])
        #expect(invalidResults == Array(repeating: false, count: invalid.count))
    }

    // MARK: Driver

    @Test func nothingScrollsInsideTheDeadZoneOrAtTheInstantItStarts() {
        var inside = driver(AutoScroll(axes: .twoAxis, deadZone: 12))
        for spot in [pointer(), pointer(below: 12), pointer(below: -12, right: 12), pointer(below: 8, right: -8)] {
            #expect(run(&inside, at: spot, until: 1, every: [1.0 / 60]).pixels == ScrollPixels())
        }
        var fresh = driver()
        #expect(fresh.advance(pointer: pointer(below: 5000), now: 0) == ScrollPixels())
    }

    @Test func justOutsideTheDeadZoneCreepsInsteadOfJumping() {
        var creeping = driver(AutoScroll(deadZone: 12, maxSpeed: 1200))
        // 0.5 points past the edge is 2.5 pixels a second.
        #expect(run(&creeping, at: pointer(below: 12.5), until: 1, every: [1.0 / 60]).pixels == ScrollPixels(vertical: -2))
    }

    @Test func aStillPointerOutsideTheZoneScrollsAtTheSameRateWhateverTheTickRate() {
        let held = pointer(below: 100, right: 50)
        // (100 - 12) / 240 of 1200 pixels a second vertically, (50 - 12) / 240 of it sideways.
        let vertical = 440.0, horizontal = 190.0
        for steps in [[1.0 / 60], [1.0 / 120], [1.0 / 30], [0.001], [0.004, 0.011, 0.02, 0.0083]] {
            var driver = driver(AutoScroll(axes: .twoAxis, deadZone: 12, maxSpeed: 1200))
            let result = run(&driver, at: held, until: 2, every: steps)
            #expect(abs(Double(-result.pixels.vertical) - vertical * result.elapsed) < 1)
            #expect(abs(Double(-result.pixels.horizontal) - horizontal * result.elapsed) < 1)
        }
    }

    @Test func afterAStallScrollingCarriesOnAtItsOwnPaceInsteadOfCatchingUp() {
        var driver = driver()
        let held = pointer(below: 12 + AutoScroll.rampDistance)
        _ = driver.advance(pointer: held, now: 0.01)
        let afterStall = driver.advance(pointer: held, now: 5)
        #expect((-120)...(-119) ~= afterStall.vertical)
        #expect((-13)...(-11) ~= driver.advance(pointer: held, now: 5.01).vertical)
    }

    @Test func leavingTheZoneDropsWhatWasOwedSoNoStrayPixelFollows() {
        var driver = driver()
        let step = 1.0 / 120
        // 0.6 of a pixel is owed each step at 72 pixels a second.
        let slow = pointer(below: 26.4)
        #expect(driver.advance(pointer: slow, now: step).vertical == 0)
        #expect(driver.advance(pointer: pointer(), now: 2 * step) == ScrollPixels())
        #expect(driver.advance(pointer: slow, now: 3 * step).vertical == 0)
    }

    @Test func turningRoundDoesNotNetTheNewDirectionAgainstTheOldOne() {
        var driver = driver()
        let step = 1.0 / 120
        #expect(driver.advance(pointer: pointer(below: 26.4), now: step).vertical == 0)
        #expect(driver.advance(pointer: pointer(below: -26.4), now: 2 * step).vertical == 0)
        #expect(driver.advance(pointer: pointer(below: -26.4), now: 3 * step).vertical == 1)
    }

    @Test func oddClocksAndPointersProduceNothingInsteadOfTrapping() {
        var driver = driver()
        let held = pointer(below: 200)
        _ = driver.advance(pointer: held, now: 1)
        #expect(driver.advance(pointer: held, now: 0.5) == ScrollPixels())
        #expect(driver.advance(pointer: held, now: .nan) == ScrollPixels())
        #expect(driver.advance(pointer: held, now: .infinity) == ScrollPixels())
        #expect(driver.advance(pointer: PointerPoint(x: .nan, y: .nan), now: 2) == ScrollPixels())
        #expect(driver.advance(pointer: PointerPoint(x: .infinity, y: -.infinity), now: 2.05) == ScrollPixels())
        #expect(driver.advance(pointer: held, now: 2.1).vertical < 0)
    }

    // MARK: Starting and stopping

    @Test func pressingTheTriggerAnchorsWhereThePointerIsAndSwallowsTheButton() {
        var processor = EventProcessor()
        let config = AutoScroll(axes: .twoAxis, deadZone: 20, maxSpeed: 2000)
        let settings = compiled(config)
        #expect(processor.autoScrollSession == nil)
        #expect(processor.process(press(), settings: settings) == .swallow)
        #expect(processor.autoScrollSession == AutoScrollSession(generation: 1, key: MappingKey(.button(3)), anchor: Self.anchor, config: config))
        // Moving with the button down is plain movement, and letting go leaves it running.
        let drag = InputEvent(.buttonDragged(3), device: Self.ball, app: Self.app, location: pointer(below: 40))
        #expect(processor.process(drag, settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
        #expect(processor.autoScrollSession?.generation == 1)
        #expect(!processor.isHolding)
        #expect(!settings.needsMotion)
    }

    @Test func pressingTheSameTriggerAgainStopsItAndDoesNothingElse() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(release(), settings: settings)
        #expect(processor.process(press(), settings: settings) == .swallow)
        #expect(processor.autoScrollSession == nil)
        #expect(processor.process(release(), settings: settings) == .swallow)

        #expect(processor.process(press(at: Self.elsewhere), settings: settings) == .swallow)
        #expect(processor.autoScrollSession?.generation == 2)
        #expect(processor.autoScrollSession?.anchor == Self.elsewhere)
    }

    @Test func anyOtherClickStopsItAndStillReachesWhatIsUnderThePointer() {
        for button in [0, 1, 2, 5] {
            var processor = EventProcessor()
            let settings = compiled()
            _ = processor.process(press(), settings: settings)
            _ = processor.process(release(), settings: settings)
            #expect(processor.process(press(button), settings: settings) == .passThrough)
            #expect(processor.autoScrollSession == nil)
            #expect(processor.process(release(button), settings: settings) == .passThrough)
        }
    }

    @Test func aClickWithAMappingStopsItAndThenDoesItsOwnJob() {
        var processor = EventProcessor()
        let settings = compiled { $0.profiles[0].mappings.append(Mapping(trigger: .button(4), action: .navigate(.back))) }
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(press(4), settings: settings) == .perform(.navigate(.back), .once))
        #expect(processor.autoScrollSession == nil)
    }

    @Test func aSwappedPressOrASlowPointerPressStopsItAndThenDoesItsOwnJob() {
        let swapping = compiled {
            $0.general.allowPrimaryButtonRemap = true
            $0.devices[Self.ball.id] = DeviceSettings(swapPrimarySecondary: true)
        }
        var swapped = EventProcessor()
        _ = swapped.process(press(), settings: swapping)
        #expect(swapped.process(press(0), settings: swapping) == .perform(.click(button: 1, modifiers: []), .down))
        #expect(swapped.autoScrollSession == nil)

        let slowing = compiled { $0.profiles[0].mappings.append(Mapping(trigger: .button(4), action: .slowPointer(factor: 0.5))) }
        var slowed = EventProcessor()
        _ = slowed.process(press(), settings: slowing)
        #expect(slowed.process(press(4), settings: slowing, slowPointerDevices: [Self.ball.id]) == .swallow)
        #expect(slowed.autoScrollSession == nil)
        #expect(slowed.slowPointerCommand.factors == [Self.ball.id: 0.5])
    }

    @Test func anotherAutoScrollTriggerReplacesItAtTheNewAnchor() {
        var processor = EventProcessor()
        let second = AutoScroll(axes: .twoAxis)
        let settings = compiled { $0.profiles[0].mappings.append(Mapping(trigger: .button(4), action: .autoScroll(second))) }
        _ = processor.process(press(), settings: settings)
        #expect(processor.process(press(4, at: Self.elsewhere), settings: settings) == .swallow)
        #expect(processor.autoScrollSession == AutoScrollSession(generation: 2, key: MappingKey(.button(4)), anchor: Self.elsewhere, config: second))
    }

    @Test func aRealTurnOfTheWheelStopsItWithoutChangingWhatHappensToTheWheel() {
        let samples = [
            ScrollSample(vertical: .lines(1)), ScrollSample(vertical: .lines(-2)), ScrollSample(horizontal: .lines(1)),
            ScrollSample(vertical: ScrollAxis(points: 12), isContinuous: true),
        ]
        for sample in samples {
            var processor = EventProcessor()
            let settings = compiled()
            _ = processor.process(press(), settings: settings)
            var control = EventProcessor()
            #expect(processor.process(wheel(sample), settings: settings) == control.process(wheel(sample), settings: settings))
            #expect(processor.autoScrollSession == nil)
        }
    }

    @Test func momentumAndEmptyScrollEventsLeaveItRunning() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.process(wheel(ScrollSample(vertical: ScrollAxis(points: 8), isMomentum: true)), settings: settings)
        _ = processor.process(wheel(ScrollSample()), settings: settings)
        #expect(processor.autoScrollSession?.generation == 1)
    }

    @Test func aPressWhileWhiskerIsOffOrStandingAsideStillStopsIt() {
        let off = compiled { $0.general.enabled = false }
        let aside = compiled { $0.general.bypassApps = [Self.app] }
        for settings in [off, aside] {
            var processor = EventProcessor()
            _ = processor.process(press(), settings: compiled())
            #expect(processor.process(press(0), settings: settings) == .passThrough)
            #expect(processor.autoScrollSession == nil)
        }
        var scrolling = EventProcessor()
        _ = scrolling.process(press(), settings: compiled())
        _ = scrolling.process(wheel(ScrollSample(vertical: .lines(1))), settings: off)
        #expect(scrolling.autoScrollSession == nil)
    }

    @Test func lettingGoOfEverythingStopsItAndSoDoesCancellingItFromOutside() {
        var processor = EventProcessor()
        let settings = compiled()
        _ = processor.process(press(), settings: settings)
        _ = processor.releaseAll()
        #expect(processor.autoScrollSession == nil)

        _ = processor.process(press(), settings: settings)
        #expect(processor.autoScrollSession?.generation == 2)
        _ = processor.releaseAllForBypass()
        #expect(processor.autoScrollSession == nil)

        _ = processor.process(press(), settings: settings)
        processor.cancelAutoScroll()
        #expect(processor.autoScrollSession == nil)
        // The button is still down: it stays swallowed, and its movement stays movement, until it comes up.
        let drag = InputEvent(.buttonDragged(3), device: Self.ball, app: Self.app, location: pointer(below: 40))
        #expect(processor.process(drag, settings: settings) == .dragAsMove)
        #expect(processor.process(release(), settings: settings) == .swallow)
    }

    @Test func withoutAPositionOrWithOutOfRangeValuesThePressPassesThrough() {
        var processor = EventProcessor()
        #expect(processor.process(press(at: nil), settings: compiled()) == .passThrough)
        #expect(processor.autoScrollSession == nil)
        for bad in [AutoScroll(deadZone: 1), AutoScroll(deadZone: 500), AutoScroll(maxSpeed: 10), AutoScroll(maxSpeed: .nan)] {
            #expect(processor.process(press(), settings: compiled(bad)) == .passThrough)
            #expect(processor.autoScrollSession == nil)
            #expect(processor.process(release(), settings: compiled(bad)) == .passThrough)
        }
    }

    @Test func noAutoScrollStartsWhileAHoldToScrollIsInProgress() {
        var processor = EventProcessor()
        let settings = compiled { $0.profiles[0].mappings.append(Mapping(trigger: .button(4), action: .holdToScroll(HoldScroll()))) }
        _ = processor.process(press(4), settings: settings)
        #expect(processor.isHolding)
        #expect(processor.process(press(), settings: settings) == .swallow)
        #expect(processor.autoScrollSession == nil)
        #expect(processor.isHolding)
        #expect(processor.process(release(), settings: settings) == .swallow)
    }

    // MARK: Settings

    @Test func settingsRoundTripAndMissingValuesFallBackToTheDefaults() throws {
        let config = AutoScroll(axes: .twoAxis, deadZone: 30, maxSpeed: 2500)
        let decoded = try SettingsCodec.decode(SettingsCodec.encode(compiled(config).settings))
        #expect(decoded.profiles[0].mappings == [Mapping(trigger: .button(3), action: .autoScroll(config))])

        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(Action.autoScroll(config))) as? [String: Any]
        #expect(json?["kind"] as? String == "autoScroll")
        #expect(json?["axes"] as? String == "twoAxis")
        #expect(json?["deadZone"] as? Double == 30)
        #expect(json?["maxSpeed"] as? Double == 2500)

        #expect(try JSONDecoder().decode(Action.self, from: Data(#"{"kind":"autoScroll"}"#.utf8)) == .autoScroll(AutoScroll()))
        #expect(try JSONDecoder().decode(Action.self, from: Data(#"{"kind":"autoScroll","axes":"twoAxis"}"#.utf8)) == .autoScroll(AutoScroll(axes: .twoAxis)))
    }

    @Test func filesFromBeforeAutoScrollLoadAsTheyWereAndKeepTheirUnknownKeys() throws {
        let old = """
        {"schemaVersion":1,"general":{"enabled":true},"future":{"x":[1,true,null]},"profiles":[{"id":"default","mappings":[
        {"trigger":{"type":"button","button":3},"action":{"kind":"holdToScroll","axes":"free"}},
        {"trigger":{"type":"button","button":4},"action":{"kind":"navigate","direction":"forward"}}]}]}
        """
        var settings = try SettingsCodec.decodeValidated(Data(old.utf8))
        #expect(settings.schemaVersion == WhiskerSettings.currentSchemaVersion)
        #expect(settings.defaultProfile.mappings == [
            Mapping(trigger: .button(3), action: .holdToScroll(HoldScroll(axes: .free))),
            Mapping(trigger: .button(4), action: .navigate(.forward)),
        ])

        settings.profiles[0].mappings.append(Mapping(trigger: .button(5), action: .autoScroll(AutoScroll())))
        let reloaded = try SettingsCodec.decodeValidated(SettingsCodec.encode(settings))
        #expect(reloaded == settings)
        #expect(reloaded.schemaVersion == settings.schemaVersion)
        #expect(reloaded.unknownKeys["future"] == .object(["x": .array([.number(1), .bool(true), .null])]))
    }

    @Test func outOfRangeValuesAreReportedAndTheMappingDropped() {
        for bad in [AutoScroll(deadZone: 2), AutoScroll(deadZone: 500), AutoScroll(maxSpeed: 20), AutoScroll(maxSpeed: 90_000)] {
            let result = compiled(bad).settings.repairedWithIssues()
            #expect(result.issues.contains { $0.message.contains("Auto-scroll dead zone") })
            #expect(result.settings.profiles[0].mappings.isEmpty)
        }
        #expect(compiled().settings.repairedWithIssues().issues.isEmpty)
    }

    @Test func aWheelNotchCannotStartOne() {
        var settings = WhiskerSettings()
        settings.profiles[0].mappings = [Mapping(trigger: .wheel(.up), action: .autoScroll(AutoScroll()))]
        let result = settings.repairedWithIssues()
        #expect(result.issues.contains { $0.message.contains("needs a mouse button") })
        #expect(result.settings.profiles[0].mappings.isEmpty)
    }
}
