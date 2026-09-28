import Charts
import SwiftData
import SwiftUI

struct HomeView: View {
    let showStats: () -> Void
    @Environment(SessionEngine.self) private var engine

    var body: some View {
        NavigationStack {
            ZStack {
                Palette.background.ignoresSafeArea()
                if let session = engine.session {
                    ActiveSessionView(session: session)
                        .transition(.opacity.combined(with: .scale(scale: 0.98)))
                } else {
                    IdleHomeView(showStats: showStats)
                        .transition(.opacity)
                }
            }
            .animation(.easeInOut(duration: 0.3), value: engine.session == nil)
            .toolbar(.hidden, for: .navigationBar)
        }
    }
}

/// Home when no session is running: today's progress and the Lock In button.
private struct IdleHomeView: View {
    let showStats: () -> Void

    @Environment(SessionEngine.self) private var engine
    @Environment(AppSettings.self) private var settings
    @Query(filter: #Predicate<Subject> { !$0.isArchived }, sort: \Subject.sortOrder) private var subjects: [Subject]
    @Query private var sessions: [StudySession]

    @State private var subjectID: UUID?
    @State private var targetMinutes = 0
    @State private var didLoadDefaults = false
    @State private var showSettings = false
    @State private var showNewSubject = false
    @State private var showCustomTarget = false
    @State private var startCount = 0

    private static let targetPresets = [0, 25, 50, 90, 120]

    var body: some View {
        let data = StudyData(sessions: sessions, active: nil, calendar: settings.statsCalendar)
        let streak = data.streaks(goal: settings.dailyGoal)

        ScrollView {
            VStack(spacing: 24) {
                header(streak: streak.current)
                TodayCard(seconds: data.todaySeconds, goal: settings.dailyGoal)
                subjectPicker
                targetPicker
                lockInButton
                Button(action: showStats) {
                    WeekCard(data: data, goal: settings.dailyGoal)
                }
                .buttonStyle(.plain)
            }
            .padding(.horizontal, 20)
            .padding(.top, 8)
            .padding(.bottom, 32)
        }
        .scrollIndicators(.hidden)
        .sheet(isPresented: $showSettings) { SettingsView() }
        .sheet(isPresented: $showNewSubject) {
            SubjectEditor(subject: nil) { subjectID = $0 }
        }
        .sheet(isPresented: $showCustomTarget) {
            CustomTargetSheet(minutes: $targetMinutes)
        }
        .onAppear(perform: loadDefaults)
        .haptic(.impact(weight: .medium), trigger: startCount, enabled: settings.hapticsEnabled)
    }

    // MARK: Sections

    private func header(streak: Int) -> some View {
        HStack(alignment: .center, spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(Date.now.formatted(.dateTime.weekday(.wide).month(.wide).day()).uppercased())
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.textSecondary)
                Text("Ready to lock in?")
                    .font(.title.weight(.bold))
                    .fontDesign(.rounded)
            }
            Spacer(minLength: 8)
            StreakBadge(days: streak)
            Button {
                showSettings = true
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(Palette.textSecondary)
                    .frame(width: 38, height: 38)
                    .background(Palette.surface, in: Circle())
                    .overlay(Circle().stroke(Palette.stroke))
            }
            .accessibilityLabel("Settings")
        }
    }

    private var subjectPicker: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Studying")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    Chip(title: "Anything", isSelected: subjectID == nil) { subjectID = nil }
                    ForEach(subjects) { subject in
                        Chip(
                            title: subject.label,
                            isSelected: subjectID == subject.id,
                            tint: Palette.subjectColor(subject.colorHex)
                        ) { subjectID = subject.id }
                    }
                    Button {
                        showNewSubject = true
                    } label: {
                        Image(systemName: "plus")
                            .font(.subheadline.weight(.bold))
                            .foregroundStyle(Palette.textSecondary)
                            .frame(width: 38, height: 38)
                            .background(Palette.surface, in: Circle())
                            .overlay(Circle().stroke(Palette.stroke))
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("Add subject")
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var targetPicker: some View {
        let isCustom = !Self.targetPresets.contains(targetMinutes)
        return VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Session length")
            ScrollView(.horizontal) {
                HStack(spacing: 8) {
                    ForEach(Self.targetPresets, id: \.self) { minutes in
                        Chip(
                            title: minutes == 0 ? "Open" : DurationText.short(TimeInterval(minutes * 60)),
                            isSelected: targetMinutes == minutes
                        ) { targetMinutes = minutes }
                    }
                    Chip(
                        title: isCustom ? DurationText.short(TimeInterval(targetMinutes * 60)) : "Custom",
                        isSelected: isCustom
                    ) { showCustomTarget = true }
                }
                .padding(.vertical, 2)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }

    private var lockInButton: some View {
        VStack(spacing: 10) {
            Button(action: start) {
                Label("Lock In", systemImage: "lock.fill")
            }
            .buttonStyle(PrimaryButtonStyle())

            Text(targetMinutes == 0
                 ? "The timer only runs while your phone is locked."
                 : "Target \(DurationText.short(TimeInterval(targetMinutes * 60))). The timer only runs while your phone is locked.")
                .font(.footnote)
                .foregroundStyle(Palette.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, 4)
    }

    // MARK: Actions

    private func start() {
        settings.lastSubjectID = subjectID
        engine.start(subjectID: subjectID, targetSeconds: targetMinutes > 0 ? TimeInterval(targetMinutes * 60) : nil)
        startCount += 1
    }

    private func loadDefaults() {
        guard !didLoadDefaults else { return }
        didLoadDefaults = true
        targetMinutes = settings.defaultTargetMinutes
        if let last = settings.lastSubjectID, subjects.contains(where: { $0.id == last }) {
            subjectID = last
        }
    }
}

// MARK: - Cards

private struct TodayCard: View {
    let seconds: TimeInterval
    let goal: TimeInterval

    var body: some View {
        let progress = goal > 0 ? seconds / goal : 0
        HStack(spacing: 20) {
            ZStack {
                ProgressRing(progress: progress, lineWidth: 14)
                VStack(spacing: 0) {
                    Text("\(Int((min(progress, 9.99) * 100).rounded()))%")
                        .font(.title2.weight(.bold))
                        .fontDesign(.rounded)
                        .monospacedDigit()
                    Text("of goal")
                        .font(.caption2)
                        .foregroundStyle(Palette.textSecondary)
                }
            }
            .frame(width: 116, height: 116)

            VStack(alignment: .leading, spacing: 6) {
                Text("TODAY")
                    .font(.caption.weight(.bold))
                    .tracking(1.2)
                    .foregroundStyle(Palette.textSecondary)
                Text(DurationText.short(seconds))
                    .font(.system(size: 40, weight: .bold, design: .rounded))
                    .monospacedDigit()
                    .lineLimit(1)
                    .minimumScaleFactor(0.6)
                Text(seconds >= goal
                     ? "Daily goal hit ✓"
                     : "\(DurationText.short(goal - seconds)) to go · goal \(DurationText.short(goal))")
                    .font(.subheadline.weight(seconds >= goal ? .semibold : .regular))
                    .foregroundStyle(seconds >= goal ? Palette.accent : Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .card(padding: 20)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Today: \(DurationText.spoken(seconds)) locked in of a \(DurationText.spoken(goal)) goal")
    }
}

private struct WeekCard: View {
    let data: StudyData
    let goal: TimeInterval

    var body: some View {
        let stats = PeriodStats(data: data, range: .week, offset: 0, goal: goal, subjects: [:])
        let peak = max(stats.buckets.map(\.minutes).max() ?? 0, goal / 60, 1)

        VStack(alignment: .leading, spacing: 14) {
            HStack {
                SectionHeader(title: "This week", trailing: DurationText.short(stats.total))
                Image(systemName: "chevron.right")
                    .font(.caption.weight(.bold))
                    .foregroundStyle(Palette.textTertiary)
            }
            Chart(stats.buckets) { bucket in
                BarMark(
                    x: .value("Day", bucket.date, unit: .day),
                    y: .value("Minutes", bucket.seconds > 0 ? bucket.minutes : peak * 0.03)
                )
                .foregroundStyle(barColor(bucket))
                .cornerRadius(5)
            }
            .chartYScale(domain: 0...peak)
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .day)) { _ in
                    AxisValueLabel(format: .dateTime.weekday(.narrow), centered: true)
                }
            }
            .frame(height: 96)
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("This week: \(DurationText.spoken(stats.total)) locked in. Opens stats.")
    }

    private func barColor(_ bucket: ChartBucket) -> Color {
        if bucket.seconds == 0 { return Color.white.opacity(0.1) }
        return bucket.seconds >= goal ? Palette.accent : Palette.accent.opacity(0.45)
    }
}

// MARK: - Custom target

private struct CustomTargetSheet: View {
    @Binding var minutes: Int
    @Environment(\.dismiss) private var dismiss
    @State private var hours = 1
    @State private var mins = 0

    var body: some View {
        NavigationStack {
            HStack(spacing: 0) {
                Picker("Hours", selection: $hours) {
                    ForEach(0..<9) { Text("\($0) hr").tag($0) }
                }
                Picker("Minutes", selection: $mins) {
                    ForEach(Array(stride(from: 0, to: 60, by: 5)), id: \.self) { Text("\($0) min").tag($0) }
                }
            }
            .pickerStyle(.wheel)
            .padding(.horizontal)
            .navigationTitle("Session length")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Set") {
                        minutes = hours * 60 + mins
                        dismiss()
                    }
                    .disabled(hours == 0 && mins == 0)
                }
            }
        }
        .presentationDetents([.height(320)])
        .onAppear {
            if minutes > 0 {
                hours = minutes / 60
                mins = (minutes % 60) / 5 * 5
            }
        }
    }
}
