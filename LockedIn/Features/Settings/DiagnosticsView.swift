import SwiftUI
import UIKit

/// Shows how lock detection is behaving on this phone, so thresholds can be tuned.
struct DiagnosticsView: View {
    @Environment(DiagnosticsLog.self) private var log
    @Environment(AppSettings.self) private var settings
    @Environment(SessionEngine.self) private var engine
    @State private var copied = false

    var body: some View {
        @Bindable var settings = settings

        List {
            Section {
                Picker("Lock detection", selection: $settings.detectionMode) {
                    ForEach(DetectionMode.allCases, id: \.self) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                LabeledContent("Device passcode", value: engine.deviceHasPasscode ? "On" : "Off")
                LabeledContent("Background tracking", value: engine.tracksLocksAnywhere ? "Running" : (engine.session == nil ? "Starts with a session" : "Off"))
                LabeledContent("Lock-like transition", value: "≤ \(Int(LockDetector.lockLikeGap * 1000)) ms")
                LabeledContent("Background check", value: "Up to \(Int(LockDetector.maxCheckWindow)) s")
            } header: {
                Text("Lock detection")
            } footer: {
                Text("Automatic uses the phone's own lock and unlock signals plus how fast LockedIn leaves the screen. “Always assume locked” counts every trip away from the app as locked, useful in the simulator.")
            }

            Section {
                Button(copied ? "Copied ✓" : "Copy log") {
                    UIPasteboard.general.string = log.exportText
                    copied = true
                }
                .disabled(log.entries.isEmpty)
                Button("Clear log", role: .destructive) { log.clear() }
                    .disabled(log.entries.isEmpty)
            }

            Section("Events, newest first") {
                if log.entries.isEmpty {
                    Text("No events yet. Start a session and lock your phone.")
                        .foregroundStyle(Palette.textSecondary)
                }
                ForEach(log.entries.reversed()) { entry in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack {
                            Text(entry.kind.label)
                                .font(.caption2.weight(.bold))
                                .foregroundStyle(color(for: entry.kind))
                            Spacer()
                            Text(entry.date.formatted(.dateTime.hour().minute().second()))
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(Palette.textTertiary)
                        }
                        Text(entry.message)
                            .font(.footnote)
                    }
                    .padding(.vertical, 2)
                }
            }
        }
        .scrollContentBackground(.hidden)
        .background(Palette.background.ignoresSafeArea())
        .navigationTitle("Diagnostics")
        .navigationBarTitleDisplayMode(.inline)
        .onChange(of: settings.detectionMode) { engine.trackingSettingChanged() }
    }

    private func color(for kind: DiagnosticsLog.Kind) -> Color {
        switch kind {
        case .verdict: Palette.accent
        case .protectedData: Color(hex: 0x7DD3FC)
        case .session: Palette.streak
        case .check: Palette.paused
        case .lifecycle: Palette.textSecondary
        case .widget: Color(hex: 0xC4B5FD)
        }
    }
}
