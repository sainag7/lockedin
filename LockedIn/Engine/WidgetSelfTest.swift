#if DEBUG
import ActivityKit
import UIKit

/// Checks on a real iPhone that the Lock Screen widget keeps up while LockedIn runs in the
/// background, where iOS is strict about Live Activity updates (see `LiveActivityController`).
///
/// Launch with `-widgetSelfTest` while no session is running, then switch to another app. Every
/// 20 seconds the widget flips between "Locked in" and "Unlocked", and Settings → Diagnostics shows
/// (via the "Showing …" lines) whether iOS actually applied each change. The test session is
/// discarded at the end, so it never reaches your stats.
enum WidgetSelfTest {
    static func runIfRequested(engine: SessionEngine, liveActivity: LiveActivityControlling, log: DiagnosticsLog) {
        guard ProcessInfo.processInfo.arguments.contains("-widgetSelfTest") else { return }
        guard engine.session == nil else {
            log.add(.widget, "Self-test skipped: end the current session first")
            return
        }
        engine.start(subjectID: nil, targetSeconds: nil)
        guard let sessionID = engine.session?.id else { return }
        log.add(.widget, "Self-test: switch to another app")

        Task {
            while UIApplication.shared.applicationState != .background {
                try? await Task.sleep(for: .seconds(1))
            }
            // Wait past the moment of leaving the screen, when iOS accepts updates anyway.
            try? await Task.sleep(for: .seconds(15))
            let attributes = LockInActivityAttributes(
                sessionID: sessionID, subjectName: nil, subjectEmoji: nil, subjectColorHex: nil, targetSeconds: nil
            )
            for round in 1...4 {
                guard engine.session?.id == sessionID else { return }
                let locked = !round.isMultiple(of: 2)
                log.add(.widget, "Self-test round \(round): \(locked ? "Locked in" : "Unlocked")")
                let state = LockInActivityAttributes.ContentState(
                    phase: locked ? .locked : .paused,
                    banked: 0,
                    lockedSince: locked ? .now : nil,
                    stopsAt: nil,
                    unlockCount: round,
                    tracksAnyApp: true
                )
                liveActivity.show(attributes, state: state, staleDate: nil)
                try? await Task.sleep(for: .seconds(20))
            }
            log.add(.widget, "Self-test done")
            engine.cancel()
        }
    }
}
#endif
