import Foundation
import Observation
import UserNotifications

nonisolated enum NotificationID {
    static let target = "session.target"
    static let dailyGoal = "session.dailyGoal"
    static let autoEnd = "session.autoEnd"
    static let breakNudge = "session.breakNudge"
    static let leftApp = "session.leftApp"
    static let breakReminder = "session.breakReminder"
    static let dailyReminder = "daily.reminder"

    static let whileLocked = [target, dailyGoal, autoEnd]
    static let session = whileLocked + [breakNudge, leftApp, breakReminder]

    /// Reminders that only make sense when LockedIn isn't on screen.
    static let hiddenInForeground: Set<String> = [breakNudge, leftApp]
}

/// Local notifications: target/goal reached, auto-end, "you left the app", break nudges, and the daily reminder.
@Observable
final class NotificationScheduler: SessionNotifying {
    private(set) var authorization: UNAuthorizationStatus = .notDetermined

    @ObservationIgnored private let settings: AppSettings
    @ObservationIgnored private let center = UNUserNotificationCenter.current()

    init(settings: AppSettings) {
        self.settings = settings
    }

    // MARK: Permission

    func refreshAuthorization() async {
        authorization = await center.notificationSettings().authorizationStatus
    }

    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorization()
        return granted
    }

    // MARK: SessionNotifying

    func scheduleWhileLocked(_ plan: LockedNotificationPlan) {
        cancelWhileLocked()
        if settings.notifyTarget, let at = plan.targetAt, let target = plan.targetSeconds {
            schedule(
                NotificationID.target, at: at,
                title: "Target hit 🎯",
                body: "\(DurationText.short(target)) locked in. Keep going, or unlock to wrap up."
            )
        }
        if settings.notifyDailyGoal, let at = plan.dailyGoalAt {
            schedule(
                NotificationID.dailyGoal, at: at,
                title: "Daily goal reached 🔥",
                body: "That's \(DurationText.short(plan.dailyGoalSeconds)) locked in today. Streak secured."
            )
        }
        if let at = plan.autoEndAt, let limit = plan.autoEndSeconds {
            schedule(
                NotificationID.autoEnd, at: at,
                title: "Session auto-ended",
                body: "Your phone was locked for \(DurationText.short(limit)) straight, so LockedIn stopped counting. Still studying? Start a new session."
            )
        }
    }

    func cancelWhileLocked() {
        center.removePendingNotificationRequests(withIdentifiers: NotificationID.whileLocked)
    }

    func scheduleBreakNudge(at date: Date, lockAnywhere: Bool) {
        schedule(
            NotificationID.breakNudge, at: date,
            title: "Break's over? ⏳",
            body: lockAnywhere
                ? "Lock your phone to keep your session going."
                : "Open LockedIn and lock your phone to keep your session going."
        )
    }

    func cancelBreakNudge() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.breakNudge])
    }

    func notifyLeftApp(sessionStarted: Bool) {
        guard settings.notifyLeftApp else { return }
        if sessionStarted {
            schedule(
                NotificationID.leftApp, at: .now,
                title: "Session paused ⏸",
                body: "You left LockedIn, so the timer stopped. Come back and lock your phone to resume."
            )
        } else {
            schedule(
                NotificationID.leftApp, at: .now,
                title: "LockedIn is waiting 🔒",
                body: "Open LockedIn and lock your phone to start the timer."
            )
        }
    }

    func scheduleBreakReminder(at date: Date) {
        schedule(
            NotificationID.breakReminder, at: date,
            title: "Break's over ☕",
            body: "Open LockedIn and tap Resume to get back to it."
        )
    }

    func cancelBreakReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.breakReminder])
    }

    func clearLeftAppAlerts() {
        center.removeDeliveredNotifications(withIdentifiers: [NotificationID.leftApp, NotificationID.breakNudge])
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.leftApp])
    }

    func cancelSessionNotifications() {
        center.removePendingNotificationRequests(withIdentifiers: NotificationID.session)
    }

    // MARK: Daily reminder

    func updateDailyReminder() {
        center.removePendingNotificationRequests(withIdentifiers: [NotificationID.dailyReminder])
        guard settings.dailyReminderEnabled else { return }
        let content = UNMutableNotificationContent()
        content.title = "Time to lock in 📚"
        content.body = "Put your phone down and get a session in. Your streak is counting on you."
        content.sound = .default
        var time = DateComponents()
        time.hour = settings.dailyReminderMinutes / 60
        time.minute = settings.dailyReminderMinutes % 60
        let trigger = UNCalendarNotificationTrigger(dateMatching: time, repeats: true)
        center.add(UNNotificationRequest(identifier: NotificationID.dailyReminder, content: content, trigger: trigger))
    }

    // MARK: Helpers

    private func schedule(_ id: String, at date: Date, title: String, body: String) {
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default
        let trigger = UNTimeIntervalNotificationTrigger(timeInterval: max(1, date.timeIntervalSinceNow), repeats: false)
        center.add(UNNotificationRequest(identifier: id, content: content, trigger: trigger))
    }
}
