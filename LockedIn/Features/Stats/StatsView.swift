import Charts
import SwiftData
import SwiftUI

struct StatsView: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionEngine.self) private var engine
    @Query private var sessions: [StudySession]
    @Query private var subjects: [Subject]

    @State private var range: StatsRange = .week
    @State private var offset = 0
    @State private var selectedDate: Date?

    var body: some View {
        let data = StudyData(sessions: sessions, active: engine.session, calendar: settings.statsCalendar)
        let infos = Dictionary(subjects.map { ($0.id, $0.info) }, uniquingKeysWith: { first, _ in first })
        let stats = PeriodStats(data: data, range: range, offset: offset, goal: settings.dailyGoal, subjects: infos)
        let streaks = data.streaks(goal: settings.dailyGoal)

        NavigationStack {
            ScrollView {
                VStack(spacing: 14) {
                    Picker("Range", selection: $range) {
                        ForEach(StatsRange.allCases) { Text($0.title).tag($0) }
                    }
                    .pickerStyle(.segmented)

                    PeriodNavigator(
                        title: stats.title,
                        subtitle: stats.subtitle,
                        canGoForward: offset < 0,
                        back: { offset -= 1 },
                        forward: { offset += 1 }
                    )

                    if data.segments.isEmpty {
                        ContentUnavailableView {
                            Label("No sessions yet", systemImage: "chart.bar.xaxis")
                        } description: {
                            Text("Lock in for a session and your trends will show up here.")
                        }
                        .padding(.top, 40)
                    } else {
                        TotalCard(stats: stats, goal: settings.dailyGoal, selectedDate: $selectedDate)
                        StatTiles(stats: stats)
                        StreakCard(streaks: streaks, goal: settings.dailyGoal)
                        if !stats.insights.isEmpty { InsightsCard(lines: stats.insights) }
                        if !stats.subjects.isEmpty { SubjectsCard(stats: stats) }
                        if stats.total > 0 { HoursCard(hours: stats.hours) }
                    }
                }
                .padding(.horizontal, 20)
                .padding(.bottom, 32)
            }
            .scrollIndicators(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Stats")
            .onChange(of: range) {
                offset = 0
                selectedDate = nil
            }
            .onChange(of: offset) { selectedDate = nil }
        }
    }
}

// MARK: - Header

private struct PeriodNavigator: View {
    let title: String
    let subtitle: String
    let canGoForward: Bool
    let back: () -> Void
    let forward: () -> Void

    var body: some View {
        HStack {
            arrow("chevron.left", label: "Previous", enabled: true, action: back)
            Spacer()
            VStack(spacing: 2) {
                Text(title)
                    .font(.headline)
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer()
            arrow("chevron.right", label: "Next", enabled: canGoForward, action: forward)
        }
        .padding(.vertical, 4)
    }

    private func arrow(_ symbol: String, label: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.body.weight(.semibold))
                .frame(width: 40, height: 40)
                .background(Palette.surface, in: Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(enabled ? .white : Palette.textTertiary)
        .disabled(!enabled)
        .accessibilityLabel(label)
    }
}

// MARK: - Total + bars

private struct TotalCard: View {
    let stats: PeriodStats
    let goal: TimeInterval
    @Binding var selectedDate: Date?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("LOCKED IN")
                        .font(.caption.weight(.bold))
                        .tracking(1.2)
                        .foregroundStyle(Palette.textSecondary)
                    Text(DurationText.short(stats.total))
                        .font(.system(size: 40, weight: .bold, design: .rounded))
                        .monospacedDigit()
                }
                Spacer()
                ChangeBadge(total: stats.total, previous: stats.previousTotal)
            }
            PeriodBarsChart(stats: stats, goal: goal, selectedDate: $selectedDate)
        }
        .card(padding: 18)
    }
}

private struct ChangeBadge: View {
    let total: TimeInterval
    let previous: TimeInterval

    var body: some View {
        if previous > 0 {
            let change = (total - previous) / previous
            let up = change >= 0
            Label("\(Int((abs(change) * 100).rounded()))%", systemImage: up ? "arrow.up.right" : "arrow.down.right")
                .font(.subheadline.weight(.bold))
                .foregroundStyle(up ? Palette.accent : Palette.paused)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background((up ? Palette.accent : Palette.paused).opacity(0.14), in: Capsule())
                .accessibilityLabel("\(up ? "Up" : "Down") \(Int((abs(change) * 100).rounded())) percent")
        }
    }
}

private struct PeriodBarsChart: View {
    let stats: PeriodStats
    let goal: TimeInterval
    @Binding var selectedDate: Date?

    private var unit: Calendar.Component { stats.range == .year ? .month : .day }
    private var showGoal: Bool { stats.range != .year && goal > 0 }

    var body: some View {
        let selected = selectedBucket
        let peak = max(stats.buckets.map(\.minutes).max() ?? 0, showGoal ? goal / 60 : 0, 1)
        let step = Self.tickStep(forPeakMinutes: peak)
        let top = (peak * 1.08 / step).rounded(.up) * step

        VStack(alignment: .leading, spacing: 12) {
            chart(selected: selected, step: step, top: top)
            if showGoal { legend }
        }
    }

    private func chart(selected: ChartBucket?, step: Double, top: Double) -> some View {
        Chart {
            ForEach(stats.buckets) { bucket in
                BarMark(
                    x: .value("Date", bucket.date, unit: unit),
                    y: .value("Minutes", bucket.minutes)
                )
                .foregroundStyle(color(for: bucket))
                .cornerRadius(stats.range == .month ? 3 : 6)
                .opacity(selected == nil || selected?.date == bucket.date ? 1 : 0.35)
                .accessibilityLabel(label(for: bucket.date))
                .accessibilityValue(DurationText.spoken(bucket.seconds))
            }
            if showGoal {
                RuleMark(y: .value("Goal", goal / 60))
                    .lineStyle(StrokeStyle(lineWidth: 1, dash: [4, 4]))
                    .foregroundStyle(Color.white.opacity(0.4))
            }
            if let selected {
                RuleMark(x: .value("Selected", selected.date, unit: unit))
                    .foregroundStyle(Color.white.opacity(0.12))
                    .zIndex(-1)
                    .annotation(position: .top, spacing: 4, overflowResolution: .init(x: .fit(to: .chart), y: .disabled)) {
                        VStack(spacing: 2) {
                            Text(label(for: selected.date))
                                .font(.caption2)
                                .foregroundStyle(Palette.textSecondary)
                            Text(DurationText.short(selected.seconds))
                                .font(.subheadline.weight(.bold))
                                .fontDesign(.rounded)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Palette.surfaceRaised, in: RoundedRectangle(cornerRadius: 10, style: .continuous))
                    }
            }
        }
        .chartXSelection(value: $selectedDate)
        .chartYScale(domain: 0...top)
        .chartYAxis {
            AxisMarks(position: .leading, values: .stride(by: step)) { value in
                AxisGridLine().foregroundStyle(Palette.stroke)
                AxisValueLabel {
                    if let minutes = value.as(Double.self) {
                        Text(DurationText.axis(minutes: minutes))
                    }
                }
            }
        }
        .chartXAxis {
            AxisMarks(values: xAxisValues) { _ in
                AxisValueLabel(format: xAxisFormat, centered: true)
            }
        }
        .frame(height: 210)
    }

    private var legend: some View {
        HStack(spacing: 14) {
            swatch(Palette.accent, "Goal met")
            swatch(Palette.accent.opacity(0.45), "Below goal")
            HStack(spacing: 5) {
                Path { path in
                    path.move(to: CGPoint(x: 0, y: 0.5))
                    path.addLine(to: CGPoint(x: 14, y: 0.5))
                }
                .stroke(Color.white.opacity(0.5), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
                .frame(width: 14, height: 1)
                Text("\(DurationText.short(goal)) goal")
            }
        }
        .font(.caption2)
        .foregroundStyle(Palette.textTertiary)
    }

    private func swatch(_ color: Color, _ label: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
            Text(label)
        }
    }

    /// A round gridline step (15m, 30m, 1h, 2h, …) giving at most four lines.
    private static func tickStep(forPeakMinutes peak: Double) -> Double {
        let steps: [Double] = [15, 30, 60, 120, 180, 240, 360, 600, 1200, 1800, 3000, 6000]
        return steps.first { peak / $0 <= 4 } ?? 6000
    }

    private var selectedBucket: ChartBucket? {
        guard let selectedDate else { return nil }
        return stats.buckets.first {
            Calendar.current.isDate($0.date, equalTo: selectedDate, toGranularity: unit)
        }
    }

    private var xAxisValues: AxisMarkValues {
        switch stats.range {
        case .week: .stride(by: .day)
        case .month: .stride(by: .day, count: 7)
        case .year: .stride(by: .month)
        }
    }

    private var xAxisFormat: Date.FormatStyle {
        switch stats.range {
        case .week: .dateTime.weekday(.abbreviated)
        case .month: .dateTime.day()
        case .year: .dateTime.month(.narrow)
        }
    }

    private func color(for bucket: ChartBucket) -> Color {
        guard showGoal else { return Palette.accent }
        return bucket.seconds >= goal ? Palette.accent : Palette.accent.opacity(0.45)
    }

    private func label(for date: Date) -> String {
        stats.range == .year
            ? date.formatted(.dateTime.month(.wide))
            : date.formatted(.dateTime.weekday(.abbreviated).month(.abbreviated).day())
    }
}

// MARK: - Tiles

private struct StatTiles: View {
    let stats: PeriodStats

    var body: some View {
        LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible(), spacing: 10)], spacing: 10) {
            StatTile(title: "Daily average", value: DurationText.short(stats.dailyAverage), systemImage: "chart.line.uptrend.xyaxis")
            StatTile(title: "Best day", value: stats.bestDay.map { DurationText.short($0.seconds) } ?? "–", systemImage: "trophy.fill", tint: Palette.paused)
            StatTile(title: "Sessions", value: "\(stats.sessionCount)", systemImage: "square.stack.3d.up.fill", tint: Color(hex: 0x7DD3FC))
            StatTile(title: "Longest session", value: DurationText.short(stats.longestSession), systemImage: "timer", tint: Color(hex: 0xC4B5FD))
            StatTile(title: "Avg focus", value: stats.averageFocus.map { "\(Int(($0 * 100).rounded()))%" } ?? "–", systemImage: "scope", tint: Color(hex: 0x6EE7B7))
            StatTile(title: "Goal days", value: "\(stats.goalDays) of \(stats.countedDays)", systemImage: "target", tint: Palette.streak)
        }
    }
}

private struct StreakCard: View {
    let streaks: Streaks
    let goal: TimeInterval

    var body: some View {
        HStack(spacing: 14) {
            Image(systemName: "flame.fill")
                .font(.system(size: 28))
                .foregroundStyle(streaks.current > 0 ? Palette.streak : Palette.textTertiary)
                .frame(width: 56, height: 56)
                .background(Palette.streak.opacity(0.14), in: Circle())
                .symbolEffect(.bounce, value: streaks.current)
            VStack(alignment: .leading, spacing: 4) {
                Text(streaks.current == 1 ? "1-day streak" : "\(streaks.current)-day streak")
                    .font(.title3.weight(.bold))
                    .fontDesign(.rounded)
                Text("Best: \(streaks.best) \(streaks.best == 1 ? "day" : "days") · hit \(DurationText.short(goal)) a day to keep it going")
                    .font(.footnote)
                    .foregroundStyle(Palette.textSecondary)
            }
            Spacer(minLength: 0)
        }
        .card()
        .accessibilityElement(children: .combine)
    }
}

private struct InsightsCard: View {
    let lines: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SectionHeader(title: "Insights")
            ForEach(lines, id: \.self) { line in
                HStack(alignment: .firstTextBaseline, spacing: 10) {
                    Image(systemName: "sparkle")
                        .font(.footnote)
                        .foregroundStyle(Palette.accent)
                    Text(line)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.9))
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .card()
    }
}

// MARK: - Breakdown charts

private struct SubjectsCard: View {
    let stats: PeriodStats

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Subjects")
            HStack(spacing: 18) {
                Chart(stats.subjects) { slice in
                    SectorMark(angle: .value("Time", slice.seconds), innerRadius: .ratio(0.64), angularInset: 2)
                        .cornerRadius(4)
                        .foregroundStyle(slice.color)
                        .accessibilityLabel(slice.name)
                        .accessibilityValue(DurationText.spoken(slice.seconds))
                }
                .frame(width: 128, height: 128)
                .overlay {
                    VStack(spacing: 0) {
                        Text(DurationText.short(stats.total))
                            .font(.headline)
                            .fontDesign(.rounded)
                        Text("total")
                            .font(.caption2)
                            .foregroundStyle(Palette.textSecondary)
                    }
                }

                VStack(alignment: .leading, spacing: 9) {
                    ForEach(stats.subjects.prefix(6)) { slice in
                        HStack(spacing: 8) {
                            Circle().fill(slice.color).frame(width: 9, height: 9)
                            Text(slice.name)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer(minLength: 4)
                            Text(DurationText.short(slice.seconds))
                                .font(.subheadline.weight(.semibold))
                                .monospacedDigit()
                                .foregroundStyle(Palette.textSecondary)
                        }
                    }
                }
            }
        }
        .card()
    }
}

private struct HoursCard: View {
    let hours: [HourBucket]

    var body: some View {
        let calendar = Calendar.current
        let reference = calendar.startOfDay(for: .now)
        let peak = peakWindow

        VStack(alignment: .leading, spacing: 16) {
            SectionHeader(title: "Time of day")
            Chart(hours) { bucket in
                BarMark(
                    x: .value("Hour", calendar.date(bySettingHour: bucket.hour, minute: 0, second: 0, of: reference) ?? reference, unit: .hour),
                    y: .value("Minutes", bucket.seconds / 60)
                )
                .foregroundStyle(peak.contains(bucket.hour) ? Palette.accent : Palette.accent.opacity(0.35))
                .cornerRadius(3)
            }
            .chartYAxis(.hidden)
            .chartXAxis {
                AxisMarks(values: .stride(by: .hour, count: 6)) { _ in
                    AxisValueLabel(format: .dateTime.hour())
                }
            }
            .frame(height: 120)
        }
        .card()
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Time of day chart")
    }

    /// The two busiest adjacent hours.
    private var peakWindow: Set<Int> {
        let total: (Int) -> TimeInterval = { hour in
            (self.hours.first { $0.hour == hour }?.seconds ?? 0) + (self.hours.first { $0.hour == (hour + 1) % 24 }?.seconds ?? 0)
        }
        guard let best = (0..<24).max(by: { total($0) < total($1) }), total(best) > 0 else { return [] }
        return [best, (best + 1) % 24]
    }
}
