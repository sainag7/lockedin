import SwiftUI

/// Picks the focus sound for the session and sets its volume. Changes apply live through
/// `engine.soundSettingChanged()`, so during a session you hear the sound change as you tap.
struct SoundPicker: View {
    @Environment(AppSettings.self) private var settings
    @Environment(SessionEngine.self) private var engine
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        @Bindable var settings = settings

        NavigationStack {
            ScrollView {
                VStack(spacing: 10) {
                    ForEach(BackgroundSound.allCases, id: \.self) { sound in
                        row(sound)
                    }

                    if settings.backgroundSound != .none {
                        volumeCard($settings.soundVolume)
                            .padding(.top, 6)
                    }
                }
                .padding(20)
            }
            .scrollContentBackground(.hidden)
            .background(Palette.background.ignoresSafeArea())
            .navigationTitle("Background sound")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done") { dismiss() }
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
    }

    private func row(_ sound: BackgroundSound) -> some View {
        let selected = settings.backgroundSound == sound
        return Button {
            settings.backgroundSound = sound
            engine.soundSettingChanged()
        } label: {
            HStack(spacing: 14) {
                Image(systemName: sound.symbol)
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(selected ? Palette.onAccent : Palette.accent)
                    .frame(width: 44, height: 44)
                    .background(selected ? Palette.accent : Palette.accent.opacity(0.12), in: RoundedRectangle(cornerRadius: 13, style: .continuous))

                VStack(alignment: .leading, spacing: 2) {
                    Text(sound.name)
                        .font(.headline)
                        .foregroundStyle(.white)
                    Text(sound.blurb)
                        .font(.subheadline)
                        .foregroundStyle(Palette.textSecondary)
                        .lineLimit(1)
                }
                Spacer(minLength: 8)
                if selected {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(Palette.accent)
                }
            }
            .card(padding: 14)
            .overlay(
                RoundedRectangle(cornerRadius: 22, style: .continuous)
                    .stroke(selected ? Palette.accent : .clear, lineWidth: 1.5)
            )
            .contentShape(RoundedRectangle(cornerRadius: 22, style: .continuous))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(selected ? [.isSelected] : [])
    }

    private func volumeCard(_ volume: Binding<Double>) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            SectionHeader(title: "Volume")
            HStack(spacing: 12) {
                Image(systemName: "speaker.fill").foregroundStyle(Palette.textSecondary)
                Slider(value: volume, in: 0...1) { editing in
                    if !editing { engine.soundSettingChanged() }
                }
                .tint(Palette.accent)
                Image(systemName: "speaker.wave.3.fill").foregroundStyle(Palette.textSecondary)
            }
        }
        .card(padding: 16)
    }
}
