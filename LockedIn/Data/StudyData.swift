import Foundation

/// A finished session reduced to what the stats need.
nonisolated struct SessionSample: Sendable {
    var id: UUID
    var start: Date
    var end: Date
    var lockedSeconds: TimeInterval
    var focus: Double?
    var subjectID: UUID?
}

/// Every locked stretch as plain values: the saved sessions plus the one in progress.
struct StudyData {
    let segments: [SegmentSample]
    let sessions: [SessionSample]
    let daily: [Date: TimeInterval]
    let calendar: StatsCalendar
    let now: Date

    init(segments: [SegmentSample], sessions: [SessionSample], calendar: StatsCalendar, now: Date) {
        self.segments = segments
        self.sessions = sessions
        self.calendar = calendar
        self.now = now
        self.daily = StatsCalculator.dailyTotals(segments, calendar: calendar)
    }

    init(sessions: [StudySession], active: ActiveSession?, calendar: StatsCalendar, now: Date = .now) {
        var segments: [SegmentSample] = []
        var samples: [SessionSample] = []
        for session in sessions {
            let subjectID = session.subject?.id
            for segment in session.segments {
                segments.append(SegmentSample(start: segment.start, end: segment.end, subjectID: subjectID))
            }
            samples.append(SessionSample(
                id: session.id,
                start: session.startedAt,
                end: session.endedAt,
                lockedSeconds: session.lockedSeconds,
                focus: session.focus,
                subjectID: subjectID
            ))
        }
        if let active {
            for stretch in active.stretches {
                segments.append(SegmentSample(start: stretch.start, end: stretch.end, subjectID: active.subjectID))
            }
            if let since = active.lockedSince, now > since {
                segments.append(SegmentSample(start: since, end: now, subjectID: active.subjectID))
            }
        }
        self.init(segments: segments, sessions: samples, calendar: calendar, now: now)
    }

    var today: Date { calendar.day(for: now) }
    var todaySeconds: TimeInterval { daily[today] ?? 0 }

    func streaks(goal: TimeInterval) -> Streaks {
        StatsCalculator.streaks(dailyTotals: daily, goal: goal, today: today, calendar: calendar)
    }
}
