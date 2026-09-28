import SwiftData
import SwiftUI

struct SessionDetailView: View {
    @Bindable var session: StudySession

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Subject.sortOrder) private var subjects: [Subject]
    @State private var confirmDelete = false

    var body: some View {
        List {
            Section {
                VStack(alignment: .leading, spacing: 14) {
                    Text(session.startedAt.formatted(date: .complete, time: .omitted))
                        .font(.caption.weight(.bold))
                        .textCase(.uppercase)
                        .foregroundStyle(Palette.textSecondary)
                    Text(DurationText.clock(session.lockedSeconds))
                        .font(.system(size: 52, weight: .bold, design: .rounded))
                        .monospacedDigit()
                    TimelineBar(
                        stretches: session.orderedSegments.map { DateInterval(start: $0.start, end: max($0.start, $0.end)) },
                        start: session.firstLockAt ?? session.startedAt,
                        end: session.endedAt
                    )
                }
                .padding(.vertical, 8)
            }

            Section("Details") {
                LabeledContent("Focus", value: session.focus.map { "\(Int(($0 * 100).rounded()))%" } ?? "–")
                LabeledContent("Unlocks", value: "\(session.unlockCount)")
                LabeledContent("Longest stretch", value: DurationText.short(session.longestStretch))
                if session.breakCount > 0 {
                    LabeledContent("Breaks", value: DurationText.breaks(count: session.breakCount, seconds: session.breakSeconds))
                }
                if session.leftAppCount > 0 {
                    LabeledContent("Left the app", value: session.leftAppCount == 1 ? "Once" : "\(session.leftAppCount) times")
                }
                if let target = session.targetSeconds {
                    LabeledContent("Target", value: "\(DurationText.short(target))\(session.lockedSeconds >= target ? " ✓" : "")")
                }
                LabeledContent(
                    "Time",
                    value: "\(session.startedAt.formatted(date: .omitted, time: .shortened)) – \(session.endedAt.formatted(date: .omitted, time: .shortened))"
                )
                if let why = session.endReason.explanation {
                    Text(why)
                        .font(.footnote)
                        .foregroundStyle(Palette.textSecondary)
                }
            }

            Section("Subject") {
                Picker("Subject", selection: $session.subject) {
                    Text("No subject").tag(Subject?.none)
                    ForEach(subjects) { subject in
                        Text(subject.label).tag(Subject?.some(subject))
                    }
                }
            }

            Section("Note") {
                TextField("What did you work on?", text: $session.note, axis: .vertical)
                    .lineLimit(2...6)
            }

            Section {
                Button("Delete Session", role: .destructive) { confirmDelete = true }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Session")
        .navigationBarTitleDisplayMode(.inline)
        .onDisappear { try? context.save() }
        .alert("Delete this session?", isPresented: $confirmDelete) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive, action: delete)
        } message: {
            Text("It will be removed from your stats and streak.")
        }
    }

    private func delete() {
        let doomed = session
        dismiss()
        // Delete after navigating away so the screen never reads a deleted model.
        Task {
            try? await Task.sleep(for: .milliseconds(400))
            context.delete(doomed)
            try? context.save()
        }
    }
}
