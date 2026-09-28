import SwiftData
import SwiftUI

struct HistoryView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionEngine.self) private var engine
    @Environment(\.modelContext) private var context
    @Query(sort: \StudySession.startedAt, order: .reverse) private var sessions: [StudySession]

    @State private var monthOffset = 0
    @State private var selectedDay: Date?

    var body: some View {
        let calendar = settings.statsCalendar
        let data = StudyData(sessions: sessions, active: engine.session, calendar: calendar)
        let month = monthStart(today: data.today, calendar: calendar.calendar)
        let day = selectedDay ?? (monthOffset == 0 ? data.today : month)
        let daySessions = sessions.filter { calendar.day(for: $0.startedAt) == day }
        let monthTotal = data.daily.filter { calendar.calendar.isDate($0.key, equalTo: month, toGranularity: .month) }.values.reduce(0, +)

        NavigationStack {
            List {
                Section {
                    VStack(spacing: 16) {
                        MonthHeader(
                            month: month,
                            total: monthTotal,
                            canGoForward: monthOffset < 0,
                            back: { changeMonth(by: -1) },
                            forward: { changeMonth(by: 1) }
                        )
                        CalendarHeatmap(
                            month: month,
                            daily: data.daily,
                            goal: settings.dailyGoal,
                            today: data.today,
                            selected: day,
                            calendar: calendar
                        ) { selectedDay = $0 }
                    }
                    .padding(.vertical, 8)
                }
                .listRowBackground(Palette.surface)

                Section {
                    if daySessions.isEmpty {
                        Text(day == data.today ? "No sessions yet today. Go lock in!" : "No sessions this day.")
                            .foregroundStyle(Palette.textSecondary)
                    } else {
                        ForEach(daySessions) { session in
                            NavigationLink {
                                SessionDetailView(session: session)
                            } label: {
                                SessionRow(session: session)
                            }
                        }
                        .onDelete { offsets in
                            for index in offsets { context.delete(daySessions[index]) }
                            try? context.save()
                        }
                    }
                } header: {
                    HStack {
                        Text(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
                        Spacer()
                        Text(DurationText.short(data.daily[day] ?? 0))
                            .monospacedDigit()
                    }
                }
                .listRowBackground(Palette.surface)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("History")
        }
    }

    private func monthStart(today: Date, calendar: Calendar) -> Date {
        let current = calendar.dateInterval(of: .month, for: today)?.start ?? today
        return calendar.date(byAdding: .month, value: monthOffset, to: current) ?? current
    }

    private func changeMonth(by delta: Int) {
        withAnimation(.easeInOut(duration: 0.2)) {
            monthOffset += delta
            selectedDay = nil
        }
    }
}

// MARK: - Month header

private struct MonthHeader: View {
    let month: Date
    let total: TimeInterval
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 2) {
                Text(month.formatted(.dateTime.month(.wide).year()))
                    .font(.title3.weight(.bold))
                    .fontDesign(.rounded)
                Text("\(DurationText.short(total)) locked in")
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            HStack(spacing: 8) {
                arrow("chevron.left", label: "Previous month", enabled: true, action: back)
                arrow("chevron.right", label: "Next month", enabled: canGoForward, action: forward)
            }
        }
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.subheadline.weight(.semibold))
                .frame(width: 34, height: 34)
                .background(Palette.surfaceRaised, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .white : Palette.textTertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Heatmap

/// A month grid where brighter days mean more time locked in; a dot marks days that hit the goal.
struct CalendarHeatmap: View {
    let month: Date
    let daily: [Date: TimeInterval]
    let goal: TimeInterval
    let today: Date
    let selected: Date
    let calendar: StatsCalendar
    let onSelect: (Date) -> Void

    var body: some View {
        let cal = calendar.calendar
        let end = cal.date(byAdding: .month, value: 1, to: month) ?? month
        let days = calendar.days(from: month, to: end)
        let leading = (cal.component(.weekday, from: month) - cal.firstWeekday + 7) % 7
        let symbols = weekdaySymbols(cal)
        let columns = Array(repeating: GridItem(.flexible(), spacing: 6), count: 7)

        VStack(spacing: 8) {
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array(symbols.enumerated()), id: \.offset) { _, symbol in
                    Text(symbol)
                        .font(.caption2.weight(.bold))
                        .foregroundStyle(Palette.textTertiary)
                }
            }
            LazyVGrid(columns: columns, spacing: 6) {
                ForEach(Array((-leading)..<0), id: \.self) { _ in
                    Color.clear.frame(height: 40)
                }
                ForEach(days, id: \.self) { day in
                    Button { onSelect(day) } label: { cell(day, cal) }
                        .buttonStyle(.plain)
                        .disabled(day > today)
                }
            }
            legend
        }
    }

    private func cell(_ day: Date, _ cal: Calendar) -> some View {
        let seconds = daily[day] ?? 0
        let intensity = goal > 0 ? min(seconds / goal, 1) : (seconds > 0 ? 1 : 0)
        let isFuture = day > today
        let isBright = seconds > 0 && intensity > 0.55
        let metGoal = goal > 0 && seconds >= goal

        return ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(seconds > 0 ? Palette.accent.opacity(0.18 + 0.82 * intensity) : Color.white.opacity(isFuture ? 0.02 : 0.05))
            Text("\(cal.component(.day, from: day))")
                .font(.footnote.weight(.semibold))
                .monospacedDigit()
                .foregroundStyle(isBright ? Palette.onAccent : (isFuture ? Palette.textTertiary : .white))
        }
        .frame(height: 40)
        .overlay(alignment: .bottom) {
            if metGoal {
                Circle()
                    .fill(isBright ? Palette.onAccent : Palette.accent)
                    .frame(width: 4, height: 4)
                    .padding(.bottom, 4)
            }
        }
        .overlay {
            if day == selected {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(.white, lineWidth: 2)
            } else if day == today {
                RoundedRectangle(cornerRadius: 10, style: .continuous).stroke(Palette.accent, lineWidth: 1.5)
            }
        }
        .contentShape(Rectangle())
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(day.formatted(.dateTime.weekday(.wide).month(.wide).day()))
        .accessibilityValue(seconds > 0 ? "\(DurationText.spoken(seconds))\(metGoal ? ", goal met" : "")" : "No sessions")
        .accessibilityAddTraits(day == selected ? .isSelected : [])
    }

    private var legend: some View {
        HStack(spacing: 6) {
            Text("Less")
            ForEach([0.0, 0.3, 0.6, 1.0], id: \.self) { level in
                RoundedRectangle(cornerRadius: 3)
                    .fill(level == 0 ? Color.white.opacity(0.05) : Palette.accent.opacity(0.18 + 0.82 * level))
                    .frame(width: 12, height: 12)
            }
            Text("More")
            Spacer()
            Circle().fill(Palette.accent).frame(width: 5, height: 5)
            Text("Goal met")
        }
        .font(.caption2)
        .foregroundStyle(Palette.textTertiary)
        .padding(.top, 4)
    }

    private func weekdaySymbols(_ cal: Calendar) -> [String] {
        let symbols = cal.veryShortStandaloneWeekdaySymbols
        let first = cal.firstWeekday - 1
        return Array(symbols[first...] + symbols[..<first])
    }
}

// MARK: - Row

struct SessionRow: View {
    let session: StudySession

    var body: some View {
        HStack(spacing: 12) {
            RoundedRectangle(cornerRadius: 2)
                .fill(Palette.subjectColor(session.subject?.colorHex))
                .frame(width: 4, height: 38)
            VStack(alignment: .leading, spacing: 3) {
                Text(session.subject?.label ?? "Session")
                    .font(.headline)
                    .lineLimit(1)
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            Text(DurationText.short(session.lockedSeconds))
                .font(.headline)
                .fontDesign(.rounded)
                .monospacedDigit()
        }
        .padding(.vertical, 2)
    }

    private var detail: String {
        let times = "\(session.startedAt.formatted(date: .omitted, time: .shortened)) – \(session.endedAt.formatted(date: .omitted, time: .shortened))"
        let unlocks = session.unlockCount == 1 ? "1 unlock" : "\(session.unlockCount) unlocks"
        return "\(times) · \(unlocks)"
    }
}
