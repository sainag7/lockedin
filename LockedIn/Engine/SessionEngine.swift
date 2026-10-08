import Foundation
import Observation

// MARK: - Collaborators (protocols so tests can swap in fakes)

protocol LiveActivityControlling: AnyObject {
    /// Shows `state` for the session: updates its Live Activity, starting one if needed (only
    /// possible while LockedIn is on screen), and ends any strays.
    func show(_ attributes: LockInActivityAttributes, state: LockInActivityAttributes.ContentState, staleDate: Date?)
    /// Ends the Live Activity. Unless `immediately`, the final state stays on the Lock Screen a while.
    func end(_ finalState: LockInActivityAttributes.ContentState?, immediately: Bool)
    /// Re-attaches to the Live Activity for `sessionID` if one is on screen and ends any others.
    func cleanUp(keeping sessionID: UUID?)
}

/// Keeps LockedIn running in the background during a session, so it hears every lock and unlock,
/// and plays the chosen focus sound.
protocol BackgroundKeepingAlive: AnyObject {
    var isRunning: Bool { get }
    func start()
    func stop()
    /// Restarts playback if something stopped it.
    func ensurePlaying()
    func setSound(_ sound: BackgroundSound)
    func setVolume(_ volume: Double)
}

protocol SessionNotifying: AnyObject {
    func scheduleWhileLocked(_ plan: LockedNotificationPlan)
    func cancelWhileLocked()
    /// `lockAnywhere`: the phone can be locked from any app (background tracking is on).
    func scheduleBreakNudge(at date: Date, lockAnywhere: Bool)
    func cancelBreakNudge()
    func notifyLeftApp(sessionStarted: Bool)
    func clearLeftAppAlerts()
    func scheduleBreakReminder(at date: Date)
    func cancelBreakReminder()
    func cancelSessionNotifications()
}

protocol SessionArchiving: AnyObject {
    /// Saves a finished session and returns its id.
    func archive(_ session: FinishedSession) -> UUID
    /// Locked seconds already saved that fall inside `interval`.
    func savedLockedSeconds(in interval: DateInterval) -> TimeInterval
    func subjectInfo(for id: UUID?) -> SubjectInfo?
}

// MARK: - Values

nonisolated struct SubjectInfo: Equatable, Sendable {
    var id: UUID
    var name: String
    var emoji: String
    var colorHex: String
}

nonisolated enum EndReason: String, Codable, Sendable {
    case manual
    /// The phone stayed locked past the auto-end limit.
    case lockLimit
    /// Paused for too long.
    case idle
    /// The phone restarted while locked.
    case deviceRestarted
    /// Paused (with the Pause button) for too long.
    case longBreak

    var explanation: String? {
        switch self {
        case .manual: nil
        case .lockLimit: "Your phone stayed locked past your auto-end limit, so the session stopped counting there. You can change the limit in Settings."
        case .idle: "Your phone stayed unlocked for over an hour, so the session ended when you last unlocked."
        case .deviceRestarted: "Your phone restarted during the session, so the last locked stretch couldn't be counted."
        case .longBreak: "The session was paused for over 4 hours, so it ended when you paused."
        }
    }
}

nonisolated struct FinishedSession: Equatable, Sendable {
    var id: UUID
    var startedAt: Date
    var endedAt: Date
    var subjectID: UUID?
    var targetSeconds: TimeInterval?
    var stretches: [LockStretch]
    var unlockCount: Int
    var leftAppCount: Int
    var reason: EndReason
    var breakCount = 0
    /// Break time after the first lock, which is left out of focus.
    var breakSeconds: TimeInterval = 0

    var lockedSeconds: TimeInterval { stretches.reduce(0) { $0 + $1.duration } }
    var firstLockAt: Date? { stretches.first?.start }
    var longestStretch: TimeInterval { stretches.map(\.duration).max() ?? 0 }

    var focus: Double? {
        guard let first = firstLockAt else { return nil }
        let span = endedAt.timeIntervalSince(first) - breakSeconds
        return span > 0 ? min(1, lockedSeconds / span) : nil
    }
}

/// Notifications to schedule when a locked stretch starts.
nonisolated struct LockedNotificationPlan: Equatable, Sendable {
    var targetAt: Date?
    var targetSeconds: TimeInterval?
    var dailyGoalAt: Date?
    var dailyGoalSeconds: TimeInterval = 0
    var autoEndAt: Date?
    var autoEndSeconds: TimeInterval?
}

nonisolated struct EngineConfig: Sendable {
    var dailyGoal: TimeInterval = 2 * 3600
    /// End the session once the phone has stayed locked this long in one stretch. Nil = never.
    var autoEndAfter: TimeInterval? = 3 * 3600
    /// End the session once it has been unlocked (or waiting for the first lock) this long.
    var idleAutoEnd: TimeInterval = 60 * 60
    /// End the session once it has been paused with the Pause button this long.
    var breakAutoEnd: TimeInterval = 4 * 3600
    /// Nudge after being unlocked this long. Nil = off.
    var breakNudgeAfter: TimeInterval? = 5 * 60
    /// Sessions with less locked time than this aren't saved.
    var minimumSessionLength: TimeInterval = 60
    /// Keep LockedIn running in the background so locks and unlocks count in any app.
    var trackLocksAnywhere = true
    /// The focus sound to play during a session (`none` = silence, keep-alive only).
    var sound: BackgroundSound = .none
    /// Focus-sound volume, 0...1.
    var soundVolume: Double = 0.6
}

nonisolated enum LockVerdict: Equatable, Sendable {
    case locked(verified: Bool)
    case leftApp
    /// Looked like a lock, but the phone was unlocked again before iOS reported it.
    case unlockedQuickly
    case noCheckPending
}

/// Shown as a sheet when a session ends.
struct SessionSummary: Identifiable, Equatable {
    let id: UUID
    let session: FinishedSession
    /// Nil when the session was too short to keep.
    let savedSessionID: UUID?
    let subject: SubjectInfo?
}

/// The stretch credited by an unlock, shown as "+23:14 locked in".
struct StretchCredit: Equatable {
    let id = UUID()
    let seconds: TimeInterval
    let at: Date
}

// MARK: - Engine

/// The session state machine:
///
///     idle ─start→ armed ─app backgrounds→ (checking)
///     checking ─lock evidence→ locked(since: when it backgrounded, or when iOS locked)
///     checking ─no evidence→ paused(.leftApp)
///     checking ─app returns first→ credited if the exit looked like a lock, otherwise nothing
///     locked ─app becomes active (= unlock)→ paused(.unlocked), stretch credited
///     paused ─app backgrounds→ (checking) …
///
/// With background tracking on, LockedIn stays running during a session, so the phone's own lock
/// and unlock signals drive the timer in any app (`deviceLocked` / `deviceUnlocked`). Without it,
/// "unlock" is LockedIn returning to the foreground (iOS reopens the app that was on screen when
/// the phone locked). `LockDetector` supplies the evidence either way.
@MainActor
@Observable
final class SessionEngine {
    private(set) var session: ActiveSession?
    private(set) var subject: SubjectInfo?
    /// Set when a session ends; the UI presents it as a summary.
    var summary: SessionSummary?
    /// The stretch credited by the most recent unlock.
    private(set) var lastCredit: StretchCredit?
    /// Kept current by `LockDetector`; drives the "no passcode" warning.
    var deviceHasPasscode = true

    /// Protected data goes away about this long after the phone locks. iOS posts its "will become
    /// unavailable" notice at the lock itself, so only a lock spotted by polling is this late.
    static let protectedDataLockDelay: TimeInterval = 10

    @ObservationIgnored private let store: ActiveSessionStoring
    @ObservationIgnored private let liveActivity: LiveActivityControlling
    @ObservationIgnored private let notifier: SessionNotifying
    @ObservationIgnored private let archive: SessionArchiving
    @ObservationIgnored private let keepAlive: BackgroundKeepingAlive
    @ObservationIgnored private let config: () -> EngineConfig
    @ObservationIgnored private let dayInterval: (Date) -> DateInterval
    @ObservationIgnored private let bootTime: () -> Date?
    @ObservationIgnored var log: (String) -> Void = { _ in }

    init(
        store: ActiveSessionStoring,
        liveActivity: LiveActivityControlling,
        notifier: SessionNotifying,
        archive: SessionArchiving,
        keepAlive: BackgroundKeepingAlive,
        config: @escaping () -> EngineConfig,
        dayInterval: @escaping (Date) -> DateInterval,
        bootTime: @escaping () -> Date?
    ) {
        self.store = store
        self.liveActivity = liveActivity
        self.notifier = notifier
        self.archive = archive
        self.keepAlive = keepAlive
        self.config = config
        self.dayInterval = dayInterval
        self.bootTime = bootTime
        let restored = store.load()
        session = restored
        subject = archive.subjectInfo(for: restored?.subjectID)
    }

    // MARK: User actions

    func start(subjectID: UUID?, targetSeconds: TimeInterval?, at now: Date = .now) {
        guard session == nil else { return }
        let new = ActiveSession(startedAt: now, subjectID: subjectID, targetSeconds: targetSeconds)
        session = new
        subject = archive.subjectInfo(for: subjectID)
        summary = nil
        lastCredit = nil
        persist()
        notifier.cancelSessionNotifications()
        syncKeepAlive()
        pushLiveActivity(new)
        log("Session started" + (targetSeconds.map { " with a \(DurationText.short($0)) target" } ?? ""))
    }

    /// Ends the session and saves it (if it has enough locked time).
    func end(at now: Date = .now) {
        finish(reason: .manual, at: now)
    }

    /// Throws away the session without saving it.
    func cancel() {
        guard session != nil else { return }
        notifier.cancelSessionNotifications()
        liveActivity.end(nil, immediately: true)
        session = nil
        subject = nil
        persist()
        keepAlive.stop()
        log("Session cancelled")
    }

    // MARK: Pause

    /// A session can be paused while it's waiting for the first lock or unlocked.
    var canPause: Bool {
        guard let s = session, s.pendingCheck == nil else { return false }
        switch s.state {
        case .armed, .paused: return true
        case .locked, .onBreak: return false
        }
    }

    /// Pauses the session. Locking the phone won't count until `resume`.
    func pause(at now: Date = .now) {
        guard canPause, var s = session else { return }
        s.state = .onBreak(since: now)
        s.idleSince = nil
        session = s
        persist()
        notifier.cancelBreakNudge()
        notifier.clearLeftAppAlerts()
        syncKeepAlive()
        pushLiveActivity(s)
        log("Paused")
    }

    /// Ends the pause, so locking the phone counts again.
    func resume(at now: Date = .now) {
        guard var s = session, let since = s.breakSince else { return }
        closeBreak(&s, since: since, at: now)
        s.state = s.stretches.isEmpty ? .armed : .paused(.unlocked)
        s.idleSince = now
        session = s
        persist()
        notifier.cancelBreakReminder()
        syncKeepAlive()
        if !s.isArmed, let nudge = config().breakNudgeAfter {
            notifier.scheduleBreakNudge(at: now.addingTimeInterval(nudge), lockAnywhere: tracksLocksAnywhere)
        }
        pushLiveActivity(s)
        log("Resumed after a \(DurationText.short(now.timeIntervalSince(since))) break")
    }

    /// Sets a reminder that the break is over, `minutes` from now, or clears it with nil.
    func setBreakReminder(minutes: Int?, at now: Date = .now) {
        guard var s = session, s.isOnBreak else { return }
        notifier.cancelBreakReminder()
        s.breakReminderMinutes = minutes
        s.breakReminderAt = minutes.map { now.addingTimeInterval(TimeInterval($0 * 60)) }
        if let at = s.breakReminderAt { notifier.scheduleBreakReminder(at: at) }
        session = s
        persist()
    }

    // MARK: Background tracking

    /// True while LockedIn is catching locks and unlocks in any app. The background audio may also be
    /// running just to play a focus sound, which is why this checks the setting, not only the audio.
    var tracksLocksAnywhere: Bool {
        guard session != nil, keepAlive.isRunning else { return false }
        return config().trackLocksAnywhere && deviceHasPasscode
    }

    /// Whether the background audio should run: to track locks, or to play a chosen focus sound.
    private var needsBackgroundAudio: Bool {
        let cfg = config()
        return (cfg.trackLocksAnywhere && deviceHasPasscode) || !cfg.sound.isSilent
    }

    /// Starts or stops the background audio to match the session, the tracking setting and the sound.
    func syncKeepAlive() {
        let cfg = config()
        if let s = session, !s.isOnBreak, needsBackgroundAudio {
            keepAlive.setSound(cfg.sound)
            keepAlive.setVolume(cfg.soundVolume)
            keepAlive.start()
        } else {
            keepAlive.stop()
        }
    }

    /// Call when the tracking setting changes: re-syncs the audio and updates the Lock Screen hint.
    func trackingSettingChanged() {
        syncKeepAlive()
        if let s = session { pushLiveActivity(s) }
    }

    /// Call when the focus sound or its volume changes: applies it live.
    func soundSettingChanged() {
        syncKeepAlive()
        if let s = session { pushLiveActivity(s) }
    }

    // MARK: Lock detection events

    /// True when the app going to the background should start a lock check.
    var needsLockCheck: Bool {
        guard let session else { return false }
        return !session.isLocked && !session.isOnBreak
    }

    func appDidEnterBackground(at time: Date, lockLikeTransition: Bool) {
        guard var s = session, !s.isLocked, !s.isOnBreak else { return }
        s.pendingCheck = .init(backgroundedAt: time, lockLikeTransition: lockLikeTransition)
        session = s
        persist()
        // A lock-like transition starts the Lock Screen timer right away. Anything slower looks like
        // going Home or to another app, so the timer stays stopped unless a lock is confirmed later.
        if lockLikeTransition {
            pushLiveActivity(s, lockedSince: time)
        }
    }

    /// The phone is locked. After a lock-like transition, counting starts from the moment the app
    /// went to the background. After a slower one, the lock came later (say, from the Home Screen),
    /// so counting starts at `lockedAt`, the detector's best guess at when the phone locked.
    /// Returns when counting starts.
    @discardableResult
    func lockConfirmed(verified: Bool, lockedAt: Date) -> Date? {
        guard var s = session, let check = s.pendingCheck else { return nil }
        let since = check.lockLikeTransition ? check.backgroundedAt : max(check.backgroundedAt, lockedAt)
        s.pendingCheck = nil
        s.state = .locked(since: since, verified: verified)
        s.idleSince = nil
        session = s
        persist()
        notifier.cancelBreakNudge()
        notifier.clearLeftAppAlerts()
        notifier.scheduleWhileLocked(notificationPlan(for: s, lockedSince: since))
        pushLiveActivity(s)
        return since
    }

    /// The background check ran out of time without the phone's protected data going away.
    ///
    /// Normally a lock-like transition still counts as a lock: the check had to stop at ~25 s,
    /// while that signal can take up to ~40 s. With background tracking the check waits longer than
    /// that (`lockSignalExpected`), so no signal means the phone was unlocked again within seconds,
    /// likely straight into another app. Anything that wasn't lock-like means the user left the app.
    @discardableResult
    func lockCheckExpired(lockSignalExpected: Bool = false) -> LockVerdict {
        guard var s = session, let check = s.pendingCheck else { return .noCheckPending }
        if check.lockLikeTransition && lockSignalExpected {
            s.pendingCheck = nil
            session = s
            persist()
            pushLiveActivity(s)
            return .unlockedQuickly
        }
        if check.lockLikeTransition {
            lockConfirmed(verified: false, lockedAt: check.backgroundedAt)
            return .locked(verified: false)
        }
        s.pendingCheck = nil
        s.leftAppCount += 1
        let started = !s.isArmed
        if started { s.state = .paused(.leftApp) }
        session = s
        persist()
        notifier.notifyLeftApp(sessionStarted: started)
        pushLiveActivity(s)
        return .leftApp
    }

    func appDidBecomeActive(at now: Date = .now) {
        guard var s = session else { return }
        if let check = s.pendingCheck {
            s.pendingCheck = nil
            if check.lockLikeTransition {
                // Unlocked before the lock signal arrived. It looked like a lock (and the Lock
                // Screen showed the timer running), so credit it like one.
                s.state = .locked(since: check.backgroundedAt, verified: false)
                s.idleSince = nil
                session = s
            } else {
                // Went Home or to another app and came back: nothing to credit.
                session = s
                persist()
            }
        }
        notifier.clearLeftAppAlerts()
        if config().trackLocksAnywhere { keepAlive.ensurePlaying() }

        switch s.state {
        case .locked(let since, let verified):
            handleUnlock(lockedSince: since, verified: verified, at: now)
        case .armed, .paused:
            let idleLimit = config().idleAutoEnd
            if let idle = s.idleSince, now.timeIntervalSince(idle) > idleLimit {
                log("Unlocked for over \(DurationText.short(idleLimit)); ending the session")
                finish(reason: .idle, at: idle)
            } else {
                // Re-sync the Lock Screen with the app every time it opens.
                pushLiveActivity(s)
            }
        case .onBreak(let since):
            if !endIfBreakTooLong(since: since, now: now) { pushLiveActivity(s) }
        }
    }

    /// Call once at launch, before the first `appDidBecomeActive`.
    func restoreAfterLaunch() {
        liveActivity.cleanUp(keeping: session?.id)
        if var s = session, let check = s.pendingCheck {
            // The app was killed mid-check. A lock-like exit counts as a lock (credited on the next
            // unlock, like any lock the app was killed during); anything else is dropped.
            s.pendingCheck = nil
            if check.lockLikeTransition {
                s.state = .locked(since: check.backgroundedAt, verified: false)
                s.idleSince = nil
            }
            session = s
            persist()
            log("Restored a session whose lock check never finished")
        }
        syncKeepAlive()
    }

    /// The phone locked while LockedIn was in the background, from whatever app was open. Counting
    /// starts at `estimate`, never earlier than the pause began. After a long break, the session
    /// ends instead of resuming.
    @discardableResult
    func deviceLocked(estimatedAt estimate: Date, now: Date = .now) -> Bool {
        guard var s = session, !s.isLocked, !s.isOnBreak, s.pendingCheck == nil else { return false }
        let pauseStart = s.idleSince ?? s.startedAt
        let idleLimit = config().idleAutoEnd
        if now.timeIntervalSince(pauseStart) > idleLimit {
            log("Unlocked for over \(DurationText.short(idleLimit)); ending the session instead of resuming")
            finish(reason: .idle, at: pauseStart)
            return false
        }
        let since = min(max(estimate, pauseStart), now)
        s.state = .locked(since: since, verified: true)
        s.idleSince = nil
        session = s
        persist()
        notifier.cancelBreakNudge()
        notifier.clearLeftAppAlerts()
        notifier.scheduleWhileLocked(notificationPlan(for: s, lockedSince: since))
        pushLiveActivity(s)
        return true
    }

    /// The phone unlocked, whichever app it opens to: stop the timer now.
    @discardableResult
    func deviceUnlocked(at time: Date) -> Bool {
        guard let s = session, case .locked(let since, let verified) = s.state else { return false }
        handleUnlock(lockedSince: since, verified: verified, at: time)
        return true
    }

    /// Applies the auto-end limits as they're reached. Called every minute while LockedIn runs,
    /// so a forgotten session stops (along with background tracking) instead of running all night.
    func tick(at now: Date = .now) {
        guard let s = session, s.pendingCheck == nil else { return }
        let cfg = config()
        if keepAlive.isRunning { keepAlive.ensurePlaying() }
        switch s.state {
        case .locked(let since, let verified):
            if let limit = cfg.autoEndAfter, now.timeIntervalSince(since) > limit {
                endAtLockLimit(since: since, verified: verified, limit: limit)
            }
        case .armed, .paused:
            if let idle = s.idleSince, now.timeIntervalSince(idle) > cfg.idleAutoEnd {
                log("Unlocked for over \(DurationText.short(cfg.idleAutoEnd)); ending the session")
                finish(reason: .idle, at: idle)
            }
        case .onBreak(let since):
            endIfBreakTooLong(since: since, now: now)
        }
    }

    // MARK: Transitions

    private func handleUnlock(lockedSince since: Date, verified: Bool, at now: Date) {
        guard var s = session else { return }
        let cfg = config()

        if let boot = bootTime(), boot > since.addingTimeInterval(30) {
            // The phone restarted during this stretch, so there's no way to know how long it was.
            log("Phone restarted while locked; dropping the unverifiable stretch")
            s.state = .paused(.unlocked)
            session = s
            finish(reason: .deviceRestarted, at: since)
            return
        }

        if let limit = cfg.autoEndAfter, now.timeIntervalSince(since) > limit {
            endAtLockLimit(since: since, verified: verified, limit: limit)
            return
        }

        let credit = now.timeIntervalSince(since)
        s.stretches.append(LockStretch(start: since, end: now, verified: verified))
        s.unlockCount += 1
        s.state = .paused(.unlocked)
        s.idleSince = now
        session = s
        persist()
        lastCredit = StretchCredit(seconds: credit, at: now)
        log("Unlocked; credited \(DurationText.clock(credit))" + (verified ? "" : " (lock inferred from timing)"))

        notifier.cancelWhileLocked()
        if let nudge = cfg.breakNudgeAfter {
            notifier.scheduleBreakNudge(at: now.addingTimeInterval(nudge), lockAnywhere: tracksLocksAnywhere)
        }
        pushLiveActivity(s)
    }

    /// Ends a session that's been paused past `breakAutoEnd`, as of when the pause began.
    @discardableResult
    private func endIfBreakTooLong(since: Date, now: Date) -> Bool {
        let limit = config().breakAutoEnd
        guard now.timeIntervalSince(since) > limit else { return false }
        log("Paused for over \(DurationText.short(limit)); ending the session")
        finish(reason: .longBreak, at: since)
        return true
    }

    /// Records a finished break. Only time after the first lock is kept, since only that affects focus.
    private func closeBreak(_ s: inout ActiveSession, since: Date, at end: Date) {
        s.breakCount += 1
        if let first = s.firstLockAt {
            s.breakSeconds += max(0, end.timeIntervalSince(max(since, first)))
        }
        s.breakReminderAt = nil
        s.breakReminderMinutes = nil
    }

    /// The phone stayed locked past the auto-end limit: count up to the limit, then end.
    private func endAtLockLimit(since: Date, verified: Bool, limit: TimeInterval) {
        guard var s = session else { return }
        let stop = since.addingTimeInterval(limit)
        log("Locked longer than the \(DurationText.short(limit)) limit; ending at the limit")
        s.stretches.append(LockStretch(start: since, end: stop, verified: verified))
        s.state = .paused(.unlocked)
        session = s
        finish(reason: .lockLimit, at: stop)
    }

    private func finish(reason: EndReason, at end: Date) {
        guard var s = session else { return }
        if case .locked(let since, let verified) = s.state, end > since {
            s.stretches.append(LockStretch(start: since, end: end, verified: verified))
        }
        if let since = s.breakSince {
            closeBreak(&s, since: since, at: end)
        }
        let finished = FinishedSession(
            id: s.id,
            startedAt: s.startedAt,
            endedAt: end,
            subjectID: s.subjectID,
            targetSeconds: s.targetSeconds,
            stretches: s.stretches,
            unlockCount: s.unlockCount,
            leftAppCount: s.leftAppCount,
            reason: reason,
            breakCount: s.breakCount,
            breakSeconds: s.breakSeconds
        )
        let keep = finished.lockedSeconds >= config().minimumSessionLength
        let savedID = keep ? archive.archive(finished) : nil

        notifier.cancelSessionNotifications()
        // Automatic endings stay on the Lock Screen for a while, so you see what happened.
        let automatic = reason == .lockLimit || reason == .deviceRestarted
        liveActivity.end(
            .init(phase: .ended, banked: finished.lockedSeconds, lockedSince: nil, stopsAt: nil, unlockCount: finished.unlockCount),
            immediately: !automatic
        )
        let finishedSubject = subject
        session = nil
        subject = nil
        persist()
        keepAlive.stop()
        log("Session ended (\(reason.rawValue)): \(DurationText.clock(finished.lockedSeconds)) locked in" + (keep ? "" : ", too short to save"))

        // An untouched session that timed out isn't worth a summary.
        if (reason == .idle || reason == .longBreak) && !keep { return }
        summary = SessionSummary(id: finished.id, session: finished, savedSessionID: savedID, subject: finishedSubject)
    }

    // MARK: Helpers

    private func persist() {
        store.save(session)
    }

    /// Shows `s` on the Lock Screen and Dynamic Island (`lockedSince` previews a lock not yet confirmed).
    private func pushLiveActivity(_ s: ActiveSession, lockedSince override: Date? = nil) {
        let since = override ?? s.lockedSince
        liveActivity.show(
            attributes(for: s),
            state: activityState(s, lockedSince: override),
            staleDate: since.flatMap(stopDate(lockedSince:))
        )
    }

    private func attributes(for s: ActiveSession) -> LockInActivityAttributes {
        LockInActivityAttributes(
            sessionID: s.id,
            subjectName: subject?.name,
            subjectEmoji: subject?.emoji,
            subjectColorHex: subject?.colorHex,
            targetSeconds: s.targetSeconds
        )
    }

    private func activityState(_ s: ActiveSession, lockedSince override: Date? = nil) -> LockInActivityAttributes.ContentState {
        if let since = override ?? s.lockedSince {
            return .init(
                phase: .locked,
                banked: s.bankedSeconds,
                lockedSince: since,
                stopsAt: stopDate(lockedSince: since),
                unlockCount: s.unlockCount,
                tracksAnyApp: tracksLocksAnywhere
            )
        }
        if let breakSince = s.breakSince {
            return .init(
                phase: .onBreak,
                banked: s.bankedSeconds,
                lockedSince: nil,
                stopsAt: nil,
                unlockCount: s.unlockCount,
                tracksAnyApp: false,
                breakSince: breakSince
            )
        }
        return .init(
            phase: s.isArmed ? .armed : .paused,
            banked: s.bankedSeconds,
            lockedSince: nil,
            stopsAt: nil,
            unlockCount: s.unlockCount,
            tracksAnyApp: tracksLocksAnywhere
        )
    }

    private func stopDate(lockedSince since: Date) -> Date? {
        config().autoEndAfter.map { since.addingTimeInterval($0) }
    }

    func notificationPlan(for s: ActiveSession, lockedSince since: Date) -> LockedNotificationPlan {
        let cfg = config()
        var plan = LockedNotificationPlan(dailyGoalSeconds: cfg.dailyGoal)

        let banked = s.bankedSeconds
        if let target = s.targetSeconds, target > banked {
            plan.targetAt = since.addingTimeInterval(target - banked)
            plan.targetSeconds = target
        }

        let day = dayInterval(since)
        let doneToday = archive.savedLockedSeconds(in: day) + s.lockedSeconds(in: day, now: since)
        if cfg.dailyGoal > 0, doneToday < cfg.dailyGoal {
            let at = since.addingTimeInterval(cfg.dailyGoal - doneToday)
            if at < day.end { plan.dailyGoalAt = at }
        }

        if let limit = cfg.autoEndAfter {
            plan.autoEndAt = since.addingTimeInterval(limit)
            plan.autoEndSeconds = limit
        }
        return plan
    }
}
