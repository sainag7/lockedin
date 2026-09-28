#if DEBUG
import Foundation
import SwiftData

/// Fills the database with realistic-looking past sessions so the charts can be checked.
enum SampleData {
    static func load(into context: ModelContext, calendar: StatsCalendar, days: Int = 60) {
        var subjects = (try? context.fetch(FetchDescriptor<Subject>(sortBy: [SortDescriptor(\.sortOrder)]))) ?? []
        if subjects.isEmpty {
            let defaults = [("Calculus", "📐"), ("Biology", "🧬"), ("History", "🏛️"), ("CS", "💻")]
            for (index, item) in defaults.enumerated() {
                let subject = Subject(name: item.0, emoji: item.1, colorHex: Palette.subjectHexes[index], sortOrder: index)
                context.insert(subject)
                subjects.append(subject)
            }
        }

        var random = SeededGenerator(seed: 7)
        let today = calendar.day(for: .now)
        let startHours = [9, 11, 14, 16, 19, 21]

        for offset in stride(from: days, through: 1, by: -1) {
            let day = calendar.addingDays(-offset, to: today)
            let weekday = calendar.calendar.component(.weekday, from: day)
            let isWeekend = weekday == 1 || weekday == 7
            let count = Int.random(in: isWeekend ? 0...2 : 1...3, using: &random)
            let hours = startHours.shuffled(using: &random).prefix(count).sorted()

            for hour in hours {
                guard var cursor = calendar.calendar.date(bySettingHour: hour, minute: Int.random(in: 0...40, using: &random), second: 0, of: day) else { continue }
                let startedAt = cursor
                cursor.addTimeInterval(TimeInterval(Int.random(in: 10...40, using: &random)))

                var segments: [LockSegment] = []
                let stretchCount = Int.random(in: 1...4, using: &random)
                for index in 0..<stretchCount {
                    let length = TimeInterval(Int.random(in: 12...45, using: &random) * 60)
                    segments.append(LockSegment(start: cursor, end: cursor + length, verified: true))
                    cursor += length
                    if index < stretchCount - 1 {
                        cursor += TimeInterval(Int.random(in: 1...6, using: &random) * 60)
                    }
                }

                let locked = segments.reduce(0) { $0 + $1.duration }
                let targets: [Double?] = [nil, nil, 25 * 60, 50 * 60, 90 * 60]
                let session = StudySession(
                    id: UUID(),
                    startedAt: startedAt,
                    endedAt: cursor,
                    lockedSeconds: locked,
                    unlockCount: stretchCount - 1,
                    leftAppCount: Int.random(in: 0...4, using: &random) == 0 ? 1 : 0,
                    targetSeconds: targets.randomElement(using: &random) ?? nil,
                    endReason: .manual
                )
                context.insert(session)
                session.subject = Int.random(in: 0...5, using: &random) == 0 ? nil : subjects.randomElement(using: &random)
                session.segments = segments
            }
        }
        try? context.save()
    }
}

/// Deterministic random numbers so sample data looks the same every time.
struct SeededGenerator: RandomNumberGenerator {
    private var state: UInt64

    init(seed: UInt64) {
        state = seed
    }

    mutating func next() -> UInt64 {
        state = state &* 6_364_136_223_846_793_005 &+ 1_442_695_040_888_963_407
        return state
    }
}
#endif
