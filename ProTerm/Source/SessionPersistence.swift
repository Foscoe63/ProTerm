// SessionPersistence.swift
import Foundation

/// Handles saving and restoring terminal sessions (IDs, titles, maybe history).
struct SessionSnapshot: Codable {
    var id: UUID
    var title: String
}

final class SessionPersistence {
    static let shared = SessionPersistence()
    private let fileURL: URL = {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = dir.appendingPathComponent("ProTerm")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("sessions.json")
    }()

    func save(sessions: [TerminalSession]) {
        let snapshots = sessions.map { SessionSnapshot(id: $0.id, title: "Session \($0.id.uuidString.prefix(4))") }
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: fileURL)
        }
    }

    func load() -> [UUID] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshots = try? JSONDecoder().decode([SessionSnapshot].self, from: data) else { return [] }
        return snapshots.map { $0.id }
    }
}
