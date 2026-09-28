@preconcurrency import ActivityKit
import Foundation

/// Data for the Lock Screen / Dynamic Island Live Activity, shared by the app and the widget extension.
nonisolated struct LockInActivityAttributes: ActivityAttributes {
    nonisolated struct ContentState: Codable, Hashable, Sendable {
        nonisolated enum Phase: String, Codable, Hashable, Sendable {
            /// Session started; waiting for the first lock.
            case armed
            /// Phone is locked and the timer is running.
            case locked
            /// Phone was unlocked (or the user left the app); shown as "Unlocked".
            case paused
            /// Paused with the Pause button; locking doesn't count until Resume.
            case onBreak
            /// The session is over.
            case ended
        }

        var phase: Phase
        /// Locked-in seconds banked before the current locked stretch.
        var banked: TimeInterval
        /// Start of the current locked stretch, while `phase == .locked`.
        var lockedSince: Date?
        /// When the running timer stops on its own (the auto-end limit), if any.
        var stopsAt: Date?
        var unlockCount: Int
        /// LockedIn is running in the background, so locking from any app resumes the timer.
        var tracksAnyApp: Bool?
        /// When the pause started, while `phase == .onBreak`.
        var breakSince: Date?

        /// When the timer would have started had it never paused. Handing this to
        /// `Text(timerInterval:)` lets the Lock Screen count up without the app running.
        var virtualStart: Date? { lockedSince?.addingTimeInterval(-banked) }

        /// Total locked-in time once the timer has stopped at `stopsAt`.
        var secondsAtStop: TimeInterval? {
            guard let lockedSince, let stopsAt else { return nil }
            return banked + max(0, stopsAt.timeIntervalSince(lockedSince))
        }
    }

    var sessionID: UUID
    var subjectName: String?
    var subjectEmoji: String?
    var subjectColorHex: String?
    var targetSeconds: TimeInterval?
}
