// SessionPersistence.swift
import Foundation

/// Handles saving and restoring terminal sessions (titles, colors, working directories).
struct SessionSnapshot: Codable {
    var id: UUID
    var title: String
    var scrollPosition: Double = 0.0  // Scroll position as a ratio (0.0 = top, 1.0 = bottom)
    var cwd: String?
    var color: String?
    /// Split layout of this tab, if it had one.
    var panes: PaneSnapshot?
    /// Index of the focused pane among the layout's leaves in reading order.
    var activePaneIndex: Int?
}

final class SessionPersistence: @unchecked Sendable {
    static let shared = SessionPersistence()
    private let fileURL: URL = {
        // UI tests launch with this flag so they never touch the user's saved tabs.
        if ProcessInfo.processInfo.arguments.contains("-ProTermUITesting") {
            let url = FileManager.default.temporaryDirectory.appendingPathComponent("proterm-uitest-sessions.json")
            if ProcessInfo.processInfo.arguments.contains("-ProTermUITestingReset") {
                try? FileManager.default.removeItem(at: url)
            }
            return url
        }
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        let folder = dir.appendingPathComponent("ProTerm")
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        return folder.appendingPathComponent("sessions.json")
    }()

    func save(snapshots: [SessionSnapshot]) {
        if let data = try? JSONEncoder().encode(snapshots) {
            try? data.write(to: fileURL, options: .atomic)
        }
    }

    func load() -> [SessionSnapshot] {
        guard let data = try? Data(contentsOf: fileURL),
              let snapshots = try? JSONDecoder().decode([SessionSnapshot].self, from: data) else { return [] }
        return snapshots
    }
}
