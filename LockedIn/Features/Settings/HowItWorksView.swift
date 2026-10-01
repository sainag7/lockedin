import SwiftUI

struct HowItWorksView: View {
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 24) {
                    HowItWorksSteps()
                        .card(padding: 20)

                    VStack(alignment: .leading, spacing: 14) {
                        SectionHeader(title: "Good to know")
                        ForEach(Self.notes, id: \.self) { note in
                            HStack(alignment: .firstTextBaseline, spacing: 10) {
                                Circle()
                                    .fill(Palette.accent)
                                    .frame(width: 5, height: 5)
                                    .offset(y: -3)
                                Text(note)
                                    .font(.subheadline)
                                    .foregroundStyle(.white.opacity(0.88))
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                    .card(padding: 20)
                }
                .padding(20)
            }
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("How LockedIn works")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }

    private static let notes = [
        "It works from any app. During a session LockedIn keeps running quietly in the background (it plays silence), so locking your phone starts the timer and unlocking stops it, whatever app is open. You can turn this off in Settings.",
        "Unlocking counts the moment the phone unlocks, including a quick Face ID glance at the Lock Screen.",
        "Need a real break? Tap Pause. Locking your phone won't count until you tap Resume, and you can set a reminder for when the break's over.",
        "A session ends on its own if your phone stays locked past your auto-end limit (Settings), stays unlocked for over an hour, or stays paused for over 4 hours.",
        "Tracking needs a device passcode. Without one, LockedIn can only count locks made from inside the app.",
        "Everything stays on your iPhone. No account, no servers.",
    ]
}

/// The four-step explainer, used in onboarding and in Settings.
struct HowItWorksSteps: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            step(1, icon: "hand.tap.fill", title: "Tap Lock In", detail: "Pick what you're studying and, if you like, a target.")
            step(2, icon: "lock.fill", title: "Lock your phone", detail: "The timer runs only while it's locked. Glance at your Lock Screen to watch it tick.")
            step(3, icon: "lock.open.fill", title: "Unlock = stop", detail: "Unlocking stops the timer. Lock again to keep going, or tap Pause for a real break.")
            step(4, icon: "chart.bar.fill", title: "Watch it add up", detail: "Daily totals, streaks and trends show how locked in you really are.")
        }
    }

    private func step(_ number: Int, icon: String, title: String, detail: String) -> some View {
        HStack(alignment: .top, spacing: 14) {
            Image(systemName: icon)
                .font(.system(size: 18, weight: .semibold))
                .foregroundStyle(Palette.accent)
                .frame(width: 44, height: 44)
                .background(Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))
            VStack(alignment: .leading, spacing: 3) {
                Text(title)
                    .font(.headline)
                Text(detail)
                    .font(.subheadline)
                    .foregroundStyle(Palette.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Step \(number). \(title). \(detail)")
    }
}
