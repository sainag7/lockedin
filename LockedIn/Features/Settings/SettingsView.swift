import SwiftData
import SwiftUI

struct SettingsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(NotificationScheduler.self) private var notifications
    @Environment(SessionEngine.self) private var engine
    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Environment(\.openURL) private var openURL
    @Query(sort: \StudySession.startedAt) private var sessions: [StudySession]

    @State private var confirmDeleteAll = false
    @State private var showHowItWorks = false

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            Form {
                Section("Goals") {
                    Picker("Daily goal", selection: $settings.dailyGoalMinutes) {
                        ForEach([30, 60, 90, 120, 180, 240, 300, 360], id: \.self) { minutes in
                            Text(DurationText.short(TimeInterval(minutes * 60))).tag(minutes)
                        }
                    }
                    Picker("Default session length", selection: $settings.defaultTargetMinutes) {
                        Text("Open").tag(0)
                        ForEach([25, 50, 90, 120], id: \.self) { minutes in
                            Text(DurationText.short(TimeInterval(minutes * 60))).tag(minutes)
                        }
                    }
                    NavigationLink("Subjects") { SubjectsView() }
                }

                Section {
                    Toggle("Track locks in any app", isOn: $settings.trackLocksAnywhere)
                } header: {
                    Text("Tracking")
                } footer: {
                    Text("During a session, LockedIn keeps running quietly in the background, so locking and unlocking count whatever app you're in. Uses a little extra battery. Turn it off to count only locks made from inside LockedIn.")
                }

                Section {
                    Picker("Focus sound", selection: $settings.backgroundSound) {
                        ForEach(BackgroundSound.allCases, id: \.self) { sound in
                            Text(sound.name).tag(sound)
                        }
                    }
                    if settings.backgroundSound != .none {
                        HStack(spacing: 12) {
                            Image(systemName: "speaker.fill").foregroundStyle(Palette.textSecondary)
                            Slider(value: $settings.soundVolume, in: 0...1)
                            Image(systemName: "speaker.wave.3.fill").foregroundStyle(Palette.textSecondary)
                        }
                    }
                } header: {
                    Text("Sounds")
                } footer: {
                    Text("Play focus noise while you're locked in. Dark is deep brown noise, Balanced is pink, Bright is white. You can also pick it from the speaker button on the session screen.")
                }

                Section {
                    Picker("Auto-end after", selection: $settings.autoEndHours) {
                        Text("Never").tag(0)
                        ForEach([1, 2, 3, 4, 6], id: \.self) { hours in
                            Text("\(hours) hr locked").tag(hours)
                        }
                    }
                    Picker("New day starts at", selection: $settings.dayStartHour) {
                        ForEach(0...4, id: \.self) { hour in
                            Text(hour == 0 ? "Midnight" : "\(hour) AM").tag(hour)
                        }
                    }
                } header: {
                    Text("Sessions")
                } footer: {
                    Text("Auto-end stops a session you forgot about, like falling asleep with your phone locked. Night owl? Move the start of your day so late sessions count toward the day before.")
                }

                Section {
                    if notifications.authorization == .denied {
                        Button {
                            if let url = URL(string: UIApplication.openSettingsURLString) { openURL(url) }
                        } label: {
                            Label("Notifications are off. Turn them on in Settings.", systemImage: "bell.slash.fill")
                                .foregroundStyle(Palette.paused)
                        }
                    }
                    Toggle("Target reached", isOn: $settings.notifyTarget)
                    Toggle("Daily goal reached", isOn: $settings.notifyDailyGoal)
                    Toggle("Left LockedIn mid-session", isOn: $settings.notifyLeftApp)
                    Picker("Break reminder", selection: $settings.breakNudgeMinutes) {
                        Text("Off").tag(0)
                        ForEach([2, 5, 10, 15], id: \.self) { minutes in
                            Text("After \(minutes) min").tag(minutes)
                        }
                    }
                    Toggle("Daily reminder", isOn: $settings.dailyReminderEnabled)
                    if settings.dailyReminderEnabled {
                        DatePicker("Remind me at", selection: reminderTime, displayedComponents: .hourAndMinute)
                    }
                } header: {
                    Text("Notifications")
                }

                Section("Feel") {
                    Toggle("Haptics", isOn: $settings.hapticsEnabled)
                }

                Section {
                    ShareLink(
                        item: SessionsCSV(text: CSVExporter.csv(for: sessions)),
                        preview: SharePreview("LockedIn sessions")
                    ) {
                        Label("Export sessions (CSV)", systemImage: "square.and.arrow.up")
                    }
                    .disabled(sessions.isEmpty)
                    Button(role: .destructive) {
                        confirmDeleteAll = true
                    } label: {
                        Label("Delete all sessions", systemImage: "trash")
                            .foregroundStyle(Palette.danger)
                    }
                    .disabled(sessions.isEmpty)
                } header: {
                    Text("Your data")
                } footer: {
                    Text("Everything stays on this iPhone. No account, no servers.")
                }

                Section("Help") {
                    Button("How LockedIn works") { showHowItWorks = true }
                    NavigationLink("Diagnostics") { DiagnosticsView() }
                }

                #if DEBUG
                Section("Developer") {
                    Button("Load 60 days of sample data") {
                        SampleData.load(into: context, calendar: settings.statsCalendar)
                    }
                    Button("Replay onboarding") {
                        dismiss()
                        settings.hasOnboarded = false
                    }
                }
                #endif

                Section {
                    LabeledContent("Version", value: version)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
            .sheet(isPresented: $showHowItWorks) { HowItWorksView() }
            .alert("Delete all sessions?", isPresented: $confirmDeleteAll) {
                Button("Cancel", role: .cancel) {}
                Button("Delete \(sessions.count) sessions", role: .destructive, action: deleteAll)
            } message: {
                Text("This clears your history, stats and streak. Subjects are kept. This can't be undone.")
            }
            .task { await notifications.refreshAuthorization() }
            .onChange(of: settings.dailyReminderEnabled) { _, enabled in
                Task {
                    if enabled { await notifications.requestAuthorization() }
                    notifications.updateDailyReminder()
                }
            }
            .onChange(of: settings.dailyReminderMinutes) { notifications.updateDailyReminder() }
            .onChange(of: settings.trackLocksAnywhere) { engine.trackingSettingChanged() }
            .onChange(of: settings.backgroundSound) { engine.soundSettingChanged() }
            .onChange(of: settings.soundVolume) { engine.soundSettingChanged() }
        }
    }

    private var reminderTime: Binding<Date> {
        Binding(
            get: {
                Calendar.current.date(
                    bySettingHour: settings.dailyReminderMinutes / 60,
                    minute: settings.dailyReminderMinutes % 60,
                    second: 0,
                    of: .now
                ) ?? .now
            },
            set: { date in
                let parts = Calendar.current.dateComponents([.hour, .minute], from: date)
                settings.dailyReminderMinutes = (parts.hour ?? 19) * 60 + (parts.minute ?? 0)
            }
        )
    }

    private var version: String {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "1.0"
        let build = info?["CFBundleVersion"] as? String ?? "1"
        return "\(short) (\(build))"
    }

    private func deleteAll() {
        for session in sessions { context.delete(session) }
        try? context.save()
    }
}
