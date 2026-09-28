import SwiftData
import SwiftUI

struct SubjectsView: View {
    @Environment(\.modelContext) private var context
    @Query(sort: \Subject.sortOrder) private var subjects: [Subject]

    @State private var editing: Subject?
    @State private var showNew = false
    @State private var pendingDelete: Subject?

    var body: some View {
        let active = subjects.filter { !$0.isArchived }
        let archived = subjects.filter(\.isArchived)

        List {
            Section {
                ForEach(active) { subject in row(subject) }
                    .onMove { from, to in move(active, from: from, to: to) }
                Button {
                    showNew = true
                } label: {
                    Label("Add Subject", systemImage: "plus.circle.fill")
                }
            } footer: {
                Text("Tap to edit. Swipe to archive or delete. Archived subjects keep their history.")
            }

            if !archived.isEmpty {
                Section("Archived") {
                    ForEach(archived) { subject in row(subject) }
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Subjects")
        .toolbar { EditButton() }
        .sheet(item: $editing) { subject in SubjectEditor(subject: subject) }
        .sheet(isPresented: $showNew) { SubjectEditor(subject: nil) }
        .alert(
            "Delete \(pendingDelete?.name ?? "subject")?",
            isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } })
        ) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let subject = pendingDelete {
                    context.delete(subject)
                    try? context.save()
                }
                pendingDelete = nil
            }
        } message: {
            Text("Its sessions are kept but will show as “No subject”. Archive it instead to keep the tag.")
        }
    }

    private func row(_ subject: Subject) -> some View {
        Button {
            editing = subject
        } label: {
            HStack(spacing: 12) {
                Circle()
                    .fill(Palette.subjectColor(subject.colorHex))
                    .frame(width: 12, height: 12)
                Text(subject.label)
                    .foregroundStyle(subject.isArchived ? Palette.textSecondary : .white)
                Spacer()
                Text(subject.sessions.count == 1 ? "1 session" : "\(subject.sessions.count) sessions")
                    .font(.caption)
                    .foregroundStyle(Palette.textTertiary)
            }
        }
        .swipeActions(edge: .trailing) {
            Button(role: .destructive) {
                pendingDelete = subject
            } label: {
                Label("Delete", systemImage: "trash")
            }
            Button {
                subject.isArchived.toggle()
                try? context.save()
            } label: {
                Label(subject.isArchived ? "Unarchive" : "Archive", systemImage: "archivebox")
            }
            .tint(.orange)
        }
    }

    private func move(_ active: [Subject], from source: IndexSet, to destination: Int) {
        var reordered = active
        reordered.move(fromOffsets: source, toOffset: destination)
        for (index, subject) in reordered.enumerated() { subject.sortOrder = index }
        try? context.save()
    }
}

/// Create or edit a subject: name, emoji, and color.
struct SubjectEditor: View {
    let subject: Subject?
    var onSave: (UUID) -> Void = { _ in }

    @Environment(\.modelContext) private var context
    @Environment(\.dismiss) private var dismiss
    @Query(sort: \Subject.sortOrder) private var allSubjects: [Subject]

    @State private var name = ""
    @State private var emoji = ""
    @State private var colorHex = Palette.subjectHexes[0]
    @FocusState private var nameFocused: Bool

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    HStack(spacing: 14) {
                        TextField("📚", text: $emoji)
                            .font(.largeTitle)
                            .multilineTextAlignment(.center)
                            .frame(width: 60, height: 60)
                            .background(Palette.subjectColor(colorHex).opacity(0.18), in: RoundedRectangle(cornerRadius: 16, style: .continuous))
                            .onChange(of: emoji) { _, new in
                                if new.count > 1 { emoji = String(new.suffix(1)) }
                            }
                            .accessibilityLabel("Emoji")
                        TextField("Subject name", text: $name)
                            .font(.title3.weight(.semibold))
                            .focused($nameFocused)
                            .submitLabel(.done)
                            .onSubmit(save)
                    }
                    .padding(.vertical, 4)
                }

                Section("Color") {
                    HStack(spacing: 0) {
                        ForEach(Array(Palette.subjectHexes.enumerated()), id: \.element) { index, hex in
                            Button {
                                colorHex = hex
                            } label: {
                                Circle()
                                    .fill(Palette.subjectColor(hex))
                                    .frame(width: 30, height: 30)
                                    .padding(4)
                                    .overlay(Circle().stroke(.white, lineWidth: colorHex == hex ? 2.5 : 0))
                            }
                            .buttonStyle(.plain)
                            .frame(maxWidth: .infinity)
                            .accessibilityLabel("Color \(index + 1)")
                            .accessibilityAddTraits(colorHex == hex ? .isSelected : [])
                        }
                    }
                    .padding(.vertical, 6)
                }
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle(subject == nil ? "New Subject" : "Edit Subject")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save", action: save)
                        .disabled(trimmedName.isEmpty)
                }
            }
            .onAppear(perform: load)
        }
        .presentationDetents([.medium])
    }

    private var trimmedName: String {
        name.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func load() {
        if let subject {
            name = subject.name
            emoji = subject.emoji
            colorHex = subject.colorHex
        } else {
            let used = Set(allSubjects.map(\.colorHex))
            colorHex = Palette.subjectHexes.first { !used.contains($0) } ?? Palette.subjectHexes[allSubjects.count % Palette.subjectHexes.count]
            nameFocused = true
        }
    }

    private func save() {
        guard !trimmedName.isEmpty else { return }
        if let subject {
            subject.name = trimmedName
            subject.emoji = emoji
            subject.colorHex = colorHex
            try? context.save()
            onSave(subject.id)
        } else {
            let order = (allSubjects.map(\.sortOrder).max() ?? -1) + 1
            let new = Subject(name: trimmedName, emoji: emoji, colorHex: colorHex, sortOrder: order)
            context.insert(new)
            try? context.save()
            onSave(new.id)
        }
        dismiss()
    }
}
