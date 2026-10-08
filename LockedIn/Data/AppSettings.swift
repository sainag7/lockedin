import Foundation
import Observation

/// User preferences, stored in UserDefaults.
@Observable
final class AppSettings {
    @ObservationIgnored private let defaults: UserDefaults

    var hasOnboarded: Bool { didSet { defaults.set(hasOnboarded, forKey: Key.hasOnboarded) } }
    var dailyGoalMinutes: Int { didSet { defaults.set(dailyGoalMinutes, forKey: Key.dailyGoalMinutes) } }
    /// Default session target; 0 means open-ended.
    var defaultTargetMinutes: Int { didSet { defaults.set(defaultTargetMinutes, forKey: Key.defaultTargetMinutes) } }
    /// End a session once the phone stays locked this long in one stretch; 0 means never.
    var autoEndHours: Int { didSet { defaults.set(autoEndHours, forKey: Key.autoEndHours) } }
    /// Hour (0–4) when a new day starts, so late-night sessions count toward the day before.
    var dayStartHour: Int { didSet { defaults.set(dayStartHour, forKey: Key.dayStartHour) } }
    var notifyTarget: Bool { didSet { defaults.set(notifyTarget, forKey: Key.notifyTarget) } }
    var notifyDailyGoal: Bool { didSet { defaults.set(notifyDailyGoal, forKey: Key.notifyDailyGoal) } }
    var notifyLeftApp: Bool { didSet { defaults.set(notifyLeftApp, forKey: Key.notifyLeftApp) } }
    /// Nudge after being unlocked this many minutes; 0 means off.
    var breakNudgeMinutes: Int { didSet { defaults.set(breakNudgeMinutes, forKey: Key.breakNudgeMinutes) } }
    var dailyReminderEnabled: Bool { didSet { defaults.set(dailyReminderEnabled, forKey: Key.dailyReminderEnabled) } }
    /// Minutes after midnight.
    var dailyReminderMinutes: Int { didSet { defaults.set(dailyReminderMinutes, forKey: Key.dailyReminderMinutes) } }
    var hapticsEnabled: Bool { didSet { defaults.set(hapticsEnabled, forKey: Key.hapticsEnabled) } }
    /// Keep LockedIn running in the background during sessions so locks count from any app.
    var trackLocksAnywhere: Bool { didSet { defaults.set(trackLocksAnywhere, forKey: Key.trackLocksAnywhere) } }
    /// Focus sound to play during a session.
    var backgroundSound: BackgroundSound { didSet { defaults.set(backgroundSound.rawValue, forKey: Key.backgroundSound) } }
    /// Focus-sound volume, 0...1.
    var soundVolume: Double { didSet { defaults.set(soundVolume, forKey: Key.soundVolume) } }
    var detectionMode: DetectionMode { didSet { defaults.set(detectionMode.rawValue, forKey: Key.detectionMode) } }
    var lastSubjectID: UUID? { didSet { defaults.set(lastSubjectID?.uuidString, forKey: Key.lastSubjectID) } }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        hasOnboarded = defaults.bool(forKey: Key.hasOnboarded)
        dailyGoalMinutes = defaults.object(forKey: Key.dailyGoalMinutes) as? Int ?? 120
        defaultTargetMinutes = defaults.object(forKey: Key.defaultTargetMinutes) as? Int ?? 0
        autoEndHours = defaults.object(forKey: Key.autoEndHours) as? Int ?? 3
        dayStartHour = defaults.object(forKey: Key.dayStartHour) as? Int ?? 0
        notifyTarget = defaults.object(forKey: Key.notifyTarget) as? Bool ?? true
        notifyDailyGoal = defaults.object(forKey: Key.notifyDailyGoal) as? Bool ?? true
        notifyLeftApp = defaults.object(forKey: Key.notifyLeftApp) as? Bool ?? true
        breakNudgeMinutes = defaults.object(forKey: Key.breakNudgeMinutes) as? Int ?? 5
        dailyReminderEnabled = defaults.bool(forKey: Key.dailyReminderEnabled)
        dailyReminderMinutes = defaults.object(forKey: Key.dailyReminderMinutes) as? Int ?? 19 * 60
        hapticsEnabled = defaults.object(forKey: Key.hapticsEnabled) as? Bool ?? true
        trackLocksAnywhere = defaults.object(forKey: Key.trackLocksAnywhere) as? Bool ?? true
        backgroundSound = defaults.string(forKey: Key.backgroundSound).flatMap(BackgroundSound.init(rawValue:)) ?? .none
        soundVolume = defaults.object(forKey: Key.soundVolume) as? Double ?? 0.6
        detectionMode = defaults.string(forKey: Key.detectionMode).flatMap(DetectionMode.init(rawValue:)) ?? .platformDefault
        lastSubjectID = defaults.string(forKey: Key.lastSubjectID).flatMap(UUID.init(uuidString:))
    }

    var dailyGoal: TimeInterval { TimeInterval(dailyGoalMinutes * 60) }

    var engineConfig: EngineConfig {
        EngineConfig(
            dailyGoal: dailyGoal,
            autoEndAfter: autoEndHours > 0 ? TimeInterval(autoEndHours * 3600) : nil,
            breakNudgeAfter: breakNudgeMinutes > 0 ? TimeInterval(breakNudgeMinutes * 60) : nil,
            trackLocksAnywhere: trackLocksAnywhere && detectionMode == .automatic,
            sound: backgroundSound,
            soundVolume: soundVolume
        )
    }

    var statsCalendar: StatsCalendar {
        StatsCalendar(calendar: .current, dayStartHour: dayStartHour)
    }

    private enum Key {
        static let hasOnboarded = "hasOnboarded"
        static let dailyGoalMinutes = "dailyGoalMinutes"
        static let defaultTargetMinutes = "defaultTargetMinutes"
        static let autoEndHours = "autoEndHours"
        static let dayStartHour = "dayStartHour"
        static let notifyTarget = "notifyTarget"
        static let notifyDailyGoal = "notifyDailyGoal"
        static let notifyLeftApp = "notifyLeftApp"
        static let breakNudgeMinutes = "breakNudgeMinutes"
        static let dailyReminderEnabled = "dailyReminderEnabled"
        static let dailyReminderMinutes = "dailyReminderMinutes"
        static let hapticsEnabled = "hapticsEnabled"
        static let trackLocksAnywhere = "trackLocksAnywhere"
        static let backgroundSound = "backgroundSound"
        static let soundVolume = "soundVolume"
        static let detectionMode = "detectionMode"
        static let lastSubjectID = "lastSubjectID"
    }
}
