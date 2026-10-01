import Foundation
import Observation

/// A rolling log of lifecycle and lock-detection events, shown in Settings → Diagnostics.
/// It exists so the lock-detection thresholds can be checked and tuned on a real iPhone.
@Observable
final class DiagnosticsLog {
    nonisolated struct Entry: Codable, Identifiable, Sendable {
        var id = UUID()
        var date: Date
        var kind: Kind
        var message: String
    }

    nonisolated enum Kind: String, Codable, Sendable {
        case lifecycle, protectedData, check, verdict, session, widget

        var label: String {
            switch self {
            case .lifecycle: "App"
            case .protectedData: "Data"
            case .check: "Check"
            case .verdict: "Verdict"
            case .session: "Session"
            case .widget: "Widget"
            }
        }
    }

    private(set) var entries: [Entry] = []

    @ObservationIgnored private let defaults: UserDefaults
    @ObservationIgnored private let key = "diagnostics.log.v1"
    @ObservationIgnored private let limit = 400

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        if let data = defaults.data(forKey: key),
           let saved = try? JSONDecoder().decode([Entry].self, from: data) {
            entries = saved
        }
    }

    func add(_ kind: Kind, _ message: String) {
        entries.append(Entry(date: .now, kind: kind, message: message))
        if entries.count > limit { entries.removeFirst(entries.count - limit) }
        save()
    }

    func clear() {
        entries = []
        save()
    }

    var exportText: String {
        let formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        return entries
            .map { "\(formatter.string(from: $0.date)) [\($0.kind.label)] \($0.message)" }
            .joined(separator: "\n")
    }

    private func save() {
        if let data = try? JSONEncoder().encode(entries) {
            defaults.set(data, forKey: key)
        }
    }
}
