@preconcurrency import ActivityKit
import Foundation
import UIKit

/// Shows the session on the Lock Screen and Dynamic Island.
///
/// Keeps exactly one Live Activity per session. If the app was stopped and relaunched, it
/// re-attaches to the Live Activity that's still on screen instead of starting a second one, and it
/// ends any stray ones, so a widget is never left counting on its own.
///
/// iOS ignores Live Activity updates from an app that's awake only to play plain background audio
/// ("Process is only playing background media so is forbidden to update activity", in
/// `liveactivitiesd`). LockedIn's keep-alive dodges this by using a `.playAndRecord` audio session,
/// which iOS permits (see `BackgroundAudio`). Each update is still sent under a background task
/// and confirmed against `contentUpdates`, which reports the states iOS actually shows, so a rare
/// dropped update is retried.
final class LiveActivityController: LiveActivityControlling {
    private typealias State = LockInActivityAttributes.ContentState

    private struct Desired {
        var attributes: LockInActivityAttributes
        var content: ActivityContent<State>
    }

    private static let maxTries = 4

    private var current: Activity<LockInActivityAttributes>? {
        didSet {
            if current?.id != oldValue?.id { watchContent() }
        }
    }
    private var desired: Desired?
    /// The state iOS last reported showing for `current`.
    private var shown: State?
    private var ending: Set<String> = []
    private var watcher: Task<Void, Never>?
    private var contentWatcher: Task<Void, Never>?
    /// True while `deliver()` runs; it always works toward the newest desired state.
    private var delivering = false
    private let log: (String) -> Void

    init(log: @escaping (String) -> Void) {
        self.log = log
        // Live Activities left over from before a relaunch can be reported late, so re-check
        // whenever ActivityKit reports one.
        watcher = Task { [weak self] in
            for await activity in Activity<LockInActivityAttributes>.activityUpdates {
                guard let self else { return }
                if activity.id != self.current?.id { self.apply() }
            }
        }
    }

    func show(_ attributes: LockInActivityAttributes, state: LockInActivityAttributes.ContentState, staleDate: Date?) {
        desired = Desired(attributes: attributes, content: ActivityContent(state: state, staleDate: staleDate))
        apply()
    }

    func end(_ finalState: LockInActivityAttributes.ContentState?, immediately: Bool) {
        desired = nil
        let content = finalState.map { ActivityContent(state: $0, staleDate: nil) }
        let policy: ActivityUIDismissalPolicy = immediately ? .immediate : .default
        if let activity = current {
            ending.insert(activity.id)
            withBackgroundTime("End Live Activity") {
                await activity.end(content, dismissalPolicy: policy)
            }
        }
        current = nil
        endStrays(keeping: nil)
    }

    func cleanUp(keeping sessionID: UUID?) {
        let keep = Activity<LockInActivityAttributes>.activities.first {
            $0.attributes.sessionID == sessionID && Self.isAlive($0)
        }
        if let keep, current == nil {
            current = keep
            log("Live Activity re-attached at launch")
        }
        endStrays(keeping: current?.id)
    }

    // MARK: Helpers

    private func apply() {
        guard let desired else {
            endStrays(keeping: nil)
            return
        }
        let sessionID = desired.attributes.sessionID

        // Prefer the one we hold; otherwise re-attach to one already on screen for this session.
        if let held = current, !(Self.isAlive(held) && held.attributes.sessionID == sessionID) {
            current = nil
        }
        if current == nil {
            current = Activity<LockInActivityAttributes>.activities.first {
                $0.attributes.sessionID == sessionID && Self.isAlive($0) && !ending.contains($0.id)
            }
            if current != nil { log("Live Activity re-attached") }
        }

        if current != nil {
            deliverSoon()
        } else if ActivityAuthorizationInfo().areActivitiesEnabled {
            do {
                let others = Activity<LockInActivityAttributes>.activities.count
                current = try Activity.request(attributes: desired.attributes, content: desired.content, pushType: nil)
                log("Live Activity started (\(others) other\(others == 1 ? "" : "s") visible)")
                sweepSoon()
            } catch {
                // Starting one only works while LockedIn is on screen; the next time it is, this retries.
                log("Couldn't start the Live Activity: \(error.localizedDescription)")
            }
        }
        endStrays(keeping: current?.id)
    }

    /// Starts `deliver()` unless it's running already, in which case it picks up the new state.
    private func deliverSoon() {
        guard !delivering, current != nil, let state = desired?.content.state, state != shown else { return }
        delivering = true
        Task {
            await deliver()
            delivering = false
        }
    }

    /// Sends the newest desired state until iOS shows it (see the type's notes). The play-and-record
    /// keep-alive means updates normally go through on the first try; the retry is a safety net.
    /// Sends aren't awaited, so an update iOS never answers can't hold up the ones after it, and
    /// `timestamp` keeps an older update from replacing a newer one.
    private func deliver() async {
        let task = BackgroundTask(name: "Update Live Activity")
        var target: State?
        var tries = 0
        while let activity = current, let content = desired?.content, content.state != shown {
            if content.state != target {
                target = content.state
                tries = 0
            }
            tries += 1
            guard tries <= Self.maxTries else {
                log("iOS didn't show \(Self.label(content.state.phase)) after \(Self.maxTries) tries")
                break
            }
            if UIApplication.shared.applicationState != .active {
                log("Sent \(Self.label(content.state.phase)) from the background (try \(tries))")
            }
            let sentAt = Date.now
            Task { await activity.update(content, alertConfiguration: nil, timestamp: sentAt) }
            // Updates that go through are shown within a few dozen milliseconds; allow extra on retry.
            await waitUntilShown(content.state, for: .milliseconds(tries == 1 ? 600 : 1500))
        }
        task.end()
    }

    /// Waits until iOS reports `state`, the desired state moves on, or `limit` passes.
    private func waitUntilShown(_ state: State, for limit: Duration) async {
        let deadline = ContinuousClock.now.advanced(by: limit)
        while shown != state, desired?.content.state == state, ContinuousClock.now < deadline {
            try? await Task.sleep(for: .milliseconds(50))
        }
    }

    /// Runs an ActivityKit change inside a background task, so it counts even when LockedIn is in
    /// the background. Used for ending, which happens as the audio stops anyway.
    private func withBackgroundTime(_ name: String, _ change: @escaping @MainActor () async -> Void) {
        let task = BackgroundTask(name: name)
        let inBackground = UIApplication.shared.applicationState != .active
        if inBackground, !task.isValid {
            log("iOS gave no background time, so the widget may not change")
        }
        Task {
            if inBackground {
                // Give iOS a moment to register the task before the change reaches it.
                try? await Task.sleep(for: .milliseconds(250))
            }
            await change()
            task.end()
        }
    }

    /// Tracks and logs each state iOS reports showing for the current Live Activity. iOS reports
    /// only the changes it accepted, so an update logged as sent with no "Showing" line was ignored.
    private func watchContent() {
        contentWatcher?.cancel()
        contentWatcher = nil
        shown = current?.content.state
        guard let activity = current else { return }
        contentWatcher = Task { [weak self] in
            for await content in activity.contentUpdates {
                guard let self, !Task.isCancelled else { return }
                self.shown = content.state
                self.log("Showing \(Self.label(content.state.phase))")
            }
        }
    }

    /// After a relaunch, iOS can report an older Live Activity a moment late; end it when it shows up.
    private func sweepSoon() {
        Task { [weak self] in
            for delay in [2, 8] {
                try? await Task.sleep(for: .seconds(delay))
                guard let self else { return }
                self.endStrays(keeping: self.current?.id)
            }
        }
    }

    private func endStrays(keeping keepID: String?) {
        for activity in Activity<LockInActivityAttributes>.activities
        where activity.id != keepID && Self.isAlive(activity) && !ending.contains(activity.id) {
            ending.insert(activity.id)
            log("Ended a stray Live Activity")
            withBackgroundTime("End stray Live Activity") {
                await activity.end(nil, dismissalPolicy: .immediate)
            }
        }
    }

    private static func isAlive(_ activity: Activity<LockInActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }

    /// What the widget says for `phase`, as used in the log.
    private static func label(_ phase: LockInActivityAttributes.ContentState.Phase) -> String {
        switch phase {
        case .armed: "Ready"
        case .locked: "Locked in"
        case .paused: "Unlocked"
        case .onBreak: "Paused"
        case .ended: "Ended"
        }
    }
}

/// A UIKit background task that's ended once: when the work finishes, or when iOS runs out of time.
private final class BackgroundTask {
    private var id: UIBackgroundTaskIdentifier = .invalid

    init(name: String) {
        id = UIApplication.shared.beginBackgroundTask(withName: name) { [weak self] in
            self?.end()
        }
    }

    var isValid: Bool { id != .invalid }

    func end() {
        guard id != .invalid else { return }
        UIApplication.shared.endBackgroundTask(id)
        id = .invalid
    }
}
