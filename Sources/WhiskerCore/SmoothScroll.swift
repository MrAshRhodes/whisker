import Foundation

extension ScrollMath {
    /// How long smoothing spreads one stretch of wheel movement over, in milliseconds.
    public static let smoothDurationRange: ClosedRange<Int> = 40...400
    public static let defaultSmoothDuration = 120
}

extension ScrollAxis {
    /// The distance in pixels, from whichever unit the event carries.
    public var pixels: Double {
        if points != 0 { return points }
        if fixed != 0 { return fixed * ScrollMath.pointsPerLine }
        return Double(lines) * ScrollMath.pointsPerLine
    }
}

/// Everything that must match for two stretches of wheel movement to be joined. Movement from another device,
/// profile, app or modifier state is never merged into the same stretch.
public struct SmoothingContext: Hashable, Sendable {
    public var device: String
    public var profile: String
    public var app: String?
    /// The flags the generated events carry: the original event's flags without those the transformation used up.
    public var flags: UInt64

    public init(device: String, profile: String, app: String?, flags: UInt64) {
        self.device = device
        self.profile = profile
        self.app = app
        self.flags = flags
    }
}

/// Bounds that keep smoothing from ever holding unbounded memory or work.
public enum SmoothScrollLimits {
    /// Stretches waiting, the one being delivered included.
    public static let maxSegments = 8
    /// Most pixels waiting on one axis. More than this is refused and passes through unsmoothed.
    public static let maxPendingPixels = 4000.0
    /// A stretch that has been retargeted this long stops absorbing new movement, so it always finishes.
    public static let maxLifetime: TimeInterval = 1.5
    /// Most pixels one generated event carries on an axis, so a long stall can't overflow the event fields.
    public static let maxEventPixels = 4000
}

/// One generated scroll event, in whole pixels on both axes. Positive vertical is up, positive horizontal is left,
/// as in `ScrollSample`.
public struct SmoothScrollOutput: Equatable, Sendable {
    public var vertical: Int
    public var horizontal: Int
    public var context: SmoothingContext

    public init(vertical: Int, horizontal: Int, context: SmoothingContext) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.context = context
    }
}

/// Distance that was thrown away rather than delivered.
public struct SmoothScrollDiscard: Equatable, Sendable {
    public var vertical = 0.0
    public var horizontal = 0.0
    public var segments = 0

    public init(vertical: Double = 0, horizontal: Double = 0, segments: Int = 0) {
        self.vertical = vertical
        self.horizontal = horizontal
        self.segments = segments
    }

    public var isEmpty: Bool { vertical == 0 && horizontal == 0 && segments == 0 }

    mutating func add(_ other: SmoothScrollDiscard) {
        vertical += other.vertical
        horizontal += other.horizontal
        segments += other.segments
    }
}

/// Spreads wheel distance that has already been transformed (mappings, direction, sideways, speed and scaling)
/// over a short time, without adding or losing any.
///
/// Pure and clock-free: every call is given the time. Per axis it conserves the signed distance: the whole
/// pixels it hands out plus what it still holds always equal what it was given, and the part of a pixel that
/// can't be delivered yet waits for the next movement in the same context. Both axes of a diagonal sample share
/// one timeline and are delivered in the same events. Movement runs in the order it arrived: a reversal or a
/// different context queues behind the stretch under way instead of cancelling or overlapping it, and only a
/// stretch in the same context and direction is joined to the one still under way.
public struct SmoothScrollPlanner: Sendable {
    private struct Segment: Sendable {
        var context: SmoothingContext
        var vertical: Double
        var horizontal: Double
        var emittedVertical = 0
        var emittedHorizontal = 0
        var arrival: TimeInterval
        /// Set once the stretch is first delivered; later stretches start no earlier than the one before ends.
        var start: TimeInterval
        var duration: TimeInterval
        var born: TimeInterval
        var started = false
    }

    private var segments: [Segment] = []
    /// The sub-pixel part left when the last stretch finished, kept for the next one in the same context.
    private var carry: (context: SmoothingContext, vertical: Double, horizontal: Double)?
    private var lastEnd: TimeInterval = 0

    /// Everything thrown away so far, for diagnostics.
    public private(set) var discarded = SmoothScrollDiscard()

    public init() {}

    public var isIdle: Bool { segments.isEmpty }
    public var segmentCount: Int { segments.count }

    /// Pixels still to deliver, with the held sub-pixel part.
    public var pending: (vertical: Double, horizontal: Double) {
        var vertical = carry?.vertical ?? 0
        var horizontal = carry?.horizontal ?? 0
        for segment in segments {
            vertical += segment.vertical - Double(segment.emittedVertical)
            horizontal += segment.horizontal - Double(segment.emittedHorizontal)
        }
        return (vertical, horizontal)
    }

    /// Whether `enqueue` took the distance. A refusal leaves the planner untouched, so the caller passes the
    /// event through as if smoothing were off.
    public enum Admission: Equatable, Sendable {
        case accepted
        case refused
    }

    /// Adds distance in pixels. `duration` is clamped to the allowed range.
    public mutating func enqueue(
        vertical: Double, horizontal: Double, context: SmoothingContext, duration: TimeInterval, now: TimeInterval
    ) -> Admission {
        guard vertical.isFinite, horizontal.isFinite, now.isFinite else { return .refused }
        guard vertical != 0 || horizontal != 0 else { return .accepted }
        let limits = ScrollMath.smoothDurationRange
        let span = min(max(duration, Double(limits.lowerBound) / 1000), Double(limits.upperBound) / 1000)

        // Distance waiting for another target is never delivered to this one.
        if segments.contains(where: { $0.context.app != context.app || $0.context.device != context.device }) {
            discardAll()
        }
        if let held = carry, held.context != context {
            discarded.add(SmoothScrollDiscard(vertical: held.vertical, horizontal: held.horizontal))
            carry = nil
        }

        let held = carry
        let addV = vertical + (held?.vertical ?? 0)
        let addH = horizontal + (held?.horizontal ?? 0)

        if let last = segments.indices.last, segments[last].context == context, now - segments[last].born <= SmoothScrollLimits.maxLifetime {
            let remainingV = segments[last].vertical - Double(segments[last].emittedVertical)
            let remainingH = segments[last].horizontal - Double(segments[last].emittedHorizontal)
            if remainingV * addV >= 0, remainingH * addH >= 0 {
                let totalV = remainingV + addV, totalH = remainingH + addH
                guard fits(replacing: last, vertical: totalV, horizontal: totalH) else { return .refused }
                carry = nil
                if segments[last].started {
                    // Retarget from now: what was already delivered stays delivered, the rest plus the new movement
                    // is spread afresh.
                    segments[last].vertical = totalV
                    segments[last].horizontal = totalH
                    segments[last].emittedVertical = 0
                    segments[last].emittedHorizontal = 0
                    segments[last].start = now
                    segments[last].duration = span
                } else {
                    segments[last].vertical = totalV
                    segments[last].horizontal = totalH
                }
                return .accepted
            }
        }

        guard segments.count < SmoothScrollLimits.maxSegments, fits(replacing: nil, vertical: addV, horizontal: addH) else { return .refused }
        carry = nil
        segments.append(Segment(context: context, vertical: addV, horizontal: addH, arrival: now, start: now, duration: span, born: now))
        return .accepted
    }

    private func fits(replacing index: Int?, vertical: Double, horizontal: Double) -> Bool {
        var pendingV = abs(vertical), pendingH = abs(horizontal)
        for (position, segment) in segments.enumerated() where position != index {
            pendingV += abs(segment.vertical - Double(segment.emittedVertical))
            pendingH += abs(segment.horizontal - Double(segment.emittedHorizontal))
        }
        return pendingV <= SmoothScrollLimits.maxPendingPixels && pendingH <= SmoothScrollLimits.maxPendingPixels
    }

    /// The next event to post, or nil when nothing is due. At most one per call, so a worker that falls behind
    /// catches up in single, bounded steps (each carrying everything due so far) rather than a burst.
    public mutating func tick(now: TimeInterval) -> SmoothScrollOutput? {
        while let head = segments.first {
            var segment = head
            if !segment.started {
                segment.start = max(segment.arrival, lastEnd)
                segment.started = true
            }
            guard now >= segment.start else {
                segments[0] = segment
                return nil
            }
            let progress = segment.duration > 0 ? min(1, (now - segment.start) / segment.duration) : 1
            let wholeV = Int((segment.vertical * progress).rounded(.towardZero))
            let wholeH = Int((segment.horizontal * progress).rounded(.towardZero))
            let stepV = clamp(wholeV - segment.emittedVertical)
            let stepH = clamp(wholeH - segment.emittedHorizontal)
            segment.emittedVertical += stepV
            segment.emittedHorizontal += stepH
            let finished = progress >= 1 && segment.emittedVertical == wholeV && segment.emittedHorizontal == wholeH

            if finished {
                segments.removeFirst()
                lastEnd = segment.start + segment.duration
                let leftV = segment.vertical - Double(segment.emittedVertical)
                let leftH = segment.horizontal - Double(segment.emittedHorizontal)
                carry = (segment.context, leftV, leftH)
            } else {
                segments[0] = segment
            }
            if stepV != 0 || stepH != 0 {
                return SmoothScrollOutput(vertical: stepV, horizontal: stepH, context: segment.context)
            }
            if !finished { return nil }
        }
        return nil
    }

    private func clamp(_ pixels: Int) -> Int {
        max(-SmoothScrollLimits.maxEventPixels, min(SmoothScrollLimits.maxEventPixels, pixels))
    }

    /// When the next event is worth asking for, or nil when idle.
    public func nextDue(now: TimeInterval) -> TimeInterval? {
        guard let head = segments.first else { return nil }
        return head.started ? now : max(now, max(head.arrival, lastEnd))
    }

    /// Drops everything waiting when any of it came from a device outside `connected`.
    @discardableResult
    public mutating func cancel(unlessConnected connected: Set<String>) -> SmoothScrollDiscard {
        let gone = segments.contains { !connected.contains($0.context.device) } || (carry.map { !connected.contains($0.context.device) } ?? false)
        return gone ? discardAll() : SmoothScrollDiscard()
    }

    /// Drops everything waiting and returns exactly what was dropped, the held sub-pixel part included. It is
    /// never delivered later, to this context or any other.
    @discardableResult
    public mutating func cancel() -> SmoothScrollDiscard {
        discardAll()
    }

    @discardableResult
    private mutating func discardAll() -> SmoothScrollDiscard {
        var dropped = SmoothScrollDiscard(segments: segments.count)
        for segment in segments {
            dropped.vertical += segment.vertical - Double(segment.emittedVertical)
            dropped.horizontal += segment.horizontal - Double(segment.emittedHorizontal)
        }
        dropped.vertical += carry?.vertical ?? 0
        dropped.horizontal += carry?.horizontal ?? 0
        segments.removeAll()
        carry = nil
        if !dropped.isEmpty { discarded.add(dropped) }
        return dropped
    }
}
