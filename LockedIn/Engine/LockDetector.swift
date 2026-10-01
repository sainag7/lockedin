import LocalAuthentication
import UIKit

nonisolated enum DetectionMode: String, CaseIterable, Codable, Sendable {
    /// Real lock detection. Needs a real iPhone with a passcode.
    case automatic
    /// Treat every trip to the background as a lock (the simulator has no data protection).
    case assumeLock

    static var platformDefault: DetectionMode {
        #if targetEnvironment(simulator)
        .assumeLock
        #else
        .automatic
        #endif
    }

    var title: String {
        switch self {
        case .automatic: "Automatic"
        case .assumeLock: "Always assume locked"
        }
    }
}

/// Turns app lifecycle and data-protection events into lock evidence for `SessionEngine`.
///
/// iOS has no public "screen locked" API, but on a phone with a passcode it posts "protected data
/// will become unavailable" the moment the phone locks (the data itself goes about 10 seconds
/// later) and "did become available" the moment it unlocks. LockedIn only hears these while it's
/// running, so it also judges by timing: a lock backgrounds the app almost instantly, while going
/// Home or switching apps animates first. A lock-like transition starts the timer at once; anything
/// slower keeps it stopped.
///
/// When the lock notice arrives just before LockedIn leaves the screen, that settles it. Otherwise
/// LockedIn keeps running for a while (a background task of about 25 seconds, or longer with
/// background tracking) and watches for the notice or for the data going away, which also catches
/// a lock the timing misjudged.
final class LockDetector: NSObject {
    /// Resign-active → background faster than this looks like a lock rather than an app switch.
    static let lockLikeGap: TimeInterval = 0.15
    /// A lock notice this recent when LockedIn leaves the screen means the phone locked it away.
    /// It normally arrives a few milliseconds before the app starts leaving.
    static let lockSignalWindow: TimeInterval = 2
    /// Longest we wait in the background for the lock signal (a background task lasts ~30 s).
    static let maxCheckWindow: TimeInterval = 25
    /// With background tracking there's no time limit, so wait past iOS's slowest lock report (~40 s).
    static let trackingCheckWindow: TimeInterval = 60

    private let engine: SessionEngine
    private let log: DiagnosticsLog
    private let mode: () -> DetectionMode

    private var resignedActiveAt: Date?
    private var backgroundedAt: Date?
    /// When iOS last said the phone was locking; cleared when it unlocks.
    private var lockSignalAt: Date?
    private var backgroundTask: UIBackgroundTaskIdentifier = .invalid
    private var checkTask: Task<Void, Never>?
    private var tickTask: Task<Void, Never>?
    private var lastHeartbeat = Date.distantPast

    init(engine: SessionEngine, log: DiagnosticsLog, mode: @escaping () -> DetectionMode) {
        self.engine = engine
        self.log = log
        self.mode = mode
        super.init()
    }

    func start() {
        let center = NotificationCenter.default
        center.addObserver(self, selector: #selector(willResignActive), name: UIApplication.willResignActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(didEnterBackground), name: UIApplication.didEnterBackgroundNotification, object: nil)
        center.addObserver(self, selector: #selector(willEnterForeground), name: UIApplication.willEnterForegroundNotification, object: nil)
        center.addObserver(self, selector: #selector(didBecomeActive), name: UIApplication.didBecomeActiveNotification, object: nil)
        center.addObserver(self, selector: #selector(protectedDataWillBecomeUnavailable), name: UIApplication.protectedDataWillBecomeUnavailableNotification, object: nil)
        center.addObserver(self, selector: #selector(protectedDataDidBecomeAvailable), name: UIApplication.protectedDataDidBecomeAvailableNotification, object: nil)
        refreshPasscodeState()

        // Apply auto-end limits as they're reached, including in the background while tracking.
        tickTask = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(60))
                self?.onTick()
            }
        }
    }

    private func onTick() {
        engine.tick()
        // A heartbeat in the log shows how long LockedIn really keeps running in the background.
        guard engine.tracksLocksAnywhere,
              UIApplication.shared.applicationState == .background,
              Date.now.timeIntervalSince(lastHeartbeat) >= 120
        else { return }
        lastHeartbeat = .now
        log.add(.lifecycle, "Still running in the background (\(engine.session?.isLocked == true ? "locked" : "unlocked"))")
    }

    private var isChecking: Bool { checkTask != nil }

    private func refreshPasscodeState() {
        engine.deviceHasPasscode = LAContext().canEvaluatePolicy(.deviceOwnerAuthentication, error: nil)
    }

    // MARK: Lifecycle

    @objc private func willResignActive() {
        resignedActiveAt = .now
        log.add(.lifecycle, "Will resign active")
    }

    @objc private func didEnterBackground() {
        let now = Date.now
        backgroundedAt = now
        let gap = resignedActiveAt.map { now.timeIntervalSince($0) }
        // Measure each exit from its own resign; an exit without one (the app never became
        // active) isn't a lock-like transition.
        resignedActiveAt = nil
        let lockLike = gap.map { $0 <= Self.lockLikeGap } ?? false
        let protected = UIApplication.shared.isProtectedDataAvailable ? "available" : "unavailable"
        log.add(.lifecycle, "Entered background: resign→background \(Self.ms(gap)) (\(lockLike ? "lock-like" : "app-switch-like")), protected data \(protected)")

        guard engine.needsLockCheck else { return }

        if mode() == .assumeLock {
            engine.appDidEnterBackground(at: now, lockLikeTransition: lockLike)
            log.add(.verdict, "Locked (assume-locked mode)")
            engine.lockConfirmed(verified: false, lockedAt: now)
            return
        }
        if let signal = lockSignalAt, now.timeIntervalSince(signal) <= Self.lockSignalWindow {
            // iOS said the phone was locking just as LockedIn left the screen: no check needed.
            engine.appDidEnterBackground(at: now, lockLikeTransition: true)
            engine.lockConfirmed(verified: true, lockedAt: signal)
            log.add(.verdict, "Locked: iOS reported the lock as LockedIn left the screen")
            return
        }
        if !lockLike && engine.tracksLocksAnywhere {
            // LockedIn keeps running, so the phone's own lock signal will resume the timer later.
            log.add(.check, "Left LockedIn: timer stays stopped until the phone locks")
            return
        }
        engine.appDidEnterBackground(at: now, lockLikeTransition: lockLike)
        if !lockLike {
            log.add(.check, "Timer stopped: this looks like leaving the app")
        }
        beginCheck(startedAt: now)
    }

    @objc private func willEnterForeground() {
        log.add(.lifecycle, "Will enter foreground")
    }

    @objc private func didBecomeActive() {
        log.add(.lifecycle, "Became active")
        if isChecking {
            log.add(.verdict, "Back before the lock check finished")
            endCheck()
        }
        refreshPasscodeState()
        engine.appDidBecomeActive(at: .now)
    }

    // MARK: Protected data

    /// Posted the moment the phone locks.
    @objc private func protectedDataWillBecomeUnavailable() {
        let now = Date.now
        lockSignalAt = now
        log.add(.protectedData, "Will become unavailable (phone locking)")
        if isChecking {
            confirmLock(source: "lock signal", lockedAt: now)
        } else if engine.tracksLocksAnywhere, UIApplication.shared.applicationState == .background {
            // Locked from another app.
            if engine.deviceLocked(estimatedAt: now) {
                log.add(.verdict, "Locked from another app: timer resumed")
            }
        }
    }

    /// Posted the moment the phone unlocks.
    @objc private func protectedDataDidBecomeAvailable() {
        lockSignalAt = nil
        log.add(.protectedData, "Became available (phone unlocked)")
        if isChecking, engine.session?.pendingCheck?.lockLikeTransition == true {
            // Unlocked before the lock was confirmed: it was a lock, so count it before stopping.
            confirmLock(source: "unlock signal", lockedAt: backgroundedAt ?? .now)
        }
        if engine.deviceUnlocked(at: .now) {
            log.add(.verdict, "Unlocked: timer stopped")
        }
    }

    // MARK: Background check

    private func beginCheck(startedAt: Date) {
        endCheck()
        let window: TimeInterval
        if engine.tracksLocksAnywhere {
            // Background audio keeps LockedIn running, so wait past iOS's slowest lock report.
            window = Self.trackingCheckWindow
        } else {
            backgroundTask = UIApplication.shared.beginBackgroundTask(withName: "LockCheck") { [weak self] in
                self?.expireCheck(reason: "background time ran out")
            }
            window = max(5, min(Self.maxCheckWindow, UIApplication.shared.backgroundTimeRemaining - 3))
        }
        log.add(.check, "Watching for the lock signal for \(Int(window))s")

        checkTask = Task { [weak self] in
            let deadline = startedAt.addingTimeInterval(window)
            while Date.now < deadline {
                try? await Task.sleep(for: .seconds(1))
                guard let self, !Task.isCancelled else { return }
                if !UIApplication.shared.isProtectedDataAvailable {
                    // The data goes about 10 s after the lock, so the lock came that much earlier.
                    self.confirmLock(source: "data check", lockedAt: .now.addingTimeInterval(-SessionEngine.protectedDataLockDelay))
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.expireCheck(reason: "no lock signal within \(Int(window))s")
        }
    }

    /// Confirms the pending lock check. `lockedAt` is when the phone locked, as best `source` tells.
    private func confirmLock(source: String, lockedAt: Date) {
        guard isChecking else { return }
        let now = Date.now
        let delay = backgroundedAt.map { now.timeIntervalSince($0) } ?? 0
        let since = engine.lockConfirmed(verified: true, lockedAt: lockedAt)
        var offset: TimeInterval = 0
        if let since, let start = backgroundedAt { offset = since.timeIntervalSince(start) }
        let counting = offset < 0.5 ? "counting from when it backgrounded" : "counting from \(String(format: "%.0f", offset))s after it backgrounded"
        log.add(.verdict, "Locked: confirmed by the \(source) \(String(format: "%.1f", delay))s after backgrounding, \(counting)")
        endCheck()
    }

    private func expireCheck(reason: String) {
        guard isChecking else { return }
        switch engine.lockCheckExpired(lockSignalExpected: engine.tracksLocksAnywhere) {
        case .locked:
            log.add(.verdict, "Locked (unverified): \(reason), but the transition looked like a lock")
        case .leftApp:
            log.add(.verdict, "Left the app: \(reason); timer stopped")
        case .unlockedQuickly:
            log.add(.verdict, "Not counted: \(reason), so the phone was unlocked again within seconds")
        case .noCheckPending:
            break
        }
        endCheck()
    }

    private func endCheck() {
        checkTask?.cancel()
        checkTask = nil
        if backgroundTask != .invalid {
            UIApplication.shared.endBackgroundTask(backgroundTask)
            backgroundTask = .invalid
        }
    }

    private static func ms(_ interval: TimeInterval?) -> String {
        guard let interval else { return "n/a" }
        return "\(Int((interval * 1000).rounded())) ms"
    }
}
