import SwiftData
import SwiftUI

/// First launch: what LockedIn does, the one rule, a daily goal, subjects, and notifications.
struct OnboardingView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(SessionEngine.self) private var engine
    @Environment(\.modelContext) private var context

    @State private var step = 0
    @State private var goalMinutes = 120
    @State private var chosen: [String] = []
    @State private var custom: [String] = []
    @State private var newSubject = ""
    @State private var askedForNotifications = false
    @State private var reminderOn = false
    @State private var reminderTime = Calendar.current.date(bySettingHour: 19, minute: 0, second: 0, of: .now) ?? .now

    private let stepCount = 5
    private static let suggestions: [(name: String, emoji: String)] = [
        ("Math", "📐"), ("Science", "🧪"), ("English", "📖"), ("History", "🏛️"),
        ("CS", "💻"), ("Languages", "🌍"), ("Reading", "📚"), ("Art", "🎨"),
    ]
    private static let goals = [30, 60, 90, 120, 180, 240, 300, 360]

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack {
                page
                    .id(step)
                    .transition(.asymmetric(
                        insertion: .move(edge: .trailing).combined(with: .opacity),
                        removal: .move(edge: .leading).combined(with: .opacity)
                    ))
            }
            .frame(maxHeight: .infinity)
            bottomButton
        }
        .padding(.horizontal, 24)
        .padding(.bottom, 12)
        .background(Palette.background.ignoresSafeArea())
    }

    // MARK: Chrome

    private var topBar: some View {
        HStack {
            Button {
                withAnimation(.spring(duration: 0.4)) { step -= 1 }
            } label: {
                Image(systemName: "chevron.left")
                    .font(.body.weight(.semibold))
                    .frame(width: 40, height: 40)
            }
            .buttonStyle(.plain)
            .opacity(step > 0 ? 1 : 0)
            .disabled(step == 0)
            .accessibilityLabel("Back")

            Spacer()
            HStack(spacing: 6) {
                ForEach(0..<stepCount, id: \.self) { index in
                    Capsule()
                        .fill(index <= step ? Palette.accent : Color.white.opacity(0.15))
                        .frame(width: index == step ? 22 : 8, height: 8)
                }
            }
            .animation(.spring(duration: 0.35), value: step)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("Step \(step + 1) of \(stepCount)")
            Spacer()
            Color.clear.frame(width: 40, height: 40)
        }
        .padding(.top, 8)
    }

    @ViewBuilder
    private var page: some View {
        switch step {
        case 0: welcome
        case 1: howItWorks
        case 2: goal
        case 3: subjects
        default: notificationsPage
        }
    }

    private var bottomButton: some View {
        VStack(spacing: 8) {
            Button(action: next) {
                Text(buttonTitle)
            }
            .buttonStyle(PrimaryButtonStyle())

            if step == 3 && chosen.isEmpty && custom.isEmpty {
                Text("You can add subjects later.")
                    .font(.footnote)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }

    private var buttonTitle: String {
        switch step {
        case 0: "Get started"
        case 3: chosen.isEmpty && custom.isEmpty ? "Skip for now" : "Continue"
        case stepCount - 1: "Start locking in"
        default: "Continue"
        }
    }

    // MARK: Pages

    private var welcome: some View {
        VStack(spacing: 28) {
            Spacer()
            ZStack {
                Circle()
                    .fill(RadialGradient(colors: [Palette.accent.opacity(0.35), .clear], center: .center, startRadius: 10, endRadius: 150))
                    .frame(width: 300, height: 300)
                Image(systemName: "lock.fill")
                    .font(.system(size: 96, weight: .semibold))
                    .foregroundStyle(Palette.accent)
                    .symbolEffect(.bounce, options: .nonRepeating)
            }
            VStack(spacing: 12) {
                Text("LockedIn")
                    .font(.system(size: 44, weight: .heavy, design: .rounded))
                Text("Put your phone down.\nWatch your focus add up.")
                    .font(.title3)
                    .foregroundStyle(Palette.textSecondary)
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
    }

    private var howItWorks: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                title("How it works", subtitle: "Your phone becomes the timer.")
                HowItWorksSteps()
                Label {
                    Text("**Works from any app:** during a session, locking your phone starts the timer and unlocking it stops the timer, whatever app you're in.")
                } icon: {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Palette.accent)
                }
                .font(.subheadline)
                .card(padding: 14)

                if !engine.deviceHasPasscode && settings.detectionMode == .automatic {
                    Label("This iPhone has no passcode, so LockedIn can only count locks made from inside the app. Set one in Settings → Face ID & Passcode to track locks from any app.", systemImage: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(Palette.paused)
                        .card(padding: 14)
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
    }

    private var goal: some View {
        VStack(alignment: .leading, spacing: 28) {
            title("Set a daily goal", subtitle: "How long do you want to lock in each day? Hitting it builds your streak. You can change it anytime.")
            Text(DurationText.short(TimeInterval(goalMinutes * 60)))
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .foregroundStyle(Palette.accent)
                .contentTransition(.numericText())
                .frame(maxWidth: .infinity)
                .animation(.snappy, value: goalMinutes)
            FlowLayout(spacing: 10) {
                ForEach(Self.goals, id: \.self) { minutes in
                    Chip(title: DurationText.short(TimeInterval(minutes * 60)), isSelected: goalMinutes == minutes) {
                        goalMinutes = minutes
                    }
                }
            }
            Spacer()
        }
        .padding(.top, 24)
    }

    private var subjects: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                title("What are you studying?", subtitle: "Tag sessions to see where your time goes. Pick a few, or add your own.")
                FlowLayout(spacing: 10) {
                    ForEach(Self.suggestions, id: \.name) { item in
                        Chip(title: "\(item.emoji) \(item.name)", isSelected: chosen.contains(item.name)) {
                            toggle(item.name)
                        }
                    }
                    ForEach(custom, id: \.self) { name in
                        Chip(title: name, isSelected: true) {
                            custom.removeAll { $0 == name }
                        }
                    }
                }
                HStack(spacing: 10) {
                    TextField("Add your own (e.g. Organic Chem)", text: $newSubject)
                        .submitLabel(.done)
                        .onSubmit(addCustom)
                        .padding(.horizontal, 14)
                        .padding(.vertical, 12)
                        .background(Palette.surface, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    Button(action: addCustom) {
                        Image(systemName: "plus")
                            .font(.headline)
                            .foregroundStyle(Palette.onAccent)
                            .frame(width: 46, height: 46)
                            .background(Palette.accent, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
                    }
                    .buttonStyle(.plain)
                    .disabled(newSubject.trimmingCharacters(in: .whitespaces).isEmpty)
                    .accessibilityLabel("Add subject")
                }
            }
            .padding(.vertical, 24)
        }
        .scrollIndicators(.hidden)
        .scrollDismissesKeyboard(.interactively)
    }

    private var notificationsPage: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                title("Stay on track", subtitle: "A few well-timed nudges. Never spam.")
                VStack(alignment: .leading, spacing: 16) {
                    perk("target", "Target and daily goal alerts", "Know the moment you hit them, without unlocking.")
                    perk("pause.circle.fill", "Heads-up if you leave", "If you switch apps mid-session, we'll tell you the timer paused.")
                    perk("hourglass", "Break reminders", "A nudge when a quick check turns into a long break.")
                }
                .card(padding: 18)

                if notifications.authorization == .authorized || askedForNotifications {
                    Toggle(isOn: $reminderOn) {
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Daily reminder").font(.headline)
                            Text("A nudge to get your session in.").font(.caption).foregroundStyle(Palette.textSecondary)
                        }
                    }
                    .card(padding: 16)
                    if reminderOn {
                        DatePicker("Remind me at", selection: $reminderTime, displayedComponents: .hourAndMinute)
                            .card(padding: 16)
                    }
                } else {
                    Button {
                        Task {
                            await notifications.requestAuthorization()
                            askedForNotifications = true
                        }
                    } label: {
                        Label("Turn on notifications", systemImage: "bell.badge.fill")
                    }
                    .buttonStyle(SecondaryButtonStyle(tint: Palette.accent))
                }
            }
            .padding(.vertical, 24)
            .animation(.snappy, value: reminderOn)
        }
        .scrollIndicators(.hidden)
        .task { await notifications.refreshAuthorization() }
    }

    // MARK: Pieces

    private func title(_ text: String, subtitle: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(text)
                .font(.largeTitle.weight(.bold))
                .fontDesign(.rounded)
            Text(subtitle)
                .font(.body)
                .foregroundStyle(Palette.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func perk(_ icon: String, _ title: String, _ detail: String) -> some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: icon)
                .font(.title3)
                .foregroundStyle(Palette.accent)
                .frame(width: 28)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.headline)
                Text(detail).font(.subheadline).foregroundStyle(Palette.textSecondary)
            }
        }
    }

    // MARK: Actions

    private func toggle(_ name: String) {
        if let index = chosen.firstIndex(of: name) {
            chosen.remove(at: index)
        } else {
            chosen.append(name)
        }
    }

    private func addCustom() {
        let name = newSubject.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !custom.contains(name), !chosen.contains(name) else { return }
        custom.append(name)
        newSubject = ""
    }

    private func next() {
        if step < stepCount - 1 {
            withAnimation(.spring(duration: 0.4)) { step += 1 }
        } else {
            finish()
        }
    }

    private func finish() {
        settings.dailyGoalMinutes = goalMinutes

        let picked = Self.suggestions.filter { chosen.contains($0.name) } + custom.map { (name: $0, emoji: "") }
        let existing = (try? context.fetchCount(FetchDescriptor<Subject>())) ?? 0
        for (index, item) in picked.enumerated() {
            let order = existing + index
            context.insert(Subject(
                name: item.name,
                emoji: item.emoji,
                colorHex: Palette.subjectHexes[order % Palette.subjectHexes.count],
                sortOrder: order
            ))
        }
        try? context.save()

        let time = Calendar.current.dateComponents([.hour, .minute], from: reminderTime)
        settings.dailyReminderMinutes = (time.hour ?? 19) * 60 + (time.minute ?? 0)
        settings.dailyReminderEnabled = reminderOn
        notifications.updateDailyReminder()

        settings.hasOnboarded = true
    }
}
