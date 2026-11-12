import Foundation

// Diagnostic only: how often Whisker actually received HID reports from a mouse during a short, user-started
// sample. Everything here is pure policy — summarising timestamps, deciding which interfaces are safe to time
// and the words used to describe a result. Opening a device and registering for its reports lives in the app
// target. This never claims sensor polling frequency, end-to-end latency, packet loss or a game's input rate:
// it counts what arrived, nothing more.

// MARK: - Timebase

/// Converts mach absolute time ticks to nanoseconds, using the numerator and denominator macOS reports for
/// this Mac (`mach_timebase_info`). The app target reads that once per launch and passes it in here, so the
/// conversion itself is pure, deterministic arithmetic.
public struct HIDTimebase: Equatable, Sendable {
    public var numerator: UInt64
    public var denominator: UInt64

    public init(numerator: UInt64, denominator: UInt64) {
        self.numerator = numerator
        self.denominator = max(denominator, 1)
    }

    /// Ticks already equal nanoseconds (what Intel Macs report, and what tests use for round numbers).
    public static let identity = HIDTimebase(numerator: 1, denominator: 1)

    /// `ticks * numerator / denominator`, using a 128-bit intermediate so a ratio like Apple Silicon's 125/3
    /// can't silently wrap, even for ticks counted since a boot weeks ago. A zero tick is never a real
    /// timestamp (see `InputTimingSummariser`), so it is returned as zero rather than computed. A result too
    /// large for 64 bits (centuries of uptime, or a nonsense ratio) saturates instead of trapping.
    public func nanoseconds(fromTicks ticks: UInt64) -> UInt64 {
        guard ticks > 0 else { return 0 }
        let product = ticks.multipliedFullWidth(by: numerator)
        guard product.high < denominator else { return UInt64.max }
        return denominator.dividingFullWidth(product).quotient
    }
}

// MARK: - Streams

/// Identifies one stream of HID reports to time: one interface's one report id. Streams are never combined —
/// different report ids, different interfaces and different physical mice all stay apart, because summing
/// them would turn a count of reports into a fabricated claim about the device as a whole.
public struct InputTimingStreamKey: Hashable, Sendable {
    public var runtimeID: Int
    public var reportID: Int

    public init(runtimeID: Int, reportID: Int) {
        self.runtimeID = runtimeID
        self.reportID = reportID
    }
}

/// The explicit start and end of one capture, in the same nanosecond domain as the timestamps handed to the
/// summariser. A timestamp outside this window didn't happen during the capture it is being judged against.
public struct InputTimingWindow: Equatable, Sendable {
    public var start: UInt64
    public var end: UInt64

    public init(start: UInt64, end: UInt64) {
        self.start = start
        self.end = end
    }
}

/// Collects raw per-stream arrival timestamps for one capture, in arrival order and otherwise untouched, so
/// `InputTimingSummariser` can see duplicates, non-monotonic arrivals and anything else out of order for
/// itself rather than have this type quietly correct it away.
public struct InputTimingRecorder: Sendable {
    /// Far more than any real mouse should produce in one short capture; filling it is itself worth surfacing
    /// rather than growing without limit or silently discarding reports.
    public static let capacityPerStream = 120_000

    public private(set) var timestampsNanoseconds: [InputTimingStreamKey: [UInt64]] = [:]
    public private(set) var overflowed: Set<InputTimingStreamKey> = []

    public init() {}

    public var isEmpty: Bool { timestampsNanoseconds.isEmpty }

    public mutating func append(_ timestampNanoseconds: UInt64, stream: InputTimingStreamKey) {
        guard !overflowed.contains(stream) else { return }
        guard (timestampsNanoseconds[stream]?.count ?? 0) < Self.capacityPerStream else {
            overflowed.insert(stream)
            return
        }
        // In place: copying the whole array per report would stall the HID callback at high rates.
        timestampsNanoseconds[stream, default: []].append(timestampNanoseconds)
    }
}

// MARK: - Quality and results

/// A problem the summariser saw in the raw timestamps, with how many times it saw it. Always reported,
/// whether or not the sample produced numbers: a quiet mouse and a flood of invalid timestamps both deserve
/// an honest account rather than a bare zero.
public struct InputTimingQuality: Equatable, Sendable {
    /// A zero timestamp: the legacy (non-timestamped) HID report path, not a measurement.
    public var invalidTimestamps = 0
    /// The same timestamp as the previous valid one.
    public var duplicates = 0
    /// Earlier than the previous valid one.
    public var nonMonotonic = 0
    /// Outside the capture's explicit window.
    public var outsideCaptureWindow = 0
    /// The stream filled `InputTimingRecorder.capacityPerStream` and further reports were dropped.
    public var overflowed = 0
    /// A gap longer than `InputTimingSummariser.pauseThresholdMs` between two otherwise-valid reports.
    public var pauses = 0

    public init(
        invalidTimestamps: Int = 0, duplicates: Int = 0, nonMonotonic: Int = 0,
        outsideCaptureWindow: Int = 0, overflowed: Int = 0, pauses: Int = 0
    ) {
        self.invalidTimestamps = invalidTimestamps
        self.duplicates = duplicates
        self.nonMonotonic = nonMonotonic
        self.outsideCaptureWindow = outsideCaptureWindow
        self.overflowed = overflowed
        self.pauses = pauses
    }
}

/// How long the gaps were between consecutive valid reports while the mouse was moving (pauses excluded),
/// in milliseconds.
public struct InputTimingDistribution: Equatable, Sendable {
    public var minimumMs: Double
    public var medianMs: Double
    public var p95Ms: Double
    /// Only computed with at least `InputTimingSummariser.minimumIntervalsForP99` intervals; nil otherwise
    /// rather than an estimate too noisy to mean anything.
    public var p99Ms: Double?
    public var maximumMs: Double

    public init(minimumMs: Double, medianMs: Double, p95Ms: Double, p99Ms: Double?, maximumMs: Double) {
        self.minimumMs = minimumMs
        self.medianMs = medianMs
        self.p95Ms = p95Ms
        self.p99Ms = p99Ms
        self.maximumMs = maximumMs
    }
}

/// A finished summary of one stream: only produced with enough movement to say something, see
/// `InputTimingSummariser.minimumMovingIntervals`.
public struct InputTimingMeasurement: Equatable, Sendable {
    public var validSamples: Int
    public var totalReports: Int
    public var spanSeconds: Double
    /// `(n−1)/(last−first)` over the whole span, pauses included: the delivery rate the issue asks for. It is
    /// averaged down by every pause, so read it with `movingRateHz`.
    public var headlineRateHz: Double
    /// How many gaps between reports were short enough to count as the mouse moving.
    public var movingIntervals: Int
    /// The same kind of rate, but only across the moving gaps: what arrived while the mouse was being moved,
    /// not averaged down by the user pausing or lifting it.
    public var movingRateHz: Double
    /// Of the moving gaps only.
    public var distribution: InputTimingDistribution
    public var quality: InputTimingQuality

    public init(
        validSamples: Int, totalReports: Int, spanSeconds: Double, headlineRateHz: Double, movingIntervals: Int,
        movingRateHz: Double, distribution: InputTimingDistribution, quality: InputTimingQuality
    ) {
        self.validSamples = validSamples
        self.totalReports = totalReports
        self.spanSeconds = spanSeconds
        self.headlineRateHz = headlineRateHz
        self.movingIntervals = movingIntervals
        self.movingRateHz = movingRateHz
        self.distribution = distribution
        self.quality = quality
    }
}

/// What `InputTimingSummariser` found for one stream.
public enum InputTimingStreamSummary: Equatable, Sendable {
    /// Too little movement or too short a span to say anything. Still carries whatever was actually seen,
    /// including when nothing arrived at all (`validSamples == 0`).
    case insufficient(validSamples: Int, totalReports: Int, quality: InputTimingQuality)
    /// Every timestamp fell outside the capture window: this stream's clock doesn't line up with the one the
    /// window was built from, so no rate is shown rather than a number built on a mismatched clock.
    case clockMismatch(totalReports: Int)
    case measured(InputTimingMeasurement)
}

// MARK: - Summariser

/// Turns one stream's raw arrival timestamps into a summary, or an honest account of why it can't give one.
/// Stateless and deterministic: the same input always gives the same answer, so it is exercised entirely
/// through tests rather than against real hardware.
public enum InputTimingSummariser {
    /// At least this many short gaps between valid reports (the mouse moving) before a result is shown as
    /// measured. Conservative and not yet validated against real capture data (see the issue's open questions).
    public static let minimumMovingIntervals = 20
    /// At least this much elapsed time between the first and last valid sample.
    public static let minimumSpanSeconds: Double = 0.25
    /// A gap longer than this is a pause — the mouse stopped moving, or was lifted — not part of the moving rate.
    public static let pauseThresholdMs: Double = 100
    /// p99 needs at least this many intervals before it means anything stable.
    public static let minimumIntervalsForP99 = 100

    /// Summarises one stream. Timestamps are read in the order given (arrival order), never sorted first, so
    /// out-of-order delivery shows up as `nonMonotonic` instead of being silently corrected away.
    public static func summarise(
        timestampsNanoseconds: [UInt64], window: InputTimingWindow, overflowed: Bool
    ) -> InputTimingStreamSummary {
        var quality = InputTimingQuality(overflowed: overflowed ? 1 : 0)
        let totalReports = timestampsNanoseconds.count
        var valid: [UInt64] = []
        valid.reserveCapacity(totalReports)
        var consideredForWindow = 0
        var runningMax: UInt64?
        for timestamp in timestampsNanoseconds {
            guard timestamp != 0 else { quality.invalidTimestamps += 1; continue }
            consideredForWindow += 1
            guard timestamp >= window.start, timestamp <= window.end else { quality.outsideCaptureWindow += 1; continue }
            if let runningMax {
                if timestamp == runningMax { quality.duplicates += 1; continue }
                if timestamp < runningMax { quality.nonMonotonic += 1; continue }
            }
            valid.append(timestamp)
            runningMax = timestamp
        }
        if consideredForWindow > 0, quality.outsideCaptureWindow == consideredForWindow {
            return .clockMismatch(totalReports: totalReports)
        }
        guard valid.count >= 2 else {
            return .insufficient(validSamples: valid.count, totalReports: totalReports, quality: quality)
        }

        let pauseThresholdNs = UInt64(pauseThresholdMs * 1_000_000)
        var moving: [UInt64] = []
        moving.reserveCapacity(valid.count - 1)
        for index in 1..<valid.count {
            let interval = valid[index] - valid[index - 1]
            if interval > pauseThresholdNs { quality.pauses += 1 } else { moving.append(interval) }
        }
        let spanSeconds = Double(valid[valid.count - 1] - valid[0]) / 1_000_000_000
        // Strictly increasing timestamps make every interval at least 1 ns, so neither divisor can be zero.
        guard moving.count >= minimumMovingIntervals, spanSeconds >= minimumSpanSeconds else {
            return .insufficient(validSamples: valid.count, totalReports: totalReports, quality: quality)
        }
        let movingSeconds = Double(moving.reduce(UInt64(0), +)) / 1_000_000_000

        return .measured(InputTimingMeasurement(
            validSamples: valid.count, totalReports: totalReports, spanSeconds: spanSeconds,
            headlineRateHz: Double(valid.count - 1) / spanSeconds,
            movingIntervals: moving.count,
            movingRateHz: Double(moving.count) / movingSeconds,
            distribution: distribution(fromNanoseconds: moving),
            quality: quality
        ))
    }

    private static func distribution(fromNanoseconds moving: [UInt64]) -> InputTimingDistribution {
        let sorted = moving.sorted()
        return InputTimingDistribution(
            minimumMs: Double(sorted[0]) / 1_000_000,
            medianMs: percentileMs(sorted, 0.5),
            p95Ms: percentileMs(sorted, 0.95),
            p99Ms: sorted.count >= minimumIntervalsForP99 ? percentileMs(sorted, 0.99) : nil,
            maximumMs: Double(sorted[sorted.count - 1]) / 1_000_000
        )
    }

    /// Linear-interpolated percentile of an already-sorted sample, in milliseconds.
    private static func percentileMs(_ sorted: [UInt64], _ fraction: Double) -> Double {
        guard sorted.count > 1 else { return Double(sorted.first ?? 0) / 1_000_000 }
        let position = fraction * Double(sorted.count - 1)
        let lower = Int(position.rounded(.down))
        let upper = min(lower + 1, sorted.count - 1)
        let fractional = position - Double(lower)
        let valueNs = Double(sorted[lower]) + (Double(sorted[upper]) - Double(sorted[lower])) * fractional
        return valueNs / 1_000_000
    }
}

// MARK: - Eligibility

/// One input element of an interface's HID descriptor, reduced to what eligibility needs: its report id and
/// the usage of the top-level collection it belongs to.
public struct InputTimingElement: Hashable, Sendable {
    public var kind: HIDElementKind
    public var reportID: Int
    public var topLevelUsagePage: Int
    public var topLevelUsage: Int

    public init(kind: HIDElementKind, reportID: Int, topLevelUsagePage: Int, topLevelUsage: Int) {
        self.kind = kind
        self.reportID = reportID
        self.topLevelUsagePage = topLevelUsagePage
        self.topLevelUsage = topLevelUsage
    }

    /// The element's top-level collection is a mouse or pointer, not (for one) a keyboard's.
    var isPointing: Bool {
        topLevelUsagePage == HIDUsage.genericDesktopPage && (topLevelUsage == HIDUsage.mouse || topLevelUsage == HIDUsage.pointer)
    }
}

/// Why an interface can't have its pointing reports timed.
public enum InputTimingRejection: Hashable, Sendable, CaseIterable {
    /// macOS described no elements for the interface.
    case undescribed
    /// The interface declares elements, but none belong to a pointing (mouse or pointer) top-level collection.
    case noPointingReports
    /// One report id carries elements from both a pointing and a non-pointing top-level collection, so a
    /// timed report on that id could be carrying more than movement.
    case cannotSeparate

    public var text: String {
        switch self {
        case .undescribed: return "macOS hasn't described this interface"
        case .noPointingReports: return "this interface doesn't report anything from a mouse or pointer"
        case .cannotSeparate: return "this interface mixes pointing and other input on the same report, so timing can't be isolated to movement"
        }
    }
}

/// Which report ids on an interface are safe to time as pointing input.
public enum InputTimingEligibility: Equatable, Sendable {
    case eligible(reportIDs: Set<Int>)
    case rejected(InputTimingRejection)
}

public enum InputTimingClassifier {
    /// An interface is eligible only when every *input* element on a given report id belongs to a pointing
    /// top-level collection. A report id that mixes a pointing and a non-pointing collection rejects the
    /// whole interface, because that one report could be carrying keyboard or macro-key data as well as
    /// movement, and timing couldn't tell which. Non-input elements (output, feature, collection) are not
    /// reports, so they play no part in this.
    public static func eligibility(of elements: [InputTimingElement]?) -> InputTimingEligibility {
        guard let elements, !elements.isEmpty else { return .rejected(.undescribed) }
        let inputs = elements.filter { $0.kind == .input }
        guard !inputs.isEmpty else { return .rejected(.noPointingReports) }
        var pointingReportIDs: Set<Int> = []
        var mixedReportID = false
        for (reportID, group) in Dictionary(grouping: inputs, by: \.reportID) {
            let pointingCount = group.filter(\.isPointing).count
            if pointingCount == group.count {
                pointingReportIDs.insert(reportID)
            } else if pointingCount > 0 {
                mixedReportID = true
            }
        }
        guard !mixedReportID else { return .rejected(.cannotSeparate) }
        guard !pointingReportIDs.isEmpty else { return .rejected(.noPointingReports) }
        return .eligible(reportIDs: pointingReportIDs)
    }
}

// MARK: - State

/// Why a device or interface isn't being timed.
public enum InputTimingUnavailableReason: Equatable, Sendable {
    /// Whisker leaves this device alone (a trackpad or touch mouse).
    case excluded
    case disconnected
    /// Two or more identical mice share one listing because there's no serial number to tell them apart, so
    /// their streams would blend together under one entry.
    case indistinguishable
    case noEligibleInterfaces(InputTimingRejection)
    case couldNotOpen

    public var text: String {
        switch self {
        case .excluded: return "Whisker leaves this device alone, so it isn't timed."
        case .disconnected: return "This device isn't connected."
        case .indistinguishable: return "Whisker can't tell two identical mice apart without a serial number, so it can't time just one of them."
        case .noEligibleInterfaces(let rejection): return "Whisker can't time this device: \(rejection.text)."
        case .couldNotOpen: return "Whisker couldn't open this device to time it."
        }
    }
}

/// Why a capture ended before its sample duration was up.
public enum InputTimingInterruption: Equatable, Sendable, CaseIterable {
    case cancelled
    case sheetClosed
    case sleep
    case permissionLost
    case disconnected
    /// The device's interfaces changed shape mid-capture (for one, a receiver re-pairing).
    case deviceChanged

    public var text: String {
        switch self {
        case .cancelled: return "Cancelled."
        case .sheetClosed: return "Stopped because the window closed."
        case .sleep: return "Stopped because the Mac went to sleep or switched to another user."
        case .permissionLost: return "Stopped because Input Monitoring was turned off."
        case .disconnected: return "Stopped because the device disconnected."
        case .deviceChanged: return "Stopped because the device changed."
        }
    }
}

/// One stream's result, labelled for the sheet — a device may have more than one stream, by interface and
/// report id, and they are always shown apart.
public struct InputTimingStreamResult: Equatable, Sendable {
    public var label: String
    public var summary: InputTimingStreamSummary

    public init(label: String, summary: InputTimingStreamSummary) {
        self.label = label
        self.summary = summary
    }
}

/// A finished capture, discarded once the sheet closes: nothing here is ever saved.
public struct InputTimingCaptureResult: Equatable, Sendable {
    public var duration: TimeInterval
    public var streams: [InputTimingStreamResult]

    public init(duration: TimeInterval, streams: [InputTimingStreamResult]) {
        self.duration = duration
        self.streams = streams
    }
}

/// What the Input Timing sheet shows. Cancelling, closing the sheet, sleep, losing permission and
/// disconnecting all discard the sample and show the interruption, never a zero result.
public enum InputTimingState: Equatable, Sendable {
    case idle
    case needsPermission
    case unavailable(InputTimingUnavailableReason)
    case sampling(elapsed: TimeInterval, reportCount: Int)
    case finished(InputTimingCaptureResult)
    case interrupted(InputTimingInterruption)
}

// MARK: - Wording and defaults

public enum InputTimingDefaults {
    /// Not yet validated against real devices; conservative so a short burst can't be read as a stable rate.
    public static let sampleDuration: TimeInterval = 10
    /// How often the sheet's live report count may update while sampling.
    public static let liveUpdateHz: Double = 4
}

public enum InputTimingWording {
    /// The one place this feature names what it is not. Every other label in this file describes only what
    /// was actually counted, so a wording-guard test can check that.
    public static let caveat = "This only counts HID reports Whisker received for this stream. It is not the mouse's polling rate, end-to-end latency, packet loss or a game's input rate. Timestamp units and delivery are not yet verified on hardware."
}

// MARK: - Presentation

/// Plain-language lines for one stream's summary, kept pure so the wording is tested rather than eyeballed. The
/// sheet only lays them out. Rates are always "reports a second" — what arrived — never a property of the mouse.
public enum InputTimingPresentation {
    /// What the sample showed: the counts, rates and gaps for a measured stream, or the reason there are no figures.
    public static func figures(for summary: InputTimingStreamSummary) -> [String] {
        switch summary {
        case .measured(let measurement):
            var lines = [
                "Counted \(reports(measurement.validSamples)) over \(String(format: "%.1f", measurement.spanSeconds)) seconds.",
                "About \(number(measurement.headlineRateHz)) reports a second arrived overall.",
            ]
            // Without pauses the two rates are the same number, so only say it once.
            if measurement.quality.pauses > 0 {
                lines.append("While the mouse was moving, about \(number(measurement.movingRateHz)) reports a second.")
            }
            let gaps = measurement.distribution
            var gapLine = "Gaps between reports while moving: shortest \(milliseconds(gaps.minimumMs)), "
                + "median \(milliseconds(gaps.medianMs)), 95th percentile \(milliseconds(gaps.p95Ms)), "
            if let p99 = gaps.p99Ms { gapLine += "99th percentile \(milliseconds(p99)), " }
            gapLine += "longest \(milliseconds(gaps.maximumMs))."
            lines.append(gapLine)
            return lines
        case .insufficient(let validSamples, let totalReports, _):
            if totalReports == 0 { return ["No reports arrived on this stream during the sample."] }
            if validSamples == 0 { return ["\(reports(totalReports)) arrived, but none could be timed."] }
            let timed = validSamples == totalReports ? "" : ", \(validSamples) of them timed"
            return ["Not enough movement to measure: \(reports(totalReports)) arrived\(timed)."]
        case .clockMismatch(let totalReports):
            return ["\(reports(totalReports)) arrived, but their timestamps don't line up with the time of the sample, so no figures are shown."]
        }
    }

    /// Anything odd the summariser saw, one line each, and only what actually happened.
    public static func notes(for summary: InputTimingStreamSummary) -> [String] {
        let quality: InputTimingQuality
        var leftOut = ""
        switch summary {
        case .measured(let measurement):
            quality = measurement.quality
            leftOut = ", left out of the moving figures"
        case .insufficient(_, _, let seen):
            quality = seen
        case .clockMismatch:
            return []
        }
        var lines: [String] = []
        if quality.pauses > 0 {
            let count = quality.pauses == 1 ? "1 pause" : "\(quality.pauses) pauses"
            lines.append("\(count) of more than \(Int(InputTimingSummariser.pauseThresholdMs)) ms between reports\(leftOut).")
        }
        if quality.duplicates > 0 { lines.append("\(reports(quality.duplicates)) repeated an earlier timestamp (not counted).") }
        if quality.nonMonotonic > 0 { lines.append("\(reports(quality.nonMonotonic)) arrived out of order (not counted).") }
        if quality.invalidTimestamps > 0 { lines.append("\(reports(quality.invalidTimestamps)) had no timestamp (not counted).") }
        if quality.outsideCaptureWindow > 0 { lines.append("\(reports(quality.outsideCaptureWindow)) fell outside the sample (not counted).") }
        if quality.overflowed > 0 { lines.append("Whisker stopped recording this stream when it reached its size limit, so the end of the sample is missing.") }
        return lines
    }

    private static func reports(_ count: Int) -> String { count == 1 ? "1 report" : "\(count) reports" }

    /// One decimal place, or none once the figure would round up to three digits anyway.
    private static func number(_ value: Double) -> String { String(format: value >= 99.95 ? "%.0f" : "%.1f", value) }

    private static func milliseconds(_ value: Double) -> String { number(value) + " ms" }
}
