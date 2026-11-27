import Foundation
import GRDB

// Billed time is one focus timeline: a booked meeting owns its slot, and
// foreground samples fill the rest, each second once. Agent runtime is
// context and never billed.
//
// Meetings bill their booked time. Where two eligible meetings overlap, the
// accepted (or organized) one beats a tentative or unanswered one. Two of the
// same standing both bill the overlap until the user says which one they
// were in (`MeetingOverlapChoice`); Review lists those double bookings.

/// The user's answer to a double booking: which meeting they were in during
/// the overlap. `eventID` < `otherEventID`; a nil winner means both count.
struct MeetingOverlapChoice: Codable, FetchableRecord, PersistableRecord, Equatable, Hashable, Sendable {
    var eventID: String
    var otherEventID: String
    var winnerEventID: String?

    static let databaseTableName = "meeting_overlap_choices"

    init(_ a: String, _ b: String, winner: String?) {
        (eventID, otherEventID) = a < b ? (a, b) : (b, a)
        winnerEventID = winner
    }

    static func pairKey(_ a: String, _ b: String) -> String { a < b ? "\(a)|\(b)" : "\(b)|\(a)" }
    var pairKey: String { Self.pairKey(eventID, otherEventID) }
}

enum MeetingBilling {
    /// Accepted or organized outranks tentative or unanswered in an overlap.
    static func rank(_ e: CalendarEvent) -> Int {
        e.rsvpStatus == "accepted" || e.rsvpStatus == "organizer" ? 2 : 1
    }

    struct Billed {
        let event: CalendarEvent
        let attribution: EventAttribution
        /// The booked time this meeting bills after overlaps are settled.
        let intervals: [DateInterval]
    }

    /// Two meetings of the same standing that overlap.
    struct DoubleBooking: Equatable, Identifiable {
        let first: CalendarEvent
        let second: CalendarEvent
        let overlap: DateInterval
        let choice: MeetingOverlapChoice?
        var id: String { MeetingOverlapChoice.pairKey(first.id, second.id) }
        var isResolved: Bool { choice != nil }
    }

    /// Meetings that can bill: not declined, not all-day holds, not ignored.
    static func eligible(_ events: [CalendarEvent], matcher: RuleMatcher) -> [(CalendarEvent, EventAttribution)] {
        events.compactMap { e in
            guard e.rsvpStatus != "declined", !e.isAllDay, e.endAt > e.startAt else { return nil }
            let a = matcher.attribute(event: e)
            return a.isIgnored ? nil : (e, a)
        }
    }

    /// Time no foreground sample can bill: every eligible booking's full
    /// span, whoever wins its overlaps, so contradictory double-booking
    /// answers can't hand a meeting slot to the app in front.
    static func blocked(events: [CalendarEvent], matcher: RuleMatcher) -> [DateInterval] {
        eligible(events, matcher: matcher).map { DateInterval(start: $0.0.startAt, end: $0.0.endAt) }
    }

    static func billed(events: [CalendarEvent], matcher: RuleMatcher,
                       choices: [MeetingOverlapChoice]) -> [Billed] {
        let pool = eligible(events, matcher: matcher)
        let choiceByPair = Dictionary(choices.map { ($0.pairKey, $0) }, uniquingKeysWith: { a, _ in a })
        return pool.map { (m, attribution) in
            let span = DateInterval(start: m.startAt, end: m.endAt)
            var cuts: [DateInterval] = []
            for (o, _) in pool where o.id != m.id {
                guard let overlap = span.intersectionIfPositive(with: DateInterval(start: o.startAt, end: o.endAt)) else { continue }
                if beats(o, m, choice: choiceByPair[MeetingOverlapChoice.pairKey(o.id, m.id)]) { cuts.append(overlap) }
            }
            return Billed(event: m, attribution: attribution, intervals: span.subtracting(cuts))
        }
    }

    /// Whether `o` takes the overlap from `m`.
    private static func beats(_ o: CalendarEvent, _ m: CalendarEvent, choice: MeetingOverlapChoice?) -> Bool {
        if let choice {
            return choice.winnerEventID == o.id
        }
        return rank(o) > rank(m)
    }

    static func doubleBookings(events: [CalendarEvent], matcher: RuleMatcher,
                               choices: [MeetingOverlapChoice]) -> [DoubleBooking] {
        let pool = eligible(events, matcher: matcher).map(\.0).sorted { ($0.startAt, $0.id) < ($1.startAt, $1.id) }
        let choiceByPair = Dictionary(choices.map { ($0.pairKey, $0) }, uniquingKeysWith: { a, _ in a })
        var out: [DoubleBooking] = []
        for (i, a) in pool.enumerated() {
            for b in pool[(i + 1)...] {
                guard b.startAt < a.endAt else { break }
                guard rank(a) == rank(b),
                      let overlap = DateInterval(start: a.startAt, end: a.endAt)
                        .intersectionIfPositive(with: DateInterval(start: b.startAt, end: b.endAt)) else { continue }
                out.append(DoubleBooking(first: a, second: b, overlap: overlap,
                                         choice: choiceByPair[MeetingOverlapChoice.pairKey(a.id, b.id)]))
            }
        }
        return out
    }
}

enum FocusSpans {
    /// The wall-clock span each active sample stands for: from its capture
    /// until the next sample (of any kind) or one interval, whichever comes
    /// first, minus time a meeting owns. Idle samples bill nothing but still
    /// end the sample before them.
    /// `isActive` decides which samples count; by default the active ones.
    /// The Cells app in front during your own call counts while idle too.
    static func spans(samples: [ActivitySample], sampleInterval: TimeInterval,
                      blocked: [DateInterval],
                      isActive: (ActivitySample) -> Bool = { !$0.isIdle }) -> [(sample: ActivitySample, spans: [DateInterval])] {
        let sorted = samples.sorted { $0.capturedAt < $1.capturedAt }
        let blocks = DateInterval.union(blocked)
        var out: [(ActivitySample, [DateInterval])] = []
        out.reserveCapacity(sorted.count)
        var b = 0
        for (i, s) in sorted.enumerated() where isActive(s) {
            var end = s.capturedAt.addingTimeInterval(sampleInterval)
            if i + 1 < sorted.count { end = min(end, sorted[i + 1].capturedAt) }
            guard end > s.capturedAt else { continue }
            let span = DateInterval(start: s.capturedAt, end: end)
            while b < blocks.count, blocks[b].end <= span.start { b += 1 }
            var cuts: [DateInterval] = []
            var j = b
            while j < blocks.count, blocks[j].start < span.end {
                if let x = span.intersectionIfPositive(with: blocks[j]) { cuts.append(x) }
                j += 1
            }
            let pieces = cuts.isEmpty ? [span] : span.subtracting(cuts)
            if !pieces.isEmpty { out.append((s, pieces)) }
        }
        return out
    }
}

extension DateInterval {
    /// The overlap, or nil when the two only touch or don't meet.
    func intersectionIfPositive(with other: DateInterval) -> DateInterval? {
        let s = Swift.max(start, other.start), e = Swift.min(end, other.end)
        return e > s ? DateInterval(start: s, end: e) : nil
    }

    /// This interval minus the given ones, as ordered pieces.
    func subtracting(_ cuts: [DateInterval]) -> [DateInterval] {
        var pieces: [DateInterval] = []
        var cursor = start
        for c in DateInterval.union(cuts) where c.end > start && c.start < end {
            if c.start > cursor { pieces.append(DateInterval(start: cursor, end: c.start)) }
            cursor = Swift.max(cursor, c.end)
        }
        if cursor < end { pieces.append(DateInterval(start: cursor, end: end)) }
        return pieces
    }

    /// Sorted, merged intervals.
    static func union(_ intervals: [DateInterval]) -> [DateInterval] {
        var out: [DateInterval] = []
        for i in intervals.sorted(by: { $0.start < $1.start }) where i.duration > 0 {
            if let last = out.last, i.start <= last.end {
                out[out.count - 1] = DateInterval(start: last.start, end: Swift.max(last.end, i.end))
            } else {
                out.append(i)
            }
        }
        return out
    }
}
