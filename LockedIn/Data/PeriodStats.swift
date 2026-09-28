import Foundation
import SwiftUI

nonisolated enum StatsRange: String, CaseIterable, Identifiable, Sendable {
    case week, month, year

    var id: String { rawValue }
    var title: String { rawValue.capitalized }

    var component: Calendar.Component {
        switch self {
        case .week: .weekOfYear
        case .month: .month
        case .year: .year
        }
    }
}

struct ChartBucket: Identifiable, Equatable {
    let date: Date
    let seconds: TimeInterval
    var id: Date { date }
    var minutes: Double { seconds / 60 }
}

struct SubjectSlice: Identifiable {
    let id: String
    let name: String
    let color: Color
    let seconds: TimeInterval
}

struct HourBucket: Identifiable {
    let hour: Int
    let seconds: TimeInterval
    var id: Int { hour }
}

/// Everything the Stats screen shows for one week, month, or year.
struct PeriodStats {
    let range: StatsRange
    let title: String
    let subtitle: String
    let isCurrent: Bool
    let buckets: [ChartBucket]
    let total: TimeInterval
    /// The previous period, over the same number of days when this one is still in progress.
    let previousTotal: TimeInterval
    let dailyAverage: TimeInterval
    let bestDay: ChartBucket?
    let longestSession: TimeInterval
    let sessionCount: Int
    let averageFocus: Double?
    let goalDays: Int
    let countedDays: Int
    let subjects: [SubjectSlice]
    let hours: [HourBucket]
    let insights: [String]

    init(data: StudyData, range: StatsRange, offset: Int, goal: TimeInterval, subjects: [UUID: SubjectInfo]) {
        let cal = data.calendar
        let daily = data.daily
        let secondsOn: (Date) -> TimeInterval = { daily[$0] ?? 0 }
        let sum: ([Date]) -> TimeInterval = { days in days.reduce(0) { $0 + secondsOn($1) } }
        let days = Self.days(range, offset: offset, data: data)
        let previousDays = Self.days(range, offset: offset - 1, data: data)
        let counted = days.filter { $0 <= data.today }

        self.range = range
        self.isCurrent = offset == 0
        (self.title, self.subtitle) = Self.titles(range: range, offset: offset, days: days, calendar: cal.calendar)

        // Bars: one per day, or one per month for a year.
        if range == .year {
            let byMonth: [Date: [Date]] = Dictionary(grouping: days) { day in
                cal.calendar.dateInterval(of: .month, for: day)?.start ?? day
            }
            buckets = byMonth.keys.sorted().map { month in
                ChartBucket(date: month, seconds: sum(byMonth[month] ?? []))
            }
        } else {
            buckets = days.map { ChartBucket(date: $0, seconds: secondsOn($0)) }
        }

        let total = sum(days)
        let comparableDays = isCurrent ? Array(previousDays.prefix(counted.count)) : previousDays
        let previousTotal = sum(comparableDays)
        self.total = total
        self.previousTotal = previousTotal
        self.countedDays = counted.count
        self.dailyAverage = counted.isEmpty ? 0 : total / Double(counted.count)
        self.goalDays = counted.filter { secondsOn($0) >= goal }.count
        let countedBuckets: [ChartBucket] = counted.map { ChartBucket(date: $0, seconds: secondsOn($0)) }
        self.bestDay = countedBuckets.filter { $0.seconds > 0 }.max { $0.seconds < $1.seconds }

        // Sessions are grouped by the logical day they started on.
        let daySet = Set(days)
        let sessions = data.sessions.filter { daySet.contains(cal.day(for: $0.start)) }
        self.sessionCount = sessions.count
        self.longestSession = sessions.map(\.lockedSeconds).max() ?? 0
        let focusValues = sessions.compactMap(\.focus)
        self.averageFocus = focusValues.isEmpty ? nil : focusValues.reduce(0, +) / Double(focusValues.count)

        // Subject and time-of-day breakdowns use the period's real time span.
        let span: DateInterval
        if let first = days.first, let last = days.last {
            span = DateInterval(start: cal.interval(forDay: first).start, end: cal.interval(forDay: last).end)
        } else {
            span = DateInterval(start: data.now, duration: 0)
        }

        let bySubject = StatsCalculator.subjectTotals(data.segments, within: span)
        let slices = bySubject
            .filter { $0.value > 0 }
            .map { id, seconds -> SubjectSlice in
                let info = id.flatMap { subjects[$0] }
                return SubjectSlice(
                    id: id?.uuidString ?? "none",
                    name: info.map { $0.emoji.isEmpty ? $0.name : "\($0.emoji) \($0.name)" } ?? "No subject",
                    color: info.map { Palette.subjectColor($0.colorHex) } ?? Color.white.opacity(0.35),
                    seconds: seconds
                )
            }
            .sorted { $0.seconds > $1.seconds }
        self.subjects = slices

        let hourly = StatsCalculator.hourlyTotals(data.segments, within: span, calendar: cal.calendar)
        self.hours = (0..<24).map { HourBucket(hour: $0, seconds: hourly[$0] ?? 0) }

        var weekdayTotals: [Int: TimeInterval] = [:]
        for day in counted {
            weekdayTotals[cal.calendar.component(.weekday, from: day), default: 0] += data.daily[day] ?? 0
        }

        self.insights = Insights.make(
            range: range,
            isCurrent: isCurrent,
            total: total,
            previousTotal: previousTotal,
            hourly: hourly,
            topSubject: slices.first.map { ($0.name, $0.seconds) },
            hasSubjects: slices.contains { $0.id != "none" },
            goalDays: goalDays,
            countedDays: counted.count,
            weekdayTotals: weekdayTotals,
            calendar: cal.calendar
        )
    }

    private static func days(_ range: StatsRange, offset: Int, data: StudyData) -> [Date] {
        let calendar = data.calendar.calendar
        guard let current = calendar.dateInterval(of: range.component, for: data.today),
              let start = calendar.date(byAdding: range.component, value: offset, to: current.start),
              let end = calendar.date(byAdding: range.component, value: 1, to: start)
        else { return [data.today] }
        return data.calendar.days(from: start, to: end)
    }

    private static func titles(range: StatsRange, offset: Int, days: [Date], calendar: Calendar) -> (String, String) {
        guard let first = days.first, let last = days.last else { return ("", "") }
        switch range {
        case .week:
            let sameMonth = calendar.isDate(first, equalTo: last, toGranularity: .month)
            let end = sameMonth ? last.formatted(.dateTime.day()) : last.formatted(.dateTime.month(.abbreviated).day())
            let title = "\(first.formatted(.dateTime.month(.abbreviated).day())) – \(end)"
            let subtitle = offset == 0 ? "This week" : offset == -1 ? "Last week" : "\(-offset) weeks ago"
            return (title, subtitle)
        case .month:
            let subtitle = offset == 0 ? "This month" : offset == -1 ? "Last month" : "\(-offset) months ago"
            return (first.formatted(.dateTime.month(.wide).year()), subtitle)
        case .year:
            let subtitle = offset == 0 ? "This year" : offset == -1 ? "Last year" : "\(-offset) years ago"
            return (first.formatted(.dateTime.year()), subtitle)
        }
    }
}

/// Plain-language takeaways shown under the charts.
nonisolated enum Insights {
    static func make(
        range: StatsRange,
        isCurrent: Bool,
        total: TimeInterval,
        previousTotal: TimeInterval,
        hourly: [Int: TimeInterval],
        topSubject: (name: String, seconds: TimeInterval)?,
        hasSubjects: Bool,
        goalDays: Int,
        countedDays: Int,
        weekdayTotals: [Int: TimeInterval],
        calendar: Calendar
    ) -> [String] {
        guard total > 0 else { return [] }
        var lines: [String] = []
        let noun = range.rawValue
        let comparedTo = isCurrent ? "this point last \(noun)" : "the \(noun) before"

        if previousTotal > 0 {
            let change = (total - previousTotal) / previousTotal
            let percent = Int((abs(change) * 100).rounded())
            if percent < 5 {
                lines.append("About the same as \(comparedTo).")
            } else if change > 0 {
                lines.append("Up \(percent)% from \(comparedTo). 📈")
            } else {
                lines.append("Down \(percent)% from \(comparedTo). Time to lock back in.")
            }
        } else if isCurrent {
            lines.append("Your first tracked \(noun). Nice start! 🎉")
        }

        if total >= 30 * 60, let peak = (0..<24).max(by: { window(hourly, $0) < window(hourly, $1) }), window(hourly, peak) > 0 {
            lines.append("You lock in most between \(hourName(peak, calendar)) and \(hourName((peak + 2) % 24, calendar)).")
        }

        if hasSubjects, let top = topSubject {
            lines.append("Most of your time went to \(top.name) (\(DurationText.short(top.seconds))).")
        }

        if countedDays >= 2 {
            lines.append("You hit your daily goal on \(goalDays) of \(countedDays) days.")
        }

        if range != .week, let best = weekdayTotals.max(by: { $0.value < $1.value }), best.value > 0 {
            let name = calendar.weekdaySymbols[(best.key - 1) % 7]
            lines.append("\(name)s are your strongest day.")
        }

        return Array(lines.prefix(4))
    }

    /// Seconds in the two-hour window starting at `hour`.
    private static func window(_ hourly: [Int: TimeInterval], _ hour: Int) -> TimeInterval {
        (hourly[hour] ?? 0) + (hourly[(hour + 1) % 24] ?? 0)
    }

    private static func hourName(_ hour: Int, _ calendar: Calendar) -> String {
        let date = calendar.date(bySettingHour: hour, minute: 0, second: 0, of: .now) ?? .now
        return date.formatted(.dateTime.hour())
    }
}
