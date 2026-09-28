import Foundation
import SwiftData

@Model
final class Subject {
    var id: UUID = UUID()
    var name: String = ""
    var emoji: String = ""
    var colorHex: String = "BEF264"
    var sortOrder: Int = 0
    var isArchived: Bool = false
    var createdAt: Date = Date.now

    @Relationship(deleteRule: .nullify, inverse: \StudySession.subject)
    var sessions: [StudySession] = []

    init(name: String, emoji: String, colorHex: String, sortOrder: Int) {
        self.name = name
        self.emoji = emoji
        self.colorHex = colorHex
        self.sortOrder = sortOrder
    }

    var info: SubjectInfo {
        SubjectInfo(id: id, name: name, emoji: emoji, colorHex: colorHex)
    }

    /// "📐 Calculus", or just the name when there's no emoji.
    var label: String { emoji.isEmpty ? name : "\(emoji) \(name)" }
}

@Model
final class StudySession {
    var id: UUID = UUID()
    var startedAt: Date = Date.now
    var endedAt: Date = Date.now
    var lockedSeconds: Double = 0
    var unlockCount: Int = 0
    var leftAppCount: Int = 0
    var targetSeconds: Double?
    var endReasonRaw: String = EndReason.manual.rawValue
    var note: String = ""
    var breakCount: Int = 0
    /// Break time after the first lock, which is left out of focus.
    var breakSeconds: Double = 0
    var subject: Subject?

    @Relationship(deleteRule: .cascade, inverse: \LockSegment.session)
    var segments: [LockSegment] = []

    init(
        id: UUID,
        startedAt: Date,
        endedAt: Date,
        lockedSeconds: Double,
        unlockCount: Int,
        leftAppCount: Int,
        targetSeconds: Double?,
        endReason: EndReason
    ) {
        self.id = id
        self.startedAt = startedAt
        self.endedAt = endedAt
        self.lockedSeconds = lockedSeconds
        self.unlockCount = unlockCount
        self.leftAppCount = leftAppCount
        self.targetSeconds = targetSeconds
        self.endReasonRaw = endReason.rawValue
    }

    var endReason: EndReason { EndReason(rawValue: endReasonRaw) ?? .manual }
    var orderedSegments: [LockSegment] { segments.sorted { $0.start < $1.start } }
    var firstLockAt: Date? { segments.map(\.start).min() }
    var longestStretch: TimeInterval { segments.map(\.duration).max() ?? 0 }

    /// Share of the time between the first lock and the end that the phone stayed locked, not counting breaks.
    var focus: Double? {
        guard let first = firstLockAt else { return nil }
        let span = endedAt.timeIntervalSince(first) - breakSeconds
        return span > 0 ? min(1, lockedSeconds / span) : nil
    }
}

@Model
final class LockSegment {
    var start: Date = Date.now
    var end: Date = Date.now
    var verified: Bool = true
    var session: StudySession?

    init(start: Date, end: Date, verified: Bool) {
        self.start = start
        self.end = end
        self.verified = verified
    }

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}
