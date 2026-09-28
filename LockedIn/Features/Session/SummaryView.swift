import SwiftData
import SwiftUI

/// Shown when a session ends.
struct SummaryView: View {
    let summary: SessionSummary

    @Environment(\.dismiss) private var dismiss
    @Environment(\.modelContext) private var context
    @Environment(AppSettings.self) private var settings
    @State private var note = ""
    @State private var confirmDiscard = false
    @State private var discarded = false
    @State private var appeared = false

    private var finished: FinishedSession { summary.session }
    private var saved: Bool { summary.savedSessionID != nil }

    var body: some View {
        ScrollView {
            VStack(spacing: 22) {
                hero
                if let explanation = finished.reason.explanation {
                    Label(explanation, systemImage: "info.circle.fill")
                        .font(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                        .card(padding: 14)
                }
                if saved {
                    statsGrid
                    timeline
                    TextField("Add a note: what did you work on?", text: $note, axis: .vertical)
                        .lineLimit(1...4)
                        .card(padding: 14)
                } else {
                    Text("Sessions under a minute aren't saved. Lock in a little longer next time!")
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .multilineTextAlignment(.center)
                }
            }
            .padding(20)
        }
        .scrollIndicators(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .safeAreaInset(edge: .bottom) { buttons }
        .presentationDragIndicator(.visible)
        .onAppear { appeared = true }
        .onDisappear(perform: saveNote)
        .haptic(.success, trigger: appeared, enabled: settings.hapticsEnabled && saved)
        .alert("Discard this session?", isPresented: $confirmDiscard) {
            Button("Cancel", role: .cancel) {}
            Button("Discard", role: .destructive, action: discard)
        } message: {
            Text("It won't count toward your stats or streak.")
        }
    }

    // MARK: Pieces

    private var hero: some View {
        VStack(spacing: 10) {
            Image(systemName: saved ? "checkmark.seal.fill" : "hourglass")
                .font(.system(size: 44, weight: .semibold))
                .foregroundStyle(saved ? Palette.accent : Palette.textSecondary)
                .frame(width: 96, height: 96)
                .background((saved ? Palette.accent : Color.white).opacity(0.12), in: Circle())
                .symbolEffect(.bounce, value: appeared)
                .padding(.top, 12)

            Text(title)
                .font(.title2.weight(.bold))
                .fontDesign(.rounded)

            Text(DurationText.clock(finished.lockedSeconds))
                .font(.system(size: 64, weight: .bold, design: .rounded))
                .monospacedDigit()
                .foregroundStyle(saved ? .white : Palette.textSecondary)

            Text(subtitle)
                .font(.subheadline)
                .foregroundStyle(Palette.textSecondary)
        }
    }

    private var title: String {
        guard saved else { return "Too short to save" }
        if let target = finished.targetSeconds, finished.lockedSeconds >= target { return "Target smashed 🎯" }
        return finished.reason == .manual ? "Session complete" : "Session ended"
    }

    private var subtitle: String {
        let subject = summary.subject.map { " · \($0.emoji.isEmpty ? $0.name : "\($0.emoji) \($0.name)")" } ?? ""
        return "locked in\(subject)"
    }

    private var statsGrid: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatTile(title: "Focus", value: finished.focus.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", systemImage: "scope")
            StatTile(title: "Unlocks", value: "\(finished.unlockCount)", systemImage: "lock.open.fill", tint: Palette.paused)
            StatTile(title: "Longest stretch", value: DurationText.short(finished.longestStretch), systemImage: "timer")
            if let target = finished.targetSeconds {
                StatTile(
                    title: "Target",
                    value: finished.lockedSeconds >= target ? "Hit ✓" : "\(Int((finished.lockedSeconds / target * 100).rounded()))%",
                    systemImage: "target",
                    tint: Palette.streak
                )
            } else {
                StatTile(title: "Session", value: DurationText.short(finished.endedAt.timeIntervalSince(finished.startedAt)), systemImage: "clock", tint: Palette.streak)
            }
        }
    }

    private var timeline: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                SectionHeader(title: "Timeline")
                HStack(spacing: 12) {
                    legend(Palette.accent, "Locked")
                    legend(Color.white.opacity(0.15), "Unlocked")
                }
            }
            TimelineBar(
                stretches: finished.stretches.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
                start: finished.firstLockAt ?? finished.startedAt,
                end: finished.endedAt
            )
            if finished.breakCount > 0 {
                Label(DurationText.breaks(count: finished.breakCount, seconds: finished.breakSeconds), systemImage: "pause.fill")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.onBreak)
            }
        }
        .card()
    }

    private func legend(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label).font(.caption2).foregroundStyle(Palette.textTertiary)
        }
    }

    private var buttons: some View {
        VStack(spacing: 6) {
            Button("Done") { dismiss() }
                .buttonStyle(PrimaryButtonStyle())
            if saved {
                Button("Discard session", role: .destructive) { confirmDiscard = true }
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(Palette.danger)
                    .padding(.vertical, 8)
            }
        }
        .padding(.horizontal, 20)
        .padding(.top, 10)
        .padding(.bottom, 4)
        .background(Palette.background)
    }

    // MARK: Actions

    private func savedSession() -> StudySession? {
        guard let id = summary.savedSessionID else { return nil }
        var descriptor = FetchDescriptor<StudySession>(predicate: #Predicate { $0.id == id })
        descriptor.fetchLimit = 1
        return try? context.fetch(descriptor).first
    }

    private func saveNote() {
        let trimmed = note.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !discarded, !trimmed.isEmpty, let session = savedSession() else { return }
        session.note = trimmed
        try? context.save()
    }

    private func discard() {
        if let session = savedSession() {
            context.delete(session)
            try? context.save()
        }
        discarded = true
        dismiss()
    }
}
