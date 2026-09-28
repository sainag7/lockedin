import SwiftUI

/// The app's colors. Shared with the widget extension so the Live Activity matches the app.
nonisolated enum Palette {
    static let background = Color(hex: 0x0A0A0C)
    static let surface = Color(hex: 0x151518)
    static let surfaceRaised = Color(hex: 0x1F1F24)
    static let stroke = Color.white.opacity(0.08)

    /// Lime: locked in.
    static let accent = Color(hex: 0xBEF264)
    /// Amber: unlocked (timer stopped until the next lock).
    static let paused = Color(hex: 0xFBBF24)
    /// Sky blue: paused with the Pause button.
    static let onBreak = Color(hex: 0x7DD3FC)
    /// Orange: streak flame.
    static let streak = Color(hex: 0xFB923C)
    static let danger = Color(hex: 0xF87171)

    static let textSecondary = Color.white.opacity(0.62)
    static let textTertiary = Color.white.opacity(0.38)
    static let onAccent = Color.black

    /// Colors offered for subjects, stored on `Subject` as hex strings.
    static let subjectHexes = ["BEF264", "7DD3FC", "C4B5FD", "F9A8D4", "FCD34D", "6EE7B7", "FDBA74", "FDA4AF"]

    static func subjectColor(_ hex: String?) -> Color {
        guard let hex, let value = UInt32(hex, radix: 16) else { return Color.white.opacity(0.45) }
        return Color(hex: value)
    }
}

extension Color {
    nonisolated init(hex: UInt32, opacity: Double = 1) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: opacity
        )
    }
}
