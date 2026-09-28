import Foundation
import SwiftData

/// Saves finished sessions to SwiftData and answers the engine's questions about saved data.
final class SessionArchiver: SessionArchiving {
    private let context: ModelContext

    init(context: ModelContext) {
        self.context = context
    }

    func archive(_ finished: FinishedSession) -> UUID {
        let session = StudySession(
            id: finished.id,
            startedAt: finished.startedAt,
            endedAt: finished.endedAt,
            lockedSeconds: finished.lockedSeconds,
            unlockCount: finished.unlockCount,
            leftAppCount: finished.leftAppCount,
            targetSeconds: finished.targetSeconds,
            endReason: finished.reason
        )
        context.insert(session)
        session.breakCount = finished.breakCount
        session.breakSeconds = finished.breakSeconds
        session.subject = subject(with: finished.subjectID)
        session.segments = finished.stretches.map {
            LockSegment(start: $0.start, end: $0.end, verified: $0.verified)
        }
        try? context.save()
        return session.id
    }

    func savedLockedSeconds(in interval: DateInterval) -> TimeInterval {
        let start = interval.start
        let end = interval.end
        let descriptor = FetchDescriptor<LockSegment>(predicate: #Predicate { $0.end > start && $0.start < end })
        let segments = (try? context.fetch(descriptor)) ?? []
        return segments.reduce(0) { total, segment in
            total + max(0, min(segment.end, end).timeIntervalSince(max(segment.start, start)))
        }
    }

    func subjectInfo(for id: UUID?) -> SubjectInfo? {
        subject(with: id)?.info
    }

    private func subject(with id: UUID?) -> Subject? {
        guard let id else { return nil }
        var descriptor = FetchDescriptor<Subject>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }
}
