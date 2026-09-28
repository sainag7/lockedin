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
/// iOS has no public "screen locked" API, so the first call is made on timing: a lock backgrounds
/// the app almost instantly, while going Home or switching apps animates first. A lock-like
/// transition starts the timer at once; anything slower keeps it stopped.
///
/// To confirm, LockedIn keeps running for about 25 seconds (a background task) and watches for the
/// phone's protected data becoming unavailable, which iOS does about 10 seconds after a lock (up to
/// ~40 s if the phone was just unlocked). That also catches a lock the timing misjudged.
final class LockDetector: NSObject {
    /// Resign-active → background faster than this looks like a lock rather than an app switch.
    static let lockLikeGap: TimeInterval = 0.15
    /// Longest we wait in the background for the lock signal (a background task lasts ~30 s).
    static let maxCheckWindow: TimeInterval = 25
    /// With background tracking there's no time limit, so wait past iOS's slowest lock report (~40 s).
    static let trackingCheckWindow: TimeInterval = 60

    private let engine: SessionEngine
    private let log: DiagnosticsLog
    private let mode: () -> DetectionMode

    private var resignedActiveAt: Date?
    private var backgroundedAt: Date?
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
        let lockLike = gap.map { $0 <= Self.lockLikeGap } ?? false
        let protected = UIApplication.shared.isProtectedDataAvailable ? "available" : "unavailable"
        log.add(.lifecycle, "Entered background: resign→background \(Self.ms(gap)) (\(lockLike ? "lock-like" : "app-switch-like")), protected data \(protected)")

        guard engine.needsLockCheck else { return }

        if mode() == .assumeLock {
            engine.appDidEnterBackground(at: now, lockLikeTransition: lockLike)
            log.add(.verdict, "Locked (assume-locked mode)")
            engine.lockConfirmed(verified: false, at: now)
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

    @objc private func protectedDataWillBecomeUnavailable() {
        log.add(.protectedData, "Will become unavailable (phone locking)")
        if isChecking {
            confirmLock(source: "notification")
        } else if engine.tracksLocksAnywhere, UIApplication.shared.applicationState == .background {
            // Locked from another app. iOS reports this about 10 s after the lock, so count from then.
            let estimate = Date.now.addingTimeInterval(-SessionEngine.protectedDataLockDelay)
            if engine.deviceLocked(estimatedAt: estimate) {
                log.add(.verdict, "Locked from another app: timer resumed, counting from ~\(Int(SessionEngine.protectedDataLockDelay))s ago")
            }
        }
    }

    @objc private func protectedDataDidBecomeAvailable() {
        log.add(.protectedData, "Became available (phone unlocked)")
        if engine.tracksLocksAnywhere, engine.deviceUnlocked(at: .now) {
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
                    self.confirmLock(source: "poll")
                    return
                }
            }
            guard let self, !Task.isCancelled else { return }
            self.expireCheck(reason: "no lock signal within \(Int(window))s")
        }
    }

    private func confirmLock(source: String) {
        guard isChecking else { return }
        let now = Date.now
        let delay = backgroundedAt.map { now.timeIntervalSince($0) } ?? 0
        let since = engine.lockConfirmed(verified: true, at: now)
        var offset: TimeInterval = 0
        if let since, let start = backgroundedAt { offset = since.timeIntervalSince(start) }
        let counting = offset < 0.5 ? "counting from when it backgrounded" : "counting from \(String(format: "%.0f", offset))s after it backgrounded"
        log.add(.verdict, "Locked: protected data went away \(String(format: "%.1f", delay))s after backgrounding (\(source)), \(counting)")
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
