import CoreTransferable
import Foundation
import UniformTypeIdentifiers

/// All sessions as a CSV file, handed to the share sheet from Settings.
nonisolated struct SessionsCSV: Transferable {
    let text: String

    static var transferRepresentation: some TransferRepresentation {
        DataRepresentation(exportedContentType: .commaSeparatedText) { csv in
            Data(csv.text.utf8)
        }
        .suggestedFileName("LockedIn Sessions.csv")
    }
}

enum CSVExporter {
    static func csv(for sessions: [StudySession]) -> String {
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        let day = DateFormatter()
        day.dateFormat = "yyyy-MM-dd"

        var rows = ["date,start,end,subject,locked_minutes,unlocks,breaks,break_minutes,focus_percent,target_minutes,ended_because,note"]
        for session in sessions.sorted(by: { $0.startedAt < $1.startedAt }) {
            let fields: [String] = [
                day.string(from: session.startedAt),
                iso.string(from: session.startedAt),
                iso.string(from: session.endedAt),
                session.subject?.name ?? "",
                String(format: "%.1f", session.lockedSeconds / 60),
                String(session.unlockCount),
                String(session.breakCount),
                String(format: "%.1f", session.breakSeconds / 60),
                session.focus.map { String(Int(($0 * 100).rounded())) } ?? "",
                session.targetSeconds.map { String(Int($0 / 60)) } ?? "",
                session.endReason.rawValue,
                session.note,
            ]
            rows.append(fields.map(escape).joined(separator: ","))
        }
        return rows.joined(separator: "\n")
    }

    private static func escape(_ field: String) -> String {
        guard field.contains(where: { $0 == "," || $0 == "\"" || $0 == "\n" }) else { return field }
        return "\"" + field.replacingOccurrences(of: "\"", with: "\"\"") + "\""
    }
}
