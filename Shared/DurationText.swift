import Foundation

/// Formats durations the same way everywhere in the app and the Live Activity.
nonisolated enum DurationText {
    /// "1h 5m", "25m", "40s", "0m".
    static func short(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        if hours > 0 { return minutes > 0 ? "\(hours)h \(minutes)m" : "\(hours)h" }
        if minutes > 0 { return "\(minutes)m" }
        return total > 0 ? "\(total)s" : "0m"
    }

    /// Clock style: "1:05:09" or "25:09".
    static func clock(_ seconds: TimeInterval) -> String {
        let total = Int(max(0, seconds))
        let hours = total / 3600
        let minutes = (total % 3600) / 60
        let secs = total % 60
        if hours > 0 { return String(format: "%d:%02d:%02d", hours, minutes, secs) }
        return String(format: "%02d:%02d", minutes, secs)
    }

    /// For VoiceOver: "1 hour, 5 minutes".
    static func spoken(_ seconds: TimeInterval) -> String {
        let formatter = DateComponentsFormatter()
        formatter.unitsStyle = .full
        formatter.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute, .second]
        return formatter.string(from: max(0, seconds)) ?? ""
    }

    /// "1 break", "2 breaks · 25m" (time is left off when it's under a minute).
    static func breaks(count: Int, seconds: TimeInterval) -> String {
        let label = count == 1 ? "1 break" : "\(count) breaks"
        return seconds >= 60 ? "\(label) · \(short(seconds))" : label
    }

    /// Chart axis labels: "2h", "1.5h", "45m".
    static func axis(minutes: Double) -> String {
        guard minutes >= 60 else { return "\(Int(minutes.rounded()))m" }
        let hours = minutes / 60
        return hours == hours.rounded() ? "\(Int(hours))h" : String(format: "%.1fh", hours)
    }
}
