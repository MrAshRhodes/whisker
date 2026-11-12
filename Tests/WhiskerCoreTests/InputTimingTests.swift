import Foundation
import Testing
@testable import WhiskerCore

@Suite("Input timing")
struct InputTimingTests {
    private let wide = InputTimingWindow(start: 1, end: UInt64.max)
    private let origin: UInt64 = 1_000_000_000

    /// `count` timestamps `intervalMs` apart, in nanoseconds.
    private func steady(_ count: Int, everyMs intervalMs: Double, from start: UInt64? = nil) -> [UInt64] {
        (0..<count).map { (start ?? origin) + UInt64(Double($0) * intervalMs * 1_000_000) }
    }

    private func summarise(_ timestamps: [UInt64], window: InputTimingWindow? = nil, overflowed: Bool = false) -> InputTimingStreamSummary {
        InputTimingSummariser.summarise(timestampsNanoseconds: timestamps, window: window ?? wide, overflowed: overflowed)
    }

    private func measurement(_ summary: InputTimingStreamSummary) -> InputTimingMeasurement? {
        if case .measured(let measurement) = summary { return measurement }
        return nil
    }

    private func close(_ a: Double, _ b: Double) -> Bool { abs(a - b) < 1e-6 }

    // MARK: Summaries

    @Test func steadyReportsGiveTheirRateAndInterval() throws {
        let thousand = try #require(measurement(summarise(steady(1001, everyMs: 1))))
        #expect(thousand.validSamples == 1001)
        #expect(close(thousand.headlineRateHz, 1000))
        #expect(close(thousand.movingRateHz, 1000))
        #expect(close(thousand.distribution.medianMs, 1))
        #expect(thousand.quality == InputTimingQuality())
        let slower = try #require(measurement(summarise(steady(51, everyMs: 8))))
        #expect(close(slower.headlineRateHz, 125))
        #expect(close(slower.spanSeconds, 0.4))
    }

    @Test func irregularIntervalsShowTheirSpreadNotJustAnAverage() throws {
        var timestamps = [origin]
        for index in 0..<40 { timestamps.append(timestamps[index] + (index.isMultiple(of: 2) ? 5_000_000 : 15_000_000)) }
        let result = try #require(measurement(summarise(timestamps)))
        #expect(close(result.headlineRateHz, 100))
        let spread = result.distribution
        #expect(close(spread.minimumMs, 5) && close(spread.medianMs, 10) && close(spread.p95Ms, 15) && close(spread.maximumMs, 15))
        #expect(spread.minimumMs <= spread.medianMs && spread.medianMs <= spread.p95Ms && spread.p95Ms <= spread.maximumMs)
    }

    @Test func p99NeedsAHundredIntervals() throws {
        #expect(try #require(measurement(summarise(steady(100, everyMs: 10)))).distribution.p99Ms == nil)
        #expect(try #require(measurement(summarise(steady(101, everyMs: 10)))).distribution.p99Ms != nil)
    }

    @Test func duplicatesAndOutOfOrderTimestampsAreCountedNotUsed() throws {
        var timestamps = steady(50, everyMs: 10)
        timestamps.insert(timestamps[9], at: 10)
        timestamps.insert(timestamps[3], at: 20)
        let result = try #require(measurement(summarise(timestamps)))
        #expect(result.quality.duplicates == 1 && result.quality.nonMonotonic == 1)
        #expect(result.validSamples == 50 && result.totalReports == 52)
        #expect(close(result.headlineRateHz, 100))
    }

    @Test func zeroTimestampsAreInvalidNotMeasurements() throws {
        let result = try #require(measurement(summarise([0, 0, 0] + steady(50, everyMs: 10))))
        #expect(result.quality.invalidTimestamps == 3 && result.totalReports == 53 && result.validSamples == 50)
        #expect(summarise([0, 0, 0, 0]) == .insufficient(validSamples: 0, totalReports: 4, quality: InputTimingQuality(invalidTimestamps: 4)))
    }

    @Test func tooFewReportsOrTooShortASpanIsInsufficientWithoutNumbers() {
        #expect(summarise([]) == .insufficient(validSamples: 0, totalReports: 0, quality: InputTimingQuality()))
        #expect(summarise([origin]) == .insufficient(validSamples: 1, totalReports: 1, quality: InputTimingQuality()))
        #expect(measurement(summarise(steady(10, everyMs: 10))) == nil)
        // Plenty of reports, but all within 30 ms.
        #expect(measurement(summarise(steady(31, everyMs: 1))) == nil)
    }

    @Test func aPauseIsCountedAndKeptOutOfTheMovingRate() throws {
        let first = steady(30, everyMs: 10)
        let second = steady(30, everyMs: 10, from: first[29] + 500_000_000)
        let result = try #require(measurement(summarise(first + second)))
        #expect(result.quality.pauses == 1 && result.movingIntervals == 58)
        #expect(close(result.movingRateHz, 100) && close(result.distribution.maximumMs, 10))
        #expect(result.headlineRateHz < result.movingRateHz)
        #expect(close(result.headlineRateHz, 59 / 1.08))
    }

    @Test func aSampleThatIsAllPausesIsInsufficient() {
        #expect(summarise(steady(30, everyMs: 200)) == .insufficient(validSamples: 30, totalReports: 30, quality: InputTimingQuality(pauses: 29)))
    }

    @Test func reportsOutsideTheCaptureWindowAreCounted() throws {
        let inside = steady(50, everyMs: 10)
        let window = InputTimingWindow(start: inside[0], end: inside[49])
        let result = try #require(measurement(summarise(inside + [inside[49] + 10_000_000], window: window)))
        #expect(result.quality.outsideCaptureWindow == 1 && result.validSamples == 50)
    }

    @Test func aStreamWhoseClockMissesTheWindowGivesNoRate() {
        let elsewhere = InputTimingWindow(start: 5_000_000_000_000, end: 6_000_000_000_000)
        #expect(summarise(steady(50, everyMs: 10), window: elsewhere) == .clockMismatch(totalReports: 50))
    }

    @Test func overflowIsReportedAsSampleQuality() throws {
        var recorder = InputTimingRecorder()
        let key = InputTimingStreamKey(runtimeID: 1, reportID: 0)
        for index in 0...InputTimingRecorder.capacityPerStream { recorder.append(origin + UInt64(index) * 1_000, stream: key) }
        #expect(recorder.timestampsNanoseconds[key]?.count == InputTimingRecorder.capacityPerStream)
        #expect(recorder.overflowed == [key])
        let summary = summarise(recorder.timestampsNanoseconds[key] ?? [], overflowed: recorder.overflowed.contains(key))
        if case .insufficient(_, _, let quality) = summary { #expect(quality.overflowed == 1) } else { #expect(measurement(summary)?.quality.overflowed == 1) }
        #expect(measurement(summarise(steady(50, everyMs: 10), overflowed: true))?.quality.overflowed == 1)
    }

    @Test func streamsStayApartByDeviceAndReportID() {
        var recorder = InputTimingRecorder()
        let keys = [
            InputTimingStreamKey(runtimeID: 1, reportID: 1), InputTimingStreamKey(runtimeID: 1, reportID: 2),
            InputTimingStreamKey(runtimeID: 2, reportID: 1),
        ]
        for (index, key) in keys.enumerated() { recorder.append(UInt64(index + 1) * 10, stream: key) }
        recorder.append(99, stream: keys[0])
        #expect(recorder.timestampsNanoseconds[keys[0]] == [10, 99])
        #expect(recorder.timestampsNanoseconds[keys[1]] == [20] && recorder.timestampsNanoseconds[keys[2]] == [30])
    }

    // MARK: Timebase

    @Test func ticksConvertWithoutOverflowingOrTrapping() {
        let appleSilicon = HIDTimebase(numerator: 125, denominator: 3)
        #expect(appleSilicon.nanoseconds(fromTicks: 24_000_000) == 1_000_000_000)
        #expect(appleSilicon.nanoseconds(fromTicks: 3) == 125 && appleSilicon.nanoseconds(fromTicks: 0) == 0)
        // 3e17 × 125 wraps a 64-bit product; the true answer, 1.25e19, still fits.
        #expect(appleSilicon.nanoseconds(fromTicks: 300_000_000_000_000_000) == 12_500_000_000_000_000_000)
        #expect(appleSilicon.nanoseconds(fromTicks: 600_000_000_000_000_000) == UInt64.max)
        #expect(HIDTimebase.identity.nanoseconds(fromTicks: 42) == 42)
        #expect(HIDTimebase(numerator: 5, denominator: 0).nanoseconds(fromTicks: 2) == 10)
    }

    // MARK: Eligibility

    private func element(_ id: Int, page: Int = HIDUsage.genericDesktopPage, usage: Int = HIDUsage.mouse, kind: HIDElementKind = .input) -> InputTimingElement {
        InputTimingElement(kind: kind, reportID: id, topLevelUsagePage: page, topLevelUsage: usage)
    }

    @Test func onlyPointingInputReportsAreEligible() {
        #expect(InputTimingClassifier.eligibility(of: nil) == .rejected(.undescribed))
        #expect(InputTimingClassifier.eligibility(of: []) == .rejected(.undescribed))
        #expect(InputTimingClassifier.eligibility(of: [element(1, kind: .feature), element(1, kind: .output)]) == .rejected(.noPointingReports))
        #expect(InputTimingClassifier.eligibility(of: [element(1, usage: HIDUsage.keyboard), element(1, usage: HIDUsage.keypad)]) == .rejected(.noPointingReports))
        #expect(InputTimingClassifier.eligibility(of: [element(1), element(1), element(2, usage: HIDUsage.pointer)]) == .eligible(reportIDs: [1, 2]))
    }

    @Test func keyboardCollectionsOnOtherReportsContributeNothing() {
        let mixedInterface = [element(1), element(2, usage: HIDUsage.keyboard), element(2, page: HIDUsage.consumerPage, usage: 1), element(3, kind: .feature)]
        #expect(InputTimingClassifier.eligibility(of: mixedInterface) == .eligible(reportIDs: [1]))
    }

    @Test func aReportMixingPointingAndKeyboardRejectsTheWholeInterface() {
        let mixed = [element(1), element(2), element(2, usage: HIDUsage.keyboard)]
        #expect(InputTimingClassifier.eligibility(of: mixed) == .rejected(.cannotSeparate))
    }

    // MARK: Presentation

    @Test func aMeasuredStreamIsDescribedByWhatArrived() {
        let summary = summarise(steady(1001, everyMs: 1))
        #expect(InputTimingPresentation.figures(for: summary) == [
            "Counted 1001 reports over 1.0 seconds.",
            "About 1000 reports a second arrived overall.",
            "Gaps between reports while moving: shortest 1.0 ms, median 1.0 ms, 95th percentile 1.0 ms, 99th percentile 1.0 ms, longest 1.0 ms.",
        ])
        #expect(InputTimingPresentation.notes(for: summary).isEmpty)
        // Under a hundred intervals there is no 99th percentile to show.
        #expect(!InputTimingPresentation.figures(for: summarise(steady(51, everyMs: 8))).joined().contains("99th"))
    }

    @Test func pausesAreExplainedAndTheMovingRateIsShownApart() {
        let first = steady(30, everyMs: 8)
        let summary = summarise(first + steady(30, everyMs: 8, from: first[29] + 500_000_000))
        let figures = InputTimingPresentation.figures(for: summary)
        #expect(figures[1] == "About 61.2 reports a second arrived overall.")
        #expect(figures[2] == "While the mouse was moving, about 125 reports a second.")
        #expect(InputTimingPresentation.notes(for: summary) == ["1 pause of more than 100 ms between reports, left out of the moving figures."])
    }

    @Test func aStreamWithoutEnoughMovementSaysSoInsteadOfShowingNumbers() {
        #expect(InputTimingPresentation.figures(for: summarise([])) == ["No reports arrived on this stream during the sample."])
        #expect(InputTimingPresentation.figures(for: summarise(steady(10, everyMs: 10))) == ["Not enough movement to measure: 10 reports arrived."])
        let untimed = summarise([0, 0, 0, 0])
        #expect(InputTimingPresentation.figures(for: untimed) == ["4 reports arrived, but none could be timed."])
        #expect(InputTimingPresentation.notes(for: untimed) == ["4 reports had no timestamp (not counted)."])
        let mismatched = summarise(steady(50, everyMs: 10), window: InputTimingWindow(start: 5_000_000_000_000, end: 6_000_000_000_000))
        #expect(InputTimingPresentation.figures(for: mismatched).count == 1 && InputTimingPresentation.notes(for: mismatched).isEmpty)
    }

    @Test func everySampleQualityProblemIsNamedOnlyWhenItHappened() {
        let all = InputTimingQuality(invalidTimestamps: 1, duplicates: 2, nonMonotonic: 3, outsideCaptureWindow: 4, overflowed: 1, pauses: 5)
        #expect(InputTimingPresentation.notes(for: .insufficient(validSamples: 5, totalReports: 16, quality: all)).count == 6)
        #expect(InputTimingPresentation.notes(for: .insufficient(validSamples: 5, totalReports: 5, quality: InputTimingQuality())).isEmpty)
    }

    // MARK: Wording

    @Test func onlyTheCaveatNamesWhatTheNumbersAreNot() {
        let claims = ["polling", "latency", "packet loss", "game", "hz"]
        let everyProblem = InputTimingQuality(invalidTimestamps: 1, duplicates: 1, nonMonotonic: 1, outsideCaptureWindow: 1, overflowed: 1, pauses: 1)
        let summaries: [InputTimingStreamSummary] = [
            summarise(steady(1001, everyMs: 1)), summarise(steady(51, everyMs: 8)), summarise(steady(10, everyMs: 10)), summarise([]),
            .insufficient(validSamples: 0, totalReports: 4, quality: everyProblem), .insufficient(validSamples: 3, totalReports: 9, quality: everyProblem),
            .clockMismatch(totalReports: 50),
            .measured(InputTimingMeasurement(
                validSamples: 60, totalReports: 70, spanSeconds: 1, headlineRateHz: 60, movingIntervals: 30, movingRateHz: 120,
                distribution: InputTimingDistribution(minimumMs: 1, medianMs: 8, p95Ms: 9, p99Ms: 120, maximumMs: 140), quality: everyProblem)),
        ]
        let texts = InputTimingRejection.allCases.map(\.text) + InputTimingInterruption.allCases.map(\.text)
            + [InputTimingUnavailableReason.excluded, .disconnected, .indistinguishable, .couldNotOpen, .noEligibleInterfaces(.cannotSeparate)].map(\.text)
            + summaries.flatMap { InputTimingPresentation.figures(for: $0) + InputTimingPresentation.notes(for: $0) }
        for text in texts {
            for claim in claims { #expect(!text.lowercased().contains(claim), "“\(text)” mentions \(claim)") }
        }
        #expect(InputTimingWording.caveat.contains("not yet verified on hardware"))
    }
}
