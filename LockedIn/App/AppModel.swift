import Foundation
import SwiftData

/// Creates the app's long-lived objects and wires them together.
final class AppModel {
    let container: ModelContainer
    let settings: AppSettings
    let diagnostics: DiagnosticsLog
    let notifications: NotificationScheduler
    let engine: SessionEngine
    private let detector: LockDetector

    init() {
        do {
            container = try ModelContainer(for: Subject.self, StudySession.self, LockSegment.self)
        } catch {
            fatalError("Couldn't open the LockedIn database: \(error)")
        }

        let settings = AppSettings()
        let diagnostics = DiagnosticsLog()
        let notifications = NotificationScheduler(settings: settings)
        let keepAlive = BackgroundAudio { diagnostics.add(.session, $0) }
        let liveActivities = LiveActivityController { diagnostics.add(.widget, $0) }

        let engine = SessionEngine(
            store: UserDefaultsSessionStore(),
            liveActivity: liveActivities,
            notifier: notifications,
            archive: SessionArchiver(context: container.mainContext),
            keepAlive: keepAlive,
            config: { settings.engineConfig },
            dayInterval: { settings.statsCalendar.interval(containing: $0) },
            bootTime: BootTime.current
        )
        engine.log = { diagnostics.add(.session, $0) }
        // A launch mid-session means the previous run was stopped (by iOS, a crash, or Xcode).
        diagnostics.add(.lifecycle, engine.session == nil ? "App launched" : "App launched mid-session (the last run was stopped)")

        self.settings = settings
        self.diagnostics = diagnostics
        self.notifications = notifications
        self.engine = engine
        self.detector = LockDetector(engine: engine, log: diagnostics) { settings.detectionMode }

        // The detector checks for a passcode first; background tracking depends on it.
        detector.start()
        engine.restoreAfterLaunch()
        notifications.updateDailyReminder()
        #if DEBUG
        WidgetSelfTest.runIfRequested(engine: engine, liveActivity: liveActivities, log: diagnostics)
        #endif
    }
}
