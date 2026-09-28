@preconcurrency import ActivityKit
import SwiftUI
import WidgetKit

/// The Lock Screen banner and Dynamic Island shown during a session. This is what people see
/// every time they glance at their locked phone, so the timer counts up here on its own.
struct LockInLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: LockInActivityAttributes.self) { context in
            LockScreenView(attributes: context.attributes, state: context.state, isStale: context.isStale)
                .activityBackgroundTint(Palette.background.opacity(0.92))
                .activitySystemActionForegroundColor(Palette.accent)
        } dynamicIsland: { context in
            let state = context.state
            let look = PhaseLook(phase: state.phase, isStale: context.isStale)
            return DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    Label(look.title, systemImage: look.icon)
                        .font(.subheadline.weight(.semibold))
                        .foregroundStyle(look.tint)
                        .padding(.leading, 6)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    SessionTimerText(state: state, isStale: context.isStale)
                        .font(.system(size: 26, weight: .semibold, design: .rounded))
                        .foregroundStyle(look.tint)
                        .frame(maxWidth: 120, alignment: .trailing)
                        .padding(.trailing, 6)
                }
                DynamicIslandExpandedRegion(.bottom) {
                    VStack(alignment: .leading, spacing: 8) {
                        if let target = context.attributes.targetSeconds, target > 0 {
                            TargetProgressBar(state: state, target: target, isStale: context.isStale, tint: look.tint)
                        }
                        Text(StatusLine.text(attributes: context.attributes, state: state, isStale: context.isStale))
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.65))
                            .lineLimit(1)
                    }
                    .padding(.horizontal, 6)
                }
            } compactLeading: {
                Image(systemName: look.icon)
                    .foregroundStyle(look.tint)
            } compactTrailing: {
                SessionTimerText(state: state, isStale: context.isStale)
                    .font(.system(size: 14, weight: .semibold, design: .rounded))
                    .foregroundStyle(look.tint)
                    .frame(maxWidth: 58)
            } minimal: {
                Image(systemName: look.icon)
                    .foregroundStyle(look.tint)
            }
            .keylineTint(Palette.accent)
        }
    }
}

// MARK: - Lock Screen

private struct LockScreenView: View {
    let attributes: LockInActivityAttributes
    let state: LockInActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        let look = PhaseLook(phase: state.phase, isStale: isStale)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 12) {
                Image(systemName: look.icon)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(look.tint == .white ? Color.black : Palette.onAccent)
                    .frame(width: 40, height: 40)
                    .background(look.tint, in: Circle())

                VStack(alignment: .leading, spacing: 2) {
                    Text(look.title)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(subjectLine)
                        .font(.caption)
                        .foregroundStyle(.white.opacity(0.65))
                }
                .lineLimit(1)

                Spacer(minLength: 8)

                SessionTimerText(state: state, isStale: isStale)
                    .font(.system(size: 36, weight: .semibold, design: .rounded))
                    .foregroundStyle(look.tint)
                    .frame(maxWidth: 140, alignment: .trailing)
            }

            if let target = attributes.targetSeconds, target > 0 {
                TargetProgressBar(state: state, target: target, isStale: isStale, tint: look.tint)
            }

            Text(StatusLine.text(attributes: attributes, state: state, isStale: isStale))
                .font(.caption2)
                .foregroundStyle(.white.opacity(0.55))
                .lineLimit(1)
        }
        .padding(16)
    }

    private var subjectLine: String {
        guard let name = attributes.subjectName, !name.isEmpty else { return "LockedIn" }
        let emoji = attributes.subjectEmoji.map { $0.isEmpty ? "" : "\($0) " } ?? ""
        return "\(emoji)\(name)"
    }
}

// MARK: - Pieces

/// Counts up on its own while locked (no app updates needed); shows a fixed value otherwise.
private struct SessionTimerText: View {
    let state: LockInActivityAttributes.ContentState
    let isStale: Bool

    var body: some View {
        if state.phase == .locked, !isStale, let start = state.virtualStart {
            let end = state.stopsAt ?? start.addingTimeInterval(24 * 3600)
            Text(timerInterval: start...max(start, end), countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else if state.phase == .onBreak, let since = state.breakSince {
            // While paused, the big number is how long the break has lasted.
            Text(timerInterval: since...since.addingTimeInterval(24 * 3600), countsDown: false)
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        } else {
            Text(DurationText.clock(isStale ? (state.secondsAtStop ?? state.banked) : state.banked))
                .monospacedDigit()
                .multilineTextAlignment(.trailing)
        }
    }
}

private struct TargetProgressBar: View {
    let state: LockInActivityAttributes.ContentState
    let target: TimeInterval
    let isStale: Bool
    let tint: Color

    var body: some View {
        HStack(spacing: 10) {
            Group {
                if state.phase == .locked, !isStale, let start = state.virtualStart {
                    ProgressView(timerInterval: start...start.addingTimeInterval(target), countsDown: false) {
                        EmptyView()
                    } currentValueLabel: {
                        EmptyView()
                    }
                } else {
                    ProgressView(value: min(state.banked, target), total: target)
                }
            }
            .progressViewStyle(.linear)
            .tint(tint)

            Text(state.banked >= target ? "Target hit ✓" : "Target \(DurationText.short(target))")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.white.opacity(0.65))
                .fixedSize()
        }
    }
}

/// Title, icon, and color for each phase.
private struct PhaseLook {
    let title: String
    let icon: String
    let tint: Color

    init(phase: LockInActivityAttributes.ContentState.Phase, isStale: Bool) {
        switch (phase, isStale) {
        case (.locked, true), (.ended, _):
            self.init(title: "Session ended", icon: "checkmark", tint: Palette.accent)
        case (.locked, false):
            self.init(title: "Locked in", icon: "lock.fill", tint: Palette.accent)
        case (.paused, _):
            self.init(title: "Unlocked", icon: "lock.open.fill", tint: Palette.paused)
        case (.onBreak, _):
            self.init(title: "Paused", icon: "pause.fill", tint: Palette.onBreak)
        case (.armed, _):
            self.init(title: "Ready", icon: "timer", tint: .white)
        }
    }

    private init(title: String, icon: String, tint: Color) {
        self.title = title
        self.icon = icon
        self.tint = tint
    }
}

private enum StatusLine {
    static func text(
        attributes: LockInActivityAttributes,
        state: LockInActivityAttributes.ContentState,
        isStale: Bool
    ) -> String {
        switch state.phase {
        case .armed:
            return "Lock your phone to start the timer"
        case .locked where isStale:
            return "Hit the auto-end limit. Open LockedIn to see your session."
        case .locked:
            switch state.unlockCount {
            case 0: return "Timer runs while your phone is locked"
            case 1: return "1 unlock so far"
            default: return "\(state.unlockCount) unlocks so far"
            }
        case .paused:
            return state.tracksAnyApp == true ? "Lock your phone to keep going" : "Open LockedIn and lock your phone to keep going"
        case .onBreak:
            return "\(DurationText.short(state.banked)) locked in · Resume in LockedIn"
        case .ended:
            return "Nice work. Session saved."
        }
    }
}
