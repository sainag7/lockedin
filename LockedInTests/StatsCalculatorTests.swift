import Foundation
import Testing
@testable import LockedIn

struct StatsCalculatorTests {
    private func calendar(dayStartHour: Int = 0) -> StatsCalendar {
        StatsCalendar(calendar: utc, dayStartHour: dayStartHour)
    }

    private func date(_ day: Int, _ hour: Int, _ minute: Int = 0) -> Date {
        utc.date(from: DateComponents(year: 2026, month: 3, day: day, hour: hour, minute: minute))!
    }

    @Test func splitsSegmentsAtMidnight() {
        let cal = calendar()
        let totals = StatsCalculator.dailyTotals(
            [SegmentSample(start: date(10, 23), end: date(11, 1), subjectID: nil)],
            calendar: cal
        )
        #expect(totals[cal.day(for: date(10, 12))] == hour)
        #expect(totals[cal.day(for: date(11, 12))] == hour)
    }

    @Test func lateNightCountsTowardThePreviousDayWithAShiftedDayStart() {
        let cal = calendar(dayStartHour: 4)
        let totals = StatsCalculator.dailyTotals(
            [SegmentSample(start: date(10, 23), end: date(11, 1), subjectID: nil)],
            calendar: cal
        )
        #expect(totals.count == 1)
        #expect(totals[cal.day(for: date(10, 12))] == 2 * hour)
        #expect(cal.day(for: date(11, 3, 59)) == cal.day(for: date(10, 12)))
        #expect(cal.day(for: date(11, 4)) == cal.day(for: date(11, 12)))
    }

    @Test func hourlyTotalsSplitAtHourBoundaries() {
        let segment = SegmentSample(start: date(10, 13, 30), end: date(10, 15, 15), subjectID: nil)
        let range = DateInterval(start: date(10, 0), end: date(11, 0))
        let totals = StatsCalculator.hourlyTotals([segment], within: range, calendar: utc)
        #expect(totals[13] == 30 * minute)
        #expect(totals[14] == hour)
        #expect(totals[15] == 15 * minute)
    }

    @Test func subjectTotalsClipToTheRange() {
        let math = UUID()
        let segments = [
            SegmentSample(start: date(9, 23), end: date(10, 1), subjectID: math),
            SegmentSample(start: date(10, 9), end: date(10, 10), subjectID: nil),
        ]
        let totals = StatsCalculator.subjectTotals(segments, within: DateInterval(start: date(10, 0), end: date(11, 0)))
        #expect(totals[math] == hour)
        #expect(totals[nil] == hour)
    }

    @Test func streakCountsConsecutiveGoalDaysAndTodayOnlyExtendsIt() {
        let cal = calendar()
        let today = cal.day(for: date(10, 12))
        func day(_ offset: Int) -> Date { cal.addingDays(offset, to: today) }

        var totals: [Date: TimeInterval] = [
            day(-6): hour, day(-5): hour, day(-4): hour,  // best run: 3
            day(-2): hour, day(-1): hour,                 // current run through yesterday: 2
            day(0): 20 * minute,                          // today not done yet
        ]
        #expect(StatsCalculator.streaks(dailyTotals: totals, goal: hour, today: today, calendar: cal) == Streaks(current: 2, best: 3))

        totals[day(0)] = hour
        #expect(StatsCalculator.streaks(dailyTotals: totals, goal: hour, today: today, calendar: cal) == Streaks(current: 3, best: 3))

        totals[day(-1)] = 0
        #expect(StatsCalculator.streaks(dailyTotals: totals, goal: hour, today: today, calendar: cal) == Streaks(current: 1, best: 3))
    }

    @Test func weekStatsCompareAgainstTheSamePointLastWeek() {
        // Tuesday, March 10 2026. Weeks start on Sunday in the Gregorian default.
        let cal = calendar()
        let now = date(10, 20)
        let segments = [
            // Last week: Sunday 1h, Monday 1h, Friday 3h (after "this point").
            SegmentSample(start: date(1, 9), end: date(1, 10), subjectID: nil),
            SegmentSample(start: date(2, 9), end: date(2, 10), subjectID: nil),
            SegmentSample(start: date(6, 9), end: date(6, 12), subjectID: nil),
            // This week: Monday 2h, Tuesday 1h.
            SegmentSample(start: date(9, 9), end: date(9, 11), subjectID: nil),
            SegmentSample(start: date(10, 18), end: date(10, 19), subjectID: nil),
        ]
        let data = StudyData(segments: segments, sessions: [], calendar: cal, now: now)
        let stats = PeriodStats(data: data, range: .week, offset: 0, goal: 90 * minute, subjects: [:])

        #expect(stats.buckets.count == 7)
        #expect(stats.total == 3 * hour)
        #expect(stats.countedDays == 3)
        #expect(stats.previousTotal == 2 * hour)   // Sun–Tue last week only
        #expect(stats.goalDays == 1)
        #expect(stats.bestDay?.seconds == 2 * hour)
        #expect(stats.insights.first == "Up 50% from this point last week. 📈")

        let lastWeek = PeriodStats(data: data, range: .week, offset: -1, goal: 90 * minute, subjects: [:])
        #expect(lastWeek.total == 5 * hour)
        #expect(lastWeek.countedDays == 7)
    }

    @Test func yearStatsBucketByMonth() {
        let cal = calendar()
        let data = StudyData(
            segments: [
                SegmentSample(start: date(2, 9), end: date(2, 10), subjectID: nil),
                SegmentSample(start: date(10, 9), end: date(10, 11), subjectID: nil),
            ],
            sessions: [],
            calendar: cal,
            now: date(10, 20)
        )
        let stats = PeriodStats(data: data, range: .year, offset: 0, goal: hour, subjects: [:])
        #expect(stats.buckets.count == 12)
        #expect(stats.buckets[2].seconds == 3 * hour)   // March
    }
}
