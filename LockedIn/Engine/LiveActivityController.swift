@preconcurrency import ActivityKit
import Foundation

/// Shows the session on the Lock Screen and Dynamic Island.
///
/// Keeps exactly one Live Activity per session. If the app was stopped and relaunched, it
/// re-attaches to the Live Activity that's still on screen instead of starting a second one, and it
/// ends any stray ones, so a widget is never left counting on its own.
final class LiveActivityController: LiveActivityControlling {
    private struct Desired {
        var attributes: LockInActivityAttributes
        var content: ActivityContent<LockInActivityAttributes.ContentState>
    }

    private var current: Activity<LockInActivityAttributes>?
    private var desired: Desired?
    private var ending: Set<String> = []
    private var watcher: Task<Void, Never>?
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
            Task { await activity.end(content, dismissalPolicy: policy) }
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

        if let activity = current {
            let content = desired.content
            Task { await activity.update(content) }
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
            Task { await activity.end(nil, dismissalPolicy: .immediate) }
        }
    }

    private static func isAlive(_ activity: Activity<LockInActivityAttributes>) -> Bool {
        activity.activityState == .active || activity.activityState == .stale
    }
}
