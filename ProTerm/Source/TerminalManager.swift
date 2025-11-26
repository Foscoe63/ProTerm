import SwiftUI          // ObservableObject, @Published (re‑exports Combine)
import Combine           // needed for @Published’s initializer & ObservableObjectPublisher
import AppKit           // (optional – kept for consistency)

/// Manages a collection of terminal sessions.
@MainActor
final class TerminalManager: ObservableObject {
    // The synthesized `objectWillChange` from @Published is sufficient.

    /// The UI watches this array for changes (new/closed sessions).
    @Published var sessions: [TerminalSession] = [] {
        didSet { SessionPersistence.shared.save(sessions: sessions) }
    }
    
    /// Tab metadata (names, colors) indexed by session ID
    @Published var tabMetadata: [UUID: TabMetadata] = [:]
    
    /// Scroll positions indexed by session ID (0.0 = top, 1.0 = bottom)
    @Published var scrollPositions: [UUID: Double] = [:]
    
    /// Version counter to force TabView updates when metadata changes
    @Published var tabMetadataVersion: Int = 0
    
    /// Reference to shell manager for creating new sessions
    private var shellManager: ShellManager?
    private var titleObserver: NSObjectProtocol?

    /// Restore persisted session IDs (or create a default session).
    init() {
        let savedIDs = SessionPersistence.shared.load()
        if savedIDs.isEmpty {
            addSession()               // create a default first session
        } else {
            for _ in savedIDs { addSession() }
        }
        
        titleObserver = NotificationCenter.default.addObserver(
            forName: .terminalTitleDidChange,
            object: nil,
            queue: .main
        ) { [weak self] notification in
            let sessionId = notification.object as? UUID
            let title = notification.userInfo?["title"] as? String
            Task { @MainActor [weak self] in
                guard let self,
                      let sessionId,
                      let title else { return }
                let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
                let displayName = trimmed.isEmpty ? "Session" : trimmed
                self.updateTabName(for: sessionId, name: displayName)
            }
        }
    }
    
    deinit {
        Task { @MainActor [weak self] in
            guard let token = self?.titleObserver else { return }
            NotificationCenter.default.removeObserver(token)
        }
    }
    
    /// Set the shell manager reference
    func setShellManager(_ shellManager: ShellManager) {
        self.shellManager = shellManager
    }

    // MARK: – Session handling
    func addSession() {
        guard let shellManager = shellManager else {
            // Fallback to bash if shell manager not set
            let session = TerminalSession(shellManager: ShellManager())
            sessions.append(session)
            tabMetadata[session.id] = TabMetadata(name: "Session \(sessions.count)", color: .default)
            return
        }
        let session = TerminalSession(shellManager: shellManager)
        sessions.append(session)
        tabMetadata[session.id] = TabMetadata(name: "Session \(sessions.count)", color: .default)
    }
    
    func updateTabName(for sessionId: UUID, name: String) {
        if var metadata = tabMetadata[sessionId] {
            metadata.name = name
            tabMetadata[sessionId] = metadata
        } else {
            tabMetadata[sessionId] = TabMetadata(name: name, color: .default)
        }
    }
    
    func updateTabColor(for sessionId: UUID, color: TabColor) {
        // Force a complete rebuild by creating a new dictionary
        var newMetadata: [UUID: TabMetadata] = [:]
        for (id, meta) in tabMetadata {
            if id == sessionId {
                var updated = meta
                updated.color = color
                newMetadata[id] = updated
            } else {
                newMetadata[id] = meta
            }
        }
        if newMetadata[sessionId] == nil {
            newMetadata[sessionId] = TabMetadata(name: "Session", color: color)
        }
        tabMetadata = newMetadata
        tabMetadataVersion += 1
        // Explicitly trigger objectWillChange
        objectWillChange.send()
    }
    
    func getTabMetadata(for sessionId: UUID) -> TabMetadata {
        return tabMetadata[sessionId] ?? TabMetadata(name: "Session", color: .default)
    }

    func closeSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        NotificationHelper.shared.notify(
            title: "Session Closed",
            body: "Closed session \(index + 1)"
        )
        let session = sessions[index]
        let sessionId = session.id
        
        // If this is an SSH session, notify IntegrationFeatures to disconnect
        if session.isSSHSession {
            NotificationCenter.default.post(
                name: Notification.Name("ProTermSSHSessionClosed"),
                object: sessionId
            )
        }
        
        sessions.remove(at: index)
        tabMetadata.removeValue(forKey: sessionId)
    }
    
    func duplicateSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let sourceSession = sessions[index]
        guard let shellManager = shellManager else { return }
        
        let newSession = TerminalSession(shellManager: shellManager)
        newSession.cwd = sourceSession.cwd
        newSession.output = sourceSession.output
        newSession.commandHistory = sourceSession.commandHistory
        
        let sourceMetadata = getTabMetadata(for: sourceSession.id)
        tabMetadata[newSession.id] = TabMetadata(
            name: "\(sourceMetadata.name) Copy",
            color: sourceMetadata.color
        )
        
        sessions.append(newSession)
    }
    
    func closeOtherSessions(except index: Int) {
        guard sessions.indices.contains(index) else { return }
        
        // Remove all sessions except the one at index
        let sessionsToRemove = sessions.enumerated().filter { $0.offset != index }
        for (_, session) in sessionsToRemove {
            tabMetadata.removeValue(forKey: session.id)
        }
        
        sessions = [sessions[index]]
    }
    
    func closeSessionsToRight(of index: Int) {
        guard sessions.indices.contains(index) else { return }
        
        // Remove all sessions after index
        let sessionsToRemove = sessions.suffix(from: index + 1)
        for session in sessionsToRemove {
            tabMetadata.removeValue(forKey: session.id)
        }
        
        sessions = Array(sessions.prefix(index + 1))
    }
    
    func moveSession(from sourceIndex: Int, to destinationIndex: Int) {
        guard sessions.indices.contains(sourceIndex),
              sessions.indices.contains(destinationIndex),
              sourceIndex != destinationIndex else { return }
        
        let session = sessions.remove(at: sourceIndex)
        sessions.insert(session, at: destinationIndex)
    }

    // MARK: – Helper
    func reportCompletion(of cmd: String) {
        NotificationHelper.shared.notify(
            title: "Command Finished",
            body: "\(cmd) completed."
        )
    }
}
