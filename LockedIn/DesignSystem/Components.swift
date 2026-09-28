import SwiftUI

// MARK: - Card

extension View {
    /// The rounded dark surface used for every card in the app.
    func card(padding: CGFloat = 16) -> some View {
        self
            .padding(padding)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Palette.surface, in: RoundedRectangle(cornerRadius: 22, style: .continuous))
            .overlay(RoundedRectangle(cornerRadius: 22, style: .continuous).stroke(Palette.stroke))
    }
}

struct SectionHeader: View {
    let title: String
    var trailing: String?

    var body: some View {
        HStack {
            Text(title.uppercased())
                .font(.caption.weight(.bold))
                .tracking(1.2)
                .foregroundStyle(Palette.textSecondary)
            Spacer()
            if let trailing {
                Text(trailing)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(Palette.textTertiary)
            }
        }
    }
}

// MARK: - Progress ring

struct ProgressRing: View {
    var progress: Double
    var lineWidth: CGFloat = 16
    var tint: Color = Palette.accent

    var body: some View {
        ZStack {
            Circle()
                .stroke(Color.white.opacity(0.07), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: min(max(progress, 0), 1))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .shadow(color: tint.opacity(0.45), radius: 10)
        }
        .animation(.spring(duration: 0.9), value: progress)
    }
}

// MARK: - Buttons

struct PrimaryButtonStyle: ButtonStyle {
    var tint: Color = Palette.accent

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.title3.weight(.bold))
            .fontDesign(.rounded)
            .foregroundStyle(Palette.onAccent)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 18)
            .background(tint, in: Capsule())
            .shadow(color: tint.opacity(configuration.isPressed ? 0.15 : 0.4), radius: 18, y: 6)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

struct SecondaryButtonStyle: ButtonStyle {
    var tint: Color = .white

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .fontDesign(.rounded)
            .foregroundStyle(tint)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 16)
            .background(Palette.surfaceRaised, in: Capsule())
            .overlay(Capsule().stroke(Palette.stroke))
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.spring(duration: 0.25), value: configuration.isPressed)
    }
}

// MARK: - Chips

struct Chip: View {
    let title: String
    var isSelected: Bool
    var tint: Color = Palette.accent
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.subheadline.weight(.semibold))
                .foregroundStyle(isSelected ? .white : Palette.textSecondary)
                .padding(.horizontal, 14)
                .padding(.vertical, 9)
                .background(isSelected ? tint.opacity(0.18) : Palette.surface, in: Capsule())
                .overlay(Capsule().stroke(isSelected ? tint : Palette.stroke, lineWidth: isSelected ? 1.5 : 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? .isSelected : [])
    }
}

// MARK: - Stat tile

struct StatTile: View {
    let title: String
    let value: String
    let systemImage: String
    var tint: Color = Palette.accent

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label {
                Text(title)
            } icon: {
                Image(systemName: systemImage).foregroundStyle(tint)
            }
            .font(.caption.weight(.semibold))
            .foregroundStyle(Palette.textSecondary)
            .lineLimit(1)

            Text(value)
                .font(.title3.weight(.bold))
                .fontDesign(.rounded)
                .monospacedDigit()
                .foregroundStyle(.white)
                .lineLimit(1)
                .minimumScaleFactor(0.7)
        }
        .card(padding: 14)
        .accessibilityElement(children: .combine)
    }
}

// MARK: - Streak badge

struct StreakBadge: View {
    let days: Int

    var body: some View {
        HStack(spacing: 4) {
            Image(systemName: "flame.fill")
                .foregroundStyle(days > 0 ? Palette.streak : Palette.textTertiary)
            Text("\(days)")
                .fontDesign(.rounded)
                .monospacedDigit()
        }
        .font(.subheadline.weight(.bold))
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Palette.surface, in: Capsule())
        .overlay(Capsule().stroke(Palette.stroke))
        .accessibilityLabel("\(days) day streak")
    }
}

// MARK: - Timeline bar

/// A session drawn as a bar: lime where the phone was locked, dark where it was unlocked.
struct TimelineBar: View {
    let stretches: [DateInterval]
    let start: Date
    let end: Date
    var tint: Color = Palette.accent

    var body: some View {
        VStack(spacing: 6) {
            GeometryReader { proxy in
                let width = proxy.size.width
                ZStack(alignment: .leading) {
                    Capsule().fill(Color.white.opacity(0.08))
                    ForEach(Array(stretches.enumerated()), id: \.offset) { _, stretch in
                        let x = width * fraction(stretch.start)
                        let w = max(3, width * (fraction(stretch.end) - fraction(stretch.start)))
                        RoundedRectangle(cornerRadius: 4)
                            .fill(tint)
                            .frame(width: w)
                            .offset(x: x)
                    }
                }
                .clipShape(Capsule())
            }
            .frame(height: 14)

            HStack {
                Text(start.formatted(date: .omitted, time: .shortened))
                Spacer()
                Text(end.formatted(date: .omitted, time: .shortened))
            }
            .font(.caption2.weight(.medium))
            .foregroundStyle(Palette.textTertiary)
        }
        .accessibilityElement(children: .ignore)
        .accessibilityLabel("Timeline with \(stretches.count) locked stretches")
    }

    private func fraction(_ date: Date) -> CGFloat {
        let total = end.timeIntervalSince(start)
        guard total > 0 else { return 0 }
        return CGFloat(min(max(date.timeIntervalSince(start) / total, 0), 1))
    }
}

// MARK: - Haptics

extension View {
    /// Plays a haptic when `trigger` changes, if haptics are on in Settings.
    func haptic<T: Equatable>(_ feedback: SensoryFeedback, trigger: T, enabled: Bool) -> some View {
        sensoryFeedback(feedback, trigger: trigger) { _, _ in enabled }
    }
}
