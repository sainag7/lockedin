import Foundation
import Testing
@testable import LockedIn

// MARK: - Fakes

final class FakeStore: ActiveSessionStoring {
    var saved: ActiveSession?
    func load() -> ActiveSession? { saved }
    func save(_ session: ActiveSession?) { saved = session }
}

final class FakeLiveActivity: LiveActivityControlling {
    var isRunning = false
    var states: [LockInActivityAttributes.ContentState] = []
    var endedWith: LockInActivityAttributes.ContentState?
    var endedImmediately: Bool?

    func show(_ attributes: LockInActivityAttributes, state: LockInActivityAttributes.ContentState, staleDate: Date?) {
        isRunning = true
        states.append(state)
    }

    func end(_ finalState: LockInActivityAttributes.ContentState?, immediately: Bool) {
        isRunning = false
        endedWith = finalState
        endedImmediately = immediately
    }

    func cleanUp(keeping sessionID: UUID?) {}
}

final class FakeNotifier: SessionNotifying {
    var lockedPlans: [LockedNotificationPlan] = []
    var nudges: [Date] = []
    var leftAppAlerts: [Bool] = []
    var breakReminder: Date?

    func scheduleWhileLocked(_ plan: LockedNotificationPlan) { lockedPlans.append(plan) }
    func cancelWhileLocked() {}
    func scheduleBreakNudge(at date: Date, lockAnywhere: Bool) { nudges.append(date) }
    func cancelBreakNudge() {}
    func notifyLeftApp(sessionStarted: Bool) { leftAppAlerts.append(sessionStarted) }
    func clearLeftAppAlerts() {}
    func scheduleBreakReminder(at date: Date) { breakReminder = date }
    func cancelBreakReminder() { breakReminder = nil }
    func cancelSessionNotifications() { breakReminder = nil }
}

final class FakeArchive: SessionArchiving {
    var archived: [FinishedSession] = []
    var savedToday: TimeInterval = 0

    func archive(_ session: FinishedSession) -> UUID {
        archived.append(session)
        return session.id
    }

    func savedLockedSeconds(in interval: DateInterval) -> TimeInterval { savedToday }
    func subjectInfo(for id: UUID?) -> SubjectInfo? { nil }
}

final class FakeKeepAlive: BackgroundKeepingAlive {
    var isRunning = false
    var restarts = 0
    func start() { isRunning = true }
    func stop() { isRunning = false }
    func ensurePlaying() { restarts += 1 }
}

/// Builds engines over shared fakes, so a second engine can simulate a relaunch.
final class Harness {
    let store = FakeStore()
    let live = FakeLiveActivity()
    let notifier = FakeNotifier()
    let archive = FakeArchive()
    let keepAlive = FakeKeepAlive()
    var config = EngineConfig()
    var bootTime: Date?

    func makeEngine() -> SessionEngine {
        SessionEngine(
            store: store,
            liveActivity: live,
            notifier: notifier,
            archive: archive,
            keepAlive: keepAlive,
            config: { [unowned self] in self.config },
            dayInterval: { utc.dateInterval(of: .day, for: $0)! },
            bootTime: { [unowned self] in self.bootTime }
        )
    }
}

let utc: Calendar = {
    var calendar = Calendar(identifier: .gregorian)
    calendar.timeZone = TimeZone(identifier: "UTC")!
    calendar.firstWeekday = 1
    return calendar
}()

/// Noon UTC on a Tuesday.
let t0 = utc.date(from: DateComponents(year: 2026, month: 3, day: 10, hour: 12))!

let minute: TimeInterval = 60
let hour: TimeInterval = 3600

// MARK: - Tests

struct SessionEngineTests {
    /// Locks at `lockAt` (confirmed by iOS's lock signal) and unlocks at `unlockAt`.
    private func lockStretch(_ engine: SessionEngine, from lockAt: Date, to unlockAt: Date) {
        engine.appDidEnterBackground(at: lockAt, lockLikeTransition: true)
        engine.lockConfirmed(verified: true, lockedAt: lockAt)
        engine.appDidBecomeActive(at: unlockAt)
    }

    @Test func lockThenUnlockCreditsTheLockedStretch() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        engine.appDidEnterBackground(at: t0 + 5, lockLikeTransition: true)
        #expect(harness.live.states.last?.phase == .locked, "A lock starts the Lock Screen timer right away")
        engine.lockConfirmed(verified: true, lockedAt: t0 + 5)
        #expect(engine.session?.lockedSince == t0 + 5)

        engine.appDidBecomeActive(at: t0 + 605)
        #expect(engine.session?.bankedSeconds == 600)
        #expect(engine.session?.unlockCount == 1)
        #expect(engine.session?.state == .paused(.unlocked))
        #expect(engine.lastCredit?.seconds == 600)
        #expect(harness.notifier.nudges == [t0 + 605 + 5 * minute])
        #expect(harness.live.states.last?.phase == .paused)
    }

    @Test func lockingAgainResumesAndAddsUp() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        lockStretch(engine, from: t0, to: t0 + 10 * minute)
        lockStretch(engine, from: t0 + 12 * minute, to: t0 + 40 * minute)

        #expect(engine.session?.bankedSeconds == 38 * minute)
        #expect(engine.session?.unlockCount == 2)
        #expect(engine.session?.longestStretch(at: t0 + 40 * minute) == 28 * minute)
        #expect(engine.session?.focus(at: t0 + 40 * minute) == 38.0 / 40.0)
    }

    @Test func leavingTheAppStopsTheTimerRightAway() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 5 * minute)
        let updatesBefore = harness.live.states.count

        engine.appDidEnterBackground(at: t0 + 6 * minute, lockLikeTransition: false)
        #expect(harness.live.states.count == updatesBefore, "Going Home must not start the Lock Screen timer")
        #expect(harness.live.states.last?.phase == .paused)

        let verdict = engine.lockCheckExpired()
        #expect(verdict == .leftApp)
        #expect(engine.session?.state == .paused(.leftApp))
        #expect(harness.notifier.leftAppAlerts == [true])
        #expect(harness.live.states.last?.phase == .paused)

        engine.appDidBecomeActive(at: t0 + 30 * minute)
        #expect(engine.session?.bankedSeconds == 5 * minute)
        #expect(engine.session?.leftAppCount == 1)
    }

    @Test func leavingBeforeTheFirstLockKeepsWaiting() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        engine.appDidEnterBackground(at: t0 + 2, lockLikeTransition: false)
        #expect(engine.lockCheckExpired() == .leftApp)
        #expect(engine.session?.state == .armed)
        #expect(harness.notifier.leftAppAlerts == [false])
    }

    @Test func lockLikeTransitionCountsWithoutTheProtectedDataSignal() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        engine.appDidEnterBackground(at: t0 + 2, lockLikeTransition: true)
        #expect(engine.lockCheckExpired() == .locked(verified: false))
        engine.appDidBecomeActive(at: t0 + 602)

        #expect(engine.session?.bankedSeconds == 600)
        #expect(engine.session?.stretches.first?.verified == false)
    }

    @Test func lockAfterGoingHomeCountsFromWhenItLocked() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        // Went Home, then locked 15 s after leaving the app.
        engine.appDidEnterBackground(at: t0, lockLikeTransition: false)
        #expect(engine.lockConfirmed(verified: true, lockedAt: t0 + 15) == t0 + 15)
        engine.appDidBecomeActive(at: t0 + 615)

        #expect(engine.session?.bankedSeconds == 600)
    }

    @Test func misjudgedLockStillCountsFromBackgrounding() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        // A slow lock transition. The data went away 8 s later, which puts the lock ~2 s before
        // the app left the screen.
        engine.appDidEnterBackground(at: t0, lockLikeTransition: false)
        #expect(engine.lockConfirmed(verified: true, lockedAt: t0 - 2) == t0)
        #expect(harness.live.states.last?.phase == .locked)
    }

    @Test func quickUnlockAfterALockLikeExitStillCounts() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        // Unlocked 7 s after locking, before the protected-data signal could arrive.
        engine.appDidEnterBackground(at: t0 + 2, lockLikeTransition: true)
        engine.appDidBecomeActive(at: t0 + 9)

        #expect(engine.session?.bankedSeconds == 7)
        #expect(engine.session?.pendingCheck == nil)
        #expect(engine.session?.state == .paused(.unlocked))
        #expect(engine.session?.unlockCount == 1)
        #expect(engine.session?.stretches.first?.verified == false)
        #expect(harness.live.states.last?.phase == .paused)
    }

    @Test func returningFromAnotherAppCreditsNothing() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        engine.appDidEnterBackground(at: t0 + 2, lockLikeTransition: false)
        engine.appDidBecomeActive(at: t0 + 20)

        #expect(engine.session?.bankedSeconds == 0)
        #expect(engine.session?.pendingCheck == nil)
        #expect(engine.session?.state == .armed)
        #expect(engine.session?.unlockCount == 0)
        #expect(harness.live.states.last?.phase == .armed)
    }

    @Test func autoEndLimitClampsTheStretchAndEndsTheSession() {
        let harness = Harness()
        harness.config.autoEndAfter = 3 * hour
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        lockStretch(engine, from: t0, to: t0 + 9 * hour)

        #expect(engine.session == nil)
        #expect(harness.archive.archived.count == 1)
        #expect(harness.archive.archived.first?.lockedSeconds == 3 * hour)
        #expect(harness.archive.archived.first?.reason == .lockLimit)
        #expect(harness.archive.archived.first?.endedAt == t0 + 3 * hour)
        #expect(engine.summary?.session.reason == .lockLimit)
    }

    @Test func relaunchWhileLockedCreditsTheStretchOnUnlock() {
        let harness = Harness()
        let first = harness.makeEngine()
        first.start(subjectID: nil, targetSeconds: nil, at: t0)
        first.appDidEnterBackground(at: t0 + 1, lockLikeTransition: true)
        first.lockConfirmed(verified: true, lockedAt: t0 + 1)

        // iOS kills the app while the phone is locked; the unlock relaunches it.
        let relaunched = harness.makeEngine()
        relaunched.restoreAfterLaunch()
        relaunched.appDidBecomeActive(at: t0 + 1201)

        #expect(relaunched.session?.bankedSeconds == 1200)
        #expect(relaunched.session?.unlockCount == 1)
        #expect(harness.live.states.last?.phase == .paused, "The widget is told the timer stopped")
    }

    @Test func openingTheAppAlwaysResyncsTheWidget() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 5 * minute)
        let pushes = harness.live.states.count
        let restarts = harness.keepAlive.restarts

        engine.appDidBecomeActive(at: t0 + 6 * minute)
        #expect(harness.live.states.count == pushes + 1)
        #expect(harness.live.states.last?.phase == .paused)
        #expect(harness.keepAlive.restarts == restarts + 1, "Opening the app restarts background audio if it stopped")
    }

    @Test func killedMidCheckAfterALockLikeExitCreditsOnUnlock() {
        let harness = Harness()
        let first = harness.makeEngine()
        first.start(subjectID: nil, targetSeconds: nil, at: t0)
        first.appDidEnterBackground(at: t0 + 1, lockLikeTransition: true)

        let relaunched = harness.makeEngine()
        relaunched.restoreAfterLaunch()
        relaunched.appDidBecomeActive(at: t0 + 601)

        #expect(relaunched.session?.bankedSeconds == 600)
        #expect(relaunched.session?.unlockCount == 1)
    }

    @Test func killedMidCheckForgetsTheCheck() {
        let harness = Harness()
        let first = harness.makeEngine()
        first.start(subjectID: nil, targetSeconds: nil, at: t0)
        first.appDidEnterBackground(at: t0 + 1, lockLikeTransition: false)

        let relaunched = harness.makeEngine()
        relaunched.restoreAfterLaunch()
        relaunched.appDidBecomeActive(at: t0 + 600)

        #expect(relaunched.session?.pendingCheck == nil)
        #expect(relaunched.session?.bankedSeconds == 0)
    }

    @Test func restartDuringALockDropsThatStretch() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)

        engine.appDidEnterBackground(at: t0 + 12 * minute, lockLikeTransition: true)
        engine.lockConfirmed(verified: true, lockedAt: t0 + 12 * minute)
        harness.bootTime = t0 + 2 * hour
        engine.appDidBecomeActive(at: t0 + 5 * hour)

        #expect(engine.session == nil)
        #expect(harness.archive.archived.first?.lockedSeconds == 10 * minute)
        #expect(harness.archive.archived.first?.reason == .deviceRestarted)
    }

    @Test func notificationTimesAccountForBankedAndSavedTime() {
        let harness = Harness()
        harness.config.dailyGoal = 2 * hour
        harness.archive.savedToday = 80 * minute
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: 50 * minute, at: t0)
        lockStretch(engine, from: t0, to: t0 + 20 * minute)

        let since = t0 + 30 * minute
        engine.appDidEnterBackground(at: since, lockLikeTransition: true)
        engine.lockConfirmed(verified: true, lockedAt: since)
        let plan = harness.notifier.lockedPlans.last

        // 20 of 50 target minutes banked → 30 to go.
        #expect(plan?.targetAt == since + 30 * minute)
        // 80 saved + 20 banked = 100 of 120 daily minutes → 20 to go.
        #expect(plan?.dailyGoalAt == since + 20 * minute)
        #expect(plan?.autoEndAt == since + 3 * hour)
    }

    @Test func targetAlreadyHitSchedulesNoTargetAlert() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: 10 * minute, at: t0)
        lockStretch(engine, from: t0, to: t0 + 15 * minute)

        engine.appDidEnterBackground(at: t0 + 16 * minute, lockLikeTransition: true)
        engine.lockConfirmed(verified: true, lockedAt: t0 + 16 * minute)
        #expect(harness.notifier.lockedPlans.last?.targetAt == nil)
    }

    @Test func manualEndSavesTheSession() {
        let harness = Harness()
        let engine = harness.makeEngine()
        let subject = UUID()
        engine.start(subjectID: subject, targetSeconds: 25 * minute, at: t0)
        lockStretch(engine, from: t0 + 10, to: t0 + 30 * minute)
        engine.end(at: t0 + 31 * minute)

        let saved = harness.archive.archived.first
        #expect(engine.session == nil)
        #expect(harness.store.saved == nil)
        #expect(saved?.subjectID == subject)
        #expect(saved?.lockedSeconds == 30 * minute - 10)
        #expect(saved?.reason == .manual)
        #expect(engine.summary?.savedSessionID == saved?.id)
        #expect(harness.live.endedWith?.phase == .ended)
    }

    @Test func sessionsUnderAMinuteAreNotSaved() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 30)
        engine.end(at: t0 + 40)

        #expect(harness.archive.archived.isEmpty)
        #expect(engine.summary != nil)
        #expect(engine.summary?.savedSessionID == nil)
    }

    @Test func longPauseEndsTheSessionWhereItPaused() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)

        engine.appDidBecomeActive(at: t0 + 10 * minute + 61 * minute)

        #expect(engine.session == nil)
        #expect(harness.archive.archived.first?.endedAt == t0 + 10 * minute)
        #expect(harness.archive.archived.first?.reason == .idle)
    }

    @Test func untouchedSessionTimesOutQuietly() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        engine.appDidBecomeActive(at: t0 + 2 * hour)

        #expect(engine.session == nil)
        #expect(harness.archive.archived.isEmpty)
        #expect(engine.summary == nil)
    }

    @Test func cancelDiscardsWithoutSaving() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        engine.cancel()

        #expect(engine.session == nil)
        #expect(harness.store.saved == nil)
        #expect(harness.archive.archived.isEmpty)
        #expect(!harness.keepAlive.isRunning)
    }

    // MARK: Tracking locks in any app

    @Test func backgroundTrackingRunsOnlyDuringASession() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        #expect(harness.keepAlive.isRunning)
        #expect(engine.tracksLocksAnywhere)
        #expect(harness.live.states.last?.tracksAnyApp == true)

        engine.end(at: t0 + 10)
        #expect(!harness.keepAlive.isRunning)
        #expect(!engine.tracksLocksAnywhere)
        #expect(harness.live.endedImmediately == true)
    }

    @Test func backgroundTrackingFollowsTheSettingAndPasscode() {
        let harness = Harness()
        harness.config.trackLocksAnywhere = false
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        #expect(!harness.keepAlive.isRunning)

        harness.config.trackLocksAnywhere = true
        engine.syncKeepAlive()
        #expect(harness.keepAlive.isRunning)

        engine.deviceHasPasscode = false
        engine.syncKeepAlive()
        #expect(!harness.keepAlive.isRunning)
    }

    @Test func unlockingIntoAnyAppStopsTheTimerRightAway() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        engine.appDidEnterBackground(at: t0, lockLikeTransition: true)
        engine.lockConfirmed(verified: true, lockedAt: t0)

        #expect(engine.deviceUnlocked(at: t0 + 600))
        #expect(engine.session?.bankedSeconds == 600)
        #expect(engine.session?.state == .paused(.unlocked))
        #expect(engine.session?.unlockCount == 1)
        #expect(harness.live.states.last?.phase == .paused)

        // Opening LockedIn afterwards changes nothing.
        engine.appDidBecomeActive(at: t0 + 700)
        #expect(engine.session?.bankedSeconds == 600)
        #expect(engine.session?.unlockCount == 1)
    }

    @Test func withTrackingALockThatIOSNeverReportsCountsNothing() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 5 * minute)

        // Locked from LockedIn, then unlocked straight into another app before iOS reported the lock.
        engine.appDidEnterBackground(at: t0 + 6 * minute, lockLikeTransition: true)
        #expect(engine.lockCheckExpired(lockSignalExpected: true) == .unlockedQuickly)
        #expect(engine.session?.state == .paused(.unlocked))
        #expect(engine.session?.bankedSeconds == 5 * minute)
        #expect(harness.live.states.last?.phase == .paused)
        #expect(harness.notifier.leftAppAlerts.isEmpty)
    }

    @Test func lockingFromAnotherAppResumesTheTimer() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)

        // Used other apps, then locked at +15m; iOS reports the lock as it happens.
        let locked = t0 + 15 * minute
        #expect(engine.deviceLocked(estimatedAt: locked, now: locked))
        #expect(engine.session?.lockedSince == t0 + 15 * minute)
        #expect(harness.live.states.last?.phase == .locked)

        engine.deviceUnlocked(at: t0 + 25 * minute)
        #expect(engine.session?.bankedSeconds == 20 * minute)
        #expect(engine.session?.unlockCount == 2)
    }

    @Test func lockEstimateNeverStartsBeforeTheUnlock() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)

        // An estimate from before the last unlock never counts time the phone was unlocked.
        engine.deviceLocked(estimatedAt: t0 + 10 * minute - 5, now: t0 + 10 * minute + 5)
        #expect(engine.session?.lockedSince == t0 + 10 * minute)
    }

    @Test func aShortLockFromAnotherAppCreditsJustThoseSeconds() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)

        // Locked from another app for 4 s.
        engine.deviceLocked(estimatedAt: t0 + 12 * minute, now: t0 + 12 * minute)
        engine.deviceUnlocked(at: t0 + 12 * minute + 4)
        #expect(engine.lastCredit?.seconds == 4)
        #expect(engine.session?.bankedSeconds == 10 * minute + 4)
    }

    @Test func unlockingRightAfterALockInsideTheAppStopsTheWidgetAtOnce() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        // Locked from LockedIn, then unlocked 7 s later: the detector confirms the lock as of
        // leaving the screen, then reports the unlock.
        engine.appDidEnterBackground(at: t0 + 2, lockLikeTransition: true)
        engine.lockConfirmed(verified: true, lockedAt: t0 + 2)
        #expect(engine.deviceUnlocked(at: t0 + 9))

        #expect(engine.session?.bankedSeconds == 7)
        #expect(engine.session?.state == .paused(.unlocked))
        #expect(engine.session?.stretches.first?.verified == true)
        #expect(harness.live.states.last?.phase == .paused)
    }

    @Test func lockingAfterALongBreakEndsTheSessionInstead() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 30 * minute)

        let later = t0 + 3 * hour
        #expect(!engine.deviceLocked(estimatedAt: later, now: later))
        #expect(engine.session == nil)
        #expect(harness.archive.archived.first?.endedAt == t0 + 30 * minute)
        #expect(harness.archive.archived.first?.reason == .idle)
        #expect(!harness.keepAlive.isRunning)
    }

    @Test func tickEndsAForgottenLockAtTheLimit() {
        let harness = Harness()
        harness.config.autoEndAfter = 3 * hour
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        engine.appDidEnterBackground(at: t0, lockLikeTransition: true)
        engine.lockConfirmed(verified: true, lockedAt: t0)

        engine.tick(at: t0 + 2 * hour)
        #expect(engine.session != nil)

        engine.tick(at: t0 + 3 * hour + 30)
        #expect(engine.session == nil)
        #expect(harness.archive.archived.first?.lockedSeconds == 3 * hour)
        #expect(harness.archive.archived.first?.reason == .lockLimit)
        #expect(harness.live.endedImmediately == false, "An automatic ending stays on the Lock Screen")
        #expect(!harness.keepAlive.isRunning)
    }

    // MARK: Pause

    @Test func pausedSessionsIgnoreLocks() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)

        engine.pause(at: t0 + 11 * minute)
        #expect(engine.session?.isOnBreak == true)
        #expect(!engine.needsLockCheck)
        #expect(!engine.canPause)
        #expect(!harness.keepAlive.isRunning, "Background tracking stops while paused")
        #expect(harness.live.states.last?.phase == .onBreak)
        #expect(harness.live.states.last?.breakSince == t0 + 11 * minute)

        // Locking from any app, or from LockedIn, doesn't count.
        #expect(!engine.deviceLocked(estimatedAt: t0 + 15 * minute, now: t0 + 15 * minute))
        engine.appDidEnterBackground(at: t0 + 16 * minute, lockLikeTransition: true)
        #expect(engine.session?.pendingCheck == nil)
        engine.appDidBecomeActive(at: t0 + 30 * minute)
        #expect(engine.session?.isOnBreak == true)
        #expect(engine.session?.bankedSeconds == 10 * minute)
        #expect(engine.session?.unlockCount == 1)
    }

    @Test func resumeCountsLocksAgainAndLeavesBreaksOutOfFocus() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)

        engine.pause(at: t0 + 10 * minute)
        engine.resume(at: t0 + 30 * minute)
        #expect(engine.session?.state == .paused(.unlocked))
        #expect(harness.keepAlive.isRunning, "Background tracking restarts on Resume")
        #expect(engine.session?.breakCount == 1)
        #expect(engine.session?.breakSeconds == 20 * minute)
        #expect(harness.notifier.nudges.last == t0 + 35 * minute)

        lockStretch(engine, from: t0 + 30 * minute, to: t0 + 40 * minute)
        #expect(engine.session?.bankedSeconds == 20 * minute)
        // 20 locked minutes out of 40, minus the 20-minute break.
        #expect(engine.session?.focus(at: t0 + 40 * minute) == 1)

        engine.end(at: t0 + 40 * minute)
        let saved = harness.archive.archived.first
        #expect(saved?.breakCount == 1)
        #expect(saved?.breakSeconds == 20 * minute)
        #expect(saved?.focus == 1)
    }

    @Test func pausingBeforeTheFirstLockGoesBackToReady() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)

        engine.pause(at: t0 + minute)
        engine.resume(at: t0 + 5 * minute)
        #expect(engine.session?.state == .armed)
        #expect(engine.session?.breakCount == 1)
        #expect(engine.session?.breakSeconds == 0, "A break before the first lock doesn't affect focus")
        #expect(harness.notifier.nudges.isEmpty)
    }

    @Test func breakReminderCanBeSetChangedAndClearedOnResume() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)
        engine.pause(at: t0 + 10 * minute)

        engine.setBreakReminder(minutes: 10, at: t0 + 11 * minute)
        #expect(harness.notifier.breakReminder == t0 + 21 * minute)
        #expect(engine.session?.breakReminderMinutes == 10)

        engine.setBreakReminder(minutes: 5, at: t0 + 12 * minute)
        #expect(harness.notifier.breakReminder == t0 + 17 * minute)

        engine.setBreakReminder(minutes: nil, at: t0 + 13 * minute)
        #expect(harness.notifier.breakReminder == nil)
        #expect(engine.session?.breakReminderAt == nil)

        engine.setBreakReminder(minutes: 30, at: t0 + 14 * minute)
        engine.resume(at: t0 + 20 * minute)
        #expect(harness.notifier.breakReminder == nil)
        #expect(engine.session?.breakReminderMinutes == nil)
    }

    @Test func aPauseOverFourHoursEndsTheSessionWhenItBegan() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 30 * minute)
        engine.pause(at: t0 + 31 * minute)

        engine.tick(at: t0 + 31 * minute + 3 * hour)
        #expect(engine.session != nil, "An hour-plus pause doesn't hit the one-hour unlocked limit")

        engine.appDidBecomeActive(at: t0 + 31 * minute + 4 * hour + 1)
        #expect(engine.session == nil)
        #expect(harness.archive.archived.first?.reason == .longBreak)
        #expect(harness.archive.archived.first?.endedAt == t0 + 31 * minute)
        #expect(harness.archive.archived.first?.lockedSeconds == 30 * minute)
    }

    @Test func endingWhilePausedRecordsTheBreak() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)
        engine.pause(at: t0 + 10 * minute)
        engine.setBreakReminder(minutes: 15, at: t0 + 10 * minute)

        engine.end(at: t0 + 25 * minute)
        let saved = harness.archive.archived.first
        #expect(saved?.lockedSeconds == 10 * minute)
        #expect(saved?.breakCount == 1)
        #expect(saved?.breakSeconds == 15 * minute)
        #expect(harness.notifier.breakReminder == nil)
    }

    @Test func cantPauseWhileLockedOrMidCheck() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        #expect(engine.canPause)

        engine.appDidEnterBackground(at: t0, lockLikeTransition: true)
        #expect(!engine.canPause)
        engine.lockConfirmed(verified: true, lockedAt: t0)
        engine.pause(at: t0 + 20)
        #expect(engine.session?.isOnBreak == false)
        #expect(engine.session?.isLocked == true)
    }

    @Test func sessionsSavedBeforePausingExistedStillLoad() throws {
        // What the previous build saved: no break fields at all.
        let json = #"{"id":"6B1D1C3E-2E7B-4C39-9E0B-1A4F7A0B5C11","startedAt":0,"state":{"armed":{}},"stretches":[],"unlockCount":0,"leftAppCount":0}"#
        let session = try JSONDecoder().decode(ActiveSession.self, from: Data(json.utf8))
        #expect(session.breakCount == 0)
        #expect(session.breakSeconds == 0)
        #expect(!session.isOnBreak)
        #expect(session.state == .armed)
    }

    @Test func tickEndsALongPause() {
        let harness = Harness()
        let engine = harness.makeEngine()
        engine.start(subjectID: nil, targetSeconds: nil, at: t0)
        lockStretch(engine, from: t0, to: t0 + 10 * minute)

        engine.tick(at: t0 + 10 * minute + 61 * minute)
        #expect(engine.session == nil)
        #expect(harness.archive.archived.first?.reason == .idle)
    }
}
