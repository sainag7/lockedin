import SwiftUI

/// The Home tab while a session is running. People mostly see this right after unlocking,
/// because while the phone is locked the Live Activity is the "running" screen.
struct ActiveSessionView: View {
    let session: ActiveSession

    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @State private var confirmEnd = false
    @State private var toast: StretchCredit?

    var body: some View {
        VStack(spacing: 0) {
            topBar
            Spacer(minLength: 16)
            switch session.state {
            case .armed:
                ArmedContent(showPasscodeWarning: !engine.deviceHasPasscode && settings.detectionMode == .automatic)
            case .locked:
                LockedContent(session: session)
            case .paused:
                PausedContent(session: session)
            case .onBreak:
                BreakContent(session: session)
            }
            Spacer(minLength: 16)
            bottomButtons
        }
        .padding(.horizontal, 20)
        .padding(.top, 8)
        .padding(.bottom, 20)
        .overlay(alignment: .top) { toastView }
        .onAppear(perform: showToastIfRecent)
        .onChange(of: engine.lastCredit) { showToastIfRecent() }
        .haptic(.success, trigger: toast?.id, enabled: settings.hapticsEnabled && toast != nil)
        .haptic(.impact(weight: .light), trigger: session.isOnBreak, enabled: settings.hapticsEnabled)
        .alert("End this session?", isPresented: $confirmEnd) {
            Button("Keep Going", role: .cancel) {}
            Button("End & Save") { engine.end() }
        } message: {
            Text("You've locked in for \(DurationText.short(session.lockedSeconds(at: .now))).")
        }
    }

    // MARK: Pieces

    private var topBar: some View {
        HStack(spacing: 8) {
            if let subject = engine.subject {
                pill(subject.emoji.isEmpty ? subject.name : "\(subject.emoji) \(subject.name)", color: Palette.subjectColor(subject.colorHex))
            } else {
                pill("Session", color: Palette.textSecondary)
            }
            if let target = session.targetSeconds {
                pill("Target \(DurationText.short(target))", color: Palette.textSecondary)
            }
            Spacer()
            Text("Started \(session.startedAt.formatted(date: .omitted, time: .shortened))")
                .font(.caption)
                .foregroundStyle(Palette.textTertiary)
        }
    }

    private func pill(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .background(Palette.surface, in: Capsule())
            .overlay(Capsule().stroke(Palette.stroke))
    }

    @ViewBuilder
    private var bottomButtons: some View {
        switch session.state {
        case .armed:
            HStack(spacing: 10) {
                pauseButton
                Button("Cancel") { engine.cancel() }
                    .buttonStyle(SecondaryButtonStyle(tint: Palette.textSecondary))
            }
        case .onBreak:
            VStack(spacing: 10) {
                Button {
                    engine.resume()
                } label: {
                    Label("Resume", systemImage: "play.fill")
                }
                .buttonStyle(PrimaryButtonStyle())
                endButton
            }
        case .locked, .paused:
            HStack(spacing: 10) {
                pauseButton
                endButton
            }
        }
    }

    private var pauseButton: some View {
        Button {
            engine.pause()
        } label: {
            Label("Pause", systemImage: "pause.fill")
        }
        .buttonStyle(SecondaryButtonStyle(tint: Palette.onBreak))
        .disabled(!engine.canPause)
    }

    private var endButton: some View {
        Button {
            confirmEnd = true
        } label: {
            Label("End Session", systemImage: "stop.fill")
        }
        .buttonStyle(SecondaryButtonStyle())
    }

    @ViewBuilder
    private var toastView: some View {
        if let toast {
            Text("+\(DurationText.clock(toast.seconds)) locked in 🔒")
                .font(.headline)
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(Palette.onAccent)
                .padding(.horizontal, 18)
                .padding(.vertical, 10)
                .background(Palette.accent, in: Capsule())
                .shadow(color: Palette.accent.opacity(0.4), radius: 14, y: 4)
                .padding(.top, 44)
                .transition(.move(edge: .top).combined(with: .opacity))
                .accessibilityLabel("Added \(DurationText.spoken(toast.seconds)) of locked in time")
        }
    }

    private func showToastIfRecent() {
        guard let credit = engine.lastCredit, Date.now.timeIntervalSince(credit.at) < 10, toast?.id != credit.id else { return }
        withAnimation(.spring(duration: 0.45)) { toast = credit }
        Task {
            try? await Task.sleep(for: .seconds(3.5))
            withAnimation(.easeOut(duration: 0.3)) {
                if toast?.id == credit.id { toast = nil }
            }
        }
    }
}

// MARK: - States

private struct ArmedContent: View {
    let showPasscodeWarning: Bool

    var body: some View {
        VStack(spacing: 28) {
            ZStack {
                Circle()
                    .fill(Palette.accent.opacity(0.1))
                    .frame(width: 200, height: 200)
                Circle()
                    .stroke(Palette.accent.opacity(0.35), lineWidth: 2)
                    .frame(width: 200, height: 200)
                Image(systemName: "lock.fill")
                    .font(.system(size: 76, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .symbolEffect(.pulse, options: .repeating)
            }
            .shadow(color: Palette.accent.opacity(0.25), radius: 30)

            VStack(spacing: 10) {
                Text("Lock your phone to start")
                    .font(.title2.weight(.bold))
                    .fontDesign(.rounded)
                Text("Press the side button. The timer runs while your phone is locked and pauses when you unlock.")
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }

            if showPasscodeWarning {
                Label("No passcode is set on this iPhone, so only locks made from inside LockedIn count. Set a passcode to track locks from any app.", systemImage: "exclamationmark.triangle.fill")
                    .font(.footnote)
                    .foregroundStyle(Palette.paused)
                    .card(padding: 14)
            }
        }
    }
}

private struct PausedContent: View {
    let session: ActiveSession

    var body: some View {
        let now = Date.now
        VStack(spacing: 24) {
            Label(session.state == .paused(.leftApp) ? "Stopped · you left the app" : "Unlocked", systemImage: "lock.open.fill")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(Palette.paused)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.paused.opacity(0.14), in: Capsule())

            VStack(spacing: 2) {
                Text(DurationText.clock(session.bankedSeconds))
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text("locked in")
                    .font(.headline)
                    .foregroundStyle(Palette.textSecondary)
            }
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("\(DurationText.spoken(session.bankedSeconds)) locked in")

            if let target = session.targetSeconds {
                TargetProgress(banked: session.bankedSeconds, target: target)
            }

            HStack(spacing: 10) {
                StatTile(title: "Unlocks", value: "\(session.unlockCount)", systemImage: "lock.open.fill", tint: Palette.paused)
                StatTile(title: "Longest", value: DurationText.short(session.longestStretch(at: now)), systemImage: "timer")
                StatTile(title: "Focus", value: session.focus(at: now).map { "\(Int(($0 * 100).rounded()))%" } ?? "–", systemImage: "scope")
            }

            HStack(spacing: 12) {
                Image(systemName: "lock.fill")
                    .foregroundStyle(Palette.accent)
                Text("Lock your phone to keep going")
                    .font(.subheadline.weight(.semibold))
                Spacer()
            }
            .card(padding: 14)
        }
    }
}

/// Paused with the Pause button: how long the break has lasted, what's banked, and an optional reminder.
private struct BreakContent: View {
    let session: ActiveSession

    @Environment(SessionEngine.self) private var engine
    private static let reminderMinutes = [5, 10, 15, 30]

    var body: some View {
        let since = session.breakSince ?? .now
        VStack(spacing: 24) {
            Label("Paused", systemImage: "pause.fill")
                .font(.caption.weight(.bold))
                .textCase(.uppercase)
                .tracking(1)
                .foregroundStyle(Palette.onBreak)
                .padding(.horizontal, 12)
                .padding(.vertical, 6)
                .background(Palette.onBreak.opacity(0.14), in: Capsule())

            TimelineView(.periodic(from: .now, by: 1)) { context in
                let onBreak = context.date.timeIntervalSince(since)
                VStack(spacing: 2) {
                    Text(DurationText.clock(onBreak))
                        .font(.system(size: 76, weight: .bold, design: .rounded))
                        .monospacedDigit()
                        .contentTransition(.numericText())
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                    Text("on break · \(DurationText.short(session.bankedSeconds)) locked in so far")
                        .font(.headline)
                        .foregroundStyle(Palette.textSecondary)
                }
                .accessibilityElement(children: .ignore)
                .accessibilityLabel("On break for \(DurationText.spoken(onBreak)). \(DurationText.spoken(session.bankedSeconds)) locked in so far.")
            }

            VStack(alignment: .leading, spacing: 12) {
                SectionHeader(title: "Remind me in", trailing: reminderTime)
                HStack(spacing: 8) {
                    ForEach(Self.reminderMinutes, id: \.self) { minutes in
                        let picked = session.breakReminderMinutes == minutes
                        Chip(title: "\(minutes)m", isSelected: picked, tint: Palette.onBreak) {
                            engine.setBreakReminder(minutes: picked ? nil : minutes)
                        }
                    }
                }
            }
            .card(padding: 14)

            HStack(spacing: 12) {
                Image(systemName: "lock.slash.fill")
                    .foregroundStyle(Palette.onBreak)
                Text("Locking your phone won't count until you resume")
                    .font(.subheadline.weight(.semibold))
                Spacer(minLength: 0)
            }
            .card(padding: 14)
        }
    }

    private var reminderTime: String? {
        session.breakReminderAt.map { "at \($0.formatted(date: .omitted, time: .shortened))" }
    }
}

/// Only visible in "assume locked" mode or for an instant around a lock.
private struct LockedContent: View {
    let session: ActiveSession

    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { context in
            VStack(spacing: 16) {
                Label("Locked in", systemImage: "lock.fill")
                    .font(.caption.weight(.bold))
                    .textCase(.uppercase)
                    .tracking(1)
                    .foregroundStyle(Palette.accent)
                Text(DurationText.clock(session.lockedSeconds(at: context.date)))
                    .font(.system(size: 76, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .contentTransition(.numericText())
            }
        }
    }
}

private struct TargetProgress: View {
    let banked: TimeInterval
    let target: TimeInterval

    var body: some View {
        let done = banked >= target
        VStack(spacing: 8) {
            ProgressView(value: min(banked, target), total: target)
                .tint(done ? Palette.accent : Palette.accent.opacity(0.8))
            HStack {
                Text(done ? "Target hit ✓" : "\(DurationText.short(target - banked)) to your target")
                    .fontWeight(done ? .semibold : .regular)
                    .foregroundStyle(done ? Palette.accent : Palette.textSecondary)
                Spacer()
                Text(done && banked > target ? "+\(DurationText.short(banked - target)) bonus" : DurationText.short(target))
                    .foregroundStyle(Palette.textTertiary)
            }
            .font(.footnote)
        }
        .padding(.horizontal, 4)
    }
}
