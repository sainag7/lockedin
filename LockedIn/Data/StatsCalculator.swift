import Foundation

/// Calendar math that respects "New day starts at", so a 1 AM session can count toward the day before.
nonisolated struct StatsCalendar: Sendable {
    var calendar: Calendar
    var dayStartHour: Int

    /// The logical day containing `date`, identified by midnight of that calendar date.
    func day(for date: Date) -> Date {
        let shifted = calendar.date(byAdding: .hour, value: -dayStartHour, to: date) ?? date
        return calendar.startOfDay(for: shifted)
    }

    /// The real time span a logical day covers.
    func interval(forDay day: Date) -> DateInterval {
        let start = calendar.date(byAdding: .hour, value: dayStartHour, to: day) ?? day
        let next = addingDays(1, to: day)
        let end = calendar.date(byAdding: .hour, value: dayStartHour, to: next) ?? next
        return DateInterval(start: start, end: end)
    }

    func interval(containing date: Date) -> DateInterval {
        interval(forDay: day(for: date))
    }

    func addingDays(_ days: Int, to day: Date) -> Date {
        calendar.date(byAdding: .day, value: days, to: day) ?? day.addingTimeInterval(TimeInterval(days) * 86_400)
    }

    /// Logical days from `start` up to, but not including, `end`.
    func days(from start: Date, to end: Date) -> [Date] {
        var days: [Date] = []
        var cursor = start
        while cursor < end {
            days.append(cursor)
            cursor = addingDays(1, to: cursor)
        }
        return days
    }
}

/// A locked stretch reduced to what the stats need.
nonisolated struct SegmentSample: Equatable, Sendable {
    var start: Date
    var end: Date
    var subjectID: UUID?
}

nonisolated struct Streaks: Equatable, Sendable {
    var current: Int
    var best: Int
}

/// Pure aggregation functions behind every chart and number in the app.
nonisolated enum StatsCalculator {
    /// Locked seconds per logical day. Segments that cross a day boundary are split.
    static func dailyTotals(_ segments: [SegmentSample], calendar: StatsCalendar) -> [Date: TimeInterval] {
        var totals: [Date: TimeInterval] = [:]
        for segment in segments where segment.end > segment.start {
            var cursor = segment.start
            while cursor < segment.end {
                let day = calendar.day(for: cursor)
                let chunkEnd = min(segment.end, calendar.interval(forDay: day).end)
                guard chunkEnd > cursor else { break }
                totals[day, default: 0] += chunkEnd.timeIntervalSince(cursor)
                cursor = chunkEnd
            }
        }
        return totals
    }

    /// Locked seconds per clock hour (0–23) inside `range`.
    static func hourlyTotals(_ segments: [SegmentSample], within range: DateInterval, calendar: Calendar) -> [Int: TimeInterval] {
        var totals: [Int: TimeInterval] = [:]
        for segment in clip(segments, to: range) {
            var cursor = segment.start
            while cursor < segment.end {
                guard let hour = calendar.dateInterval(of: .hour, for: cursor) else { break }
                let chunkEnd = min(segment.end, hour.end)
                guard chunkEnd > cursor else { break }
                totals[calendar.component(.hour, from: cursor), default: 0] += chunkEnd.timeIntervalSince(cursor)
                cursor = chunkEnd
            }
        }
        return totals
    }

    /// Locked seconds per subject (nil = no subject) inside `range`.
    static func subjectTotals(_ segments: [SegmentSample], within range: DateInterval) -> [UUID?: TimeInterval] {
        var totals: [UUID?: TimeInterval] = [:]
        for segment in clip(segments, to: range) {
            totals[segment.subjectID, default: 0] += segment.end.timeIntervalSince(segment.start)
        }
        return totals
    }

    static func clip(_ segments: [SegmentSample], to range: DateInterval) -> [SegmentSample] {
        segments.compactMap { segment in
            let start = max(segment.start, range.start)
            let end = min(segment.end, range.end)
            return end > start ? SegmentSample(start: start, end: end, subjectID: segment.subjectID) : nil
        }
    }

    /// Streak = consecutive logical days that met the goal. Today only extends the streak;
    /// it doesn't break it until the day is over.
    static func streaks(dailyTotals: [Date: TimeInterval], goal: TimeInterval, today: Date, calendar: StatsCalendar) -> Streaks {
        guard goal > 0 else { return Streaks(current: 0, best: 0) }
        let metDays = Set(dailyTotals.filter { $0.value >= goal }.keys)

        var current = 0
        var cursor = metDays.contains(today) ? today : calendar.addingDays(-1, to: today)
        while metDays.contains(cursor) {
            current += 1
            cursor = calendar.addingDays(-1, to: cursor)
        }

        var best = 0
        for day in metDays where !metDays.contains(calendar.addingDays(-1, to: day)) {
            var length = 0
            var next = day
            while metDays.contains(next) {
                length += 1
                next = calendar.addingDays(1, to: next)
            }
            best = max(best, length)
        }
        return Streaks(current: current, best: max(best, current))
    }
}
