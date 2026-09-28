import Foundation

/// One continuous stretch with the phone locked.
nonisolated struct LockStretch: Codable, Equatable, Sendable {
    var start: Date
    var end: Date
    /// False when the lock was inferred from timing alone (no data-protection signal).
    var verified: Bool

    var duration: TimeInterval { max(0, end.timeIntervalSince(start)) }
}

/// The session in progress. Saved on every change so it survives the app being killed.
nonisolated struct ActiveSession: Codable, Equatable, Sendable {
    nonisolated enum PauseReason: String, Codable, Sendable {
        case unlocked
        case leftApp
    }

    nonisolated enum State: Codable, Equatable, Sendable {
        /// Started, waiting for the first lock.
        case armed
        /// The phone has been locked since `since`, so the timer is running.
        case locked(since: Date, verified: Bool)
        /// The timer is stopped because the phone is unlocked (shown as "Unlocked"); locking resumes it.
        case paused(PauseReason)
        /// Paused with the Pause button: locking doesn't count until Resume.
        case onBreak(since: Date)
    }

    /// The app went to the background and we haven't yet decided whether the phone locked.
    nonisolated struct PendingCheck: Codable, Equatable, Sendable {
        var backgroundedAt: Date
        /// The app backgrounded almost instantly after resigning active, the way a lock does.
        var lockLikeTransition: Bool
    }

    var id = UUID()
    var startedAt: Date
    var subjectID: UUID?
    var targetSeconds: TimeInterval?
    var state: State = .armed
    var stretches: [LockStretch] = []
    var unlockCount = 0
    var leftAppCount = 0
    /// Start of the current not-counting period (armed or unlocked). Nil while locked or paused.
    var idleSince: Date?
    var pendingCheck: PendingCheck?
    /// When the break reminder fires, and the length that was picked.
    var breakReminderAt: Date?
    var breakReminderMinutes: Int?

    // Added with Pause. Optional so sessions saved by earlier builds still load.
    private var storedBreakCount: Int?
    private var storedBreakSeconds: TimeInterval?

    init(startedAt: Date, subjectID: UUID?, targetSeconds: TimeInterval?) {
        self.startedAt = startedAt
        self.subjectID = subjectID
        self.targetSeconds = targetSeconds
        self.idleSince = startedAt
    }

    /// Breaks taken with the Pause button.
    var breakCount: Int {
        get { storedBreakCount ?? 0 }
        set { storedBreakCount = newValue }
    }

    /// Break time after the first lock, which is left out of focus.
    var breakSeconds: TimeInterval {
        get { storedBreakSeconds ?? 0 }
        set { storedBreakSeconds = newValue }
    }

    var lockedSince: Date? {
        if case .locked(let since, _) = state { return since }
        return nil
    }

    var breakSince: Date? {
        if case .onBreak(let since) = state { return since }
        return nil
    }

    var isLocked: Bool { lockedSince != nil }
    var isArmed: Bool { state == .armed }
    var isOnBreak: Bool { breakSince != nil }

    /// Locked time from finished stretches (excludes the stretch in progress).
    var bankedSeconds: TimeInterval { stretches.reduce(0) { $0 + $1.duration } }

    var firstLockAt: Date? { stretches.first?.start ?? lockedSince }

    func lockedSeconds(at now: Date) -> TimeInterval {
        bankedSeconds + (lockedSince.map { max(0, now.timeIntervalSince($0)) } ?? 0)
    }

    func longestStretch(at now: Date) -> TimeInterval {
        let current = lockedSince.map { max(0, now.timeIntervalSince($0)) } ?? 0
        return max(stretches.map(\.duration).max() ?? 0, current)
    }

    /// Share of the time since the first lock that the phone stayed locked, not counting breaks.
    func focus(at now: Date) -> Double? {
        guard let first = firstLockAt else { return nil }
        let currentBreak = breakSince.map { max(0, now.timeIntervalSince(max($0, first))) } ?? 0
        let span = now.timeIntervalSince(first) - breakSeconds - currentBreak
        guard span > 0 else { return nil }
        return min(1, lockedSeconds(at: now) / span)
    }

    /// Locked seconds that fall inside `interval`, including the stretch in progress.
    func lockedSeconds(in interval: DateInterval, now: Date) -> TimeInterval {
        var ranges = stretches.map { ($0.start, $0.end) }
        if let since = lockedSince { ranges.append((since, now)) }
        return ranges.reduce(0) { total, range in
            total + max(0, min(range.1, interval.end).timeIntervalSince(max(range.0, interval.start)))
        }
    }
}

// MARK: - Persistence

protocol ActiveSessionStoring: AnyObject {
    func load() -> ActiveSession?
    func save(_ session: ActiveSession?)
}

/// Keeps the in-progress session in UserDefaults (JSON). Written on every state change.
final class UserDefaultsSessionStore: ActiveSessionStoring {
    private let defaults: UserDefaults
    private let key = "activeSession.v1"

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
    }

    func load() -> ActiveSession? {
        guard let data = defaults.data(forKey: key) else { return nil }
        return try? JSONDecoder().decode(ActiveSession.self, from: data)
    }

    func save(_ session: ActiveSession?) {
        if let session, let data = try? JSONEncoder().encode(session) {
            defaults.set(data, forKey: key)
        } else {
            defaults.removeObject(forKey: key)
        }
    }
}
