import SwiftUI          // ObservableObject, @Published (re‑exports Combine)
import Combine           // needed for @Published’s initializer & ObservableObjectPublisher
import AppKit           // (optional – kept for consistency)
import Darwin           // for kill() and SIGKILL

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
    private var didBootstrapSessions = false
    private var titleObserver: NSObjectProtocol?

    /// Sessions are created once `setShellManager` runs (ContentView.onAppear / ProTermApp).
    init() {
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
    
    /// Set the shell manager reference and create initial sessions (once).
    func setShellManager(_ shellManager: ShellManager) {
        self.shellManager = shellManager
        bootstrapSessionsIfNeeded()
    }

    private func bootstrapSessionsIfNeeded() {
        guard !didBootstrapSessions, shellManager != nil else { return }
        didBootstrapSessions = true
        let savedIDs = SessionPersistence.shared.load()
        if savedIDs.isEmpty {
            addSession()
        } else {
            for _ in savedIDs { addSession() }
        }
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

    /// Check if a session has a running process that should warn before closing
    func sessionHasRunningProcess(_ session: TerminalSession) -> Bool {
        return session.isProcessRunning && session.hasActivePTY
    }
    
    /// Get warning message for a session with running processes
    func warningMessageForSession(at index: Int) -> String? {
        guard sessions.indices.contains(index) else { return nil }
        let session = sessions[index]
        
        if session.isSSHSession && session.isProcessRunning {
            return "This SSH session is still connected. Closing will disconnect."
        } else if session.isProcessRunning && session.hasActivePTY {
            return "This session has a running process. Closing will terminate it."
        }
        return nil
    }
    
    /// Force close a session without confirmation (used after user confirms)
    func forceCloseSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        
        let session = sessions[index]
        let sessionId = session.id
        
        // If this is an SSH session, notify IntegrationFeatures to disconnect
        if session.isSSHSession {
            NotificationCenter.default.post(
                name: Notification.Name("ProTermSSHSessionClosed"),
                object: sessionId
            )
        }
        
        // Send SIGKILL to any running process
        if session.childPID > 0 {
            _ = kill(session.childPID, SIGKILL)
        }
        
        sessions.remove(at: index)
        tabMetadata.removeValue(forKey: sessionId)
    }
    
    /// Close session with optional confirmation if process is running
    /// Returns true if closed immediately, false if user needs to confirm
    @discardableResult
    func closeSession(at index: Int, requireConfirmation: Bool = true) -> Bool {
        guard sessions.indices.contains(index) else { return false }
        
        // Check if we need to warn about running process
        if requireConfirmation, let warning = warningMessageForSession(at: index) {
            // Post notification for UI to show confirmation dialog
            NotificationCenter.default.post(
                name: .proTermCloseSessionWithWarning,
                object: index,
                userInfo: ["warning": warning]
            )
            return false
        }
        
        forceCloseSession(at: index)
        return true
    }
    
    func duplicateSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        let sourceSession = sessions[index]
        guard let shellManager = shellManager else { return }
        
        let newSession = TerminalSession(shellManager: shellManager, initialCWD: sourceSession.cwd)
        newSession.output = sourceSession.output
        newSession.commandHistory = sourceSession.commandHistory
        
        let sourceMetadata = getTabMetadata(for: sourceSession.id)
        tabMetadata[newSession.id] = TabMetadata(
            name: "\(sourceMetadata.name) Copy",
            color: sourceMetadata.color
        )
        
        sessions.append(newSession)
    }
    
    /// Close all sessions except the one at index, with optional confirmation
    func closeOtherSessions(except index: Int, requireConfirmation: Bool = true) {
        guard sessions.indices.contains(index) else { return }
        
        // Check if any sessions to close have running processes
        if requireConfirmation {
            var sessionsWithWarnings: [Int] = []
            for (i, session) in sessions.enumerated() {
                if i != index && sessionHasRunningProcess(session) {
                    sessionsWithWarnings.append(i)
                }
            }
            
            if !sessionsWithWarnings.isEmpty {
                NotificationCenter.default.post(
                    name: .proTermCloseMultipleSessionsWithWarning,
                    object: index,
                    userInfo: ["affectedIndices": sessionsWithWarnings]
                )
                return
            }
        }
        
        // Proceed with closing
        let keepSession = sessions[index]
        let updatedSessions: [TerminalSession] = [keepSession]
        var updatedMetadata: [UUID: TabMetadata] = [:]
        updatedMetadata[keepSession.id] = tabMetadata[keepSession.id] ?? TabMetadata(name: "Session 1", color: .default)
        
        for session in sessions where session.id != keepSession.id {
            if session.childPID > 0 {
                _ = kill(session.childPID, SIGKILL)
            }
        }
        
        sessions = updatedSessions
        tabMetadata = updatedMetadata
    }
    
    /// Close all sessions after index, with optional confirmation
    func closeSessionsToRight(of index: Int, requireConfirmation: Bool = true) {
        guard sessions.indices.contains(index) else { return }
        
        // Check if any sessions to close have running processes
        if requireConfirmation {
            var sessionsWithWarnings: [Int] = []
            for i in (index + 1)..<sessions.count {
                if sessionHasRunningProcess(sessions[i]) {
                    sessionsWithWarnings.append(i)
                }
            }
            
            if !sessionsWithWarnings.isEmpty {
                NotificationCenter.default.post(
                    name: .proTermCloseMultipleSessionsWithWarning,
                    object: index,
                    userInfo: ["affectedIndices": sessionsWithWarnings, "direction": "right"]
                )
                return
            }
        }
        
        // Kill any running processes in sessions to close
        for i in (index + 1)..<sessions.count {
            if sessions[i].childPID > 0 {
                _ = kill(sessions[i].childPID, SIGKILL)
            }
        }
        
        sessions = Array(sessions.prefix(index + 1))
        // Clean up metadata for removed sessions
        let removedIds = Set(sessions.dropFirst(index + 1).map { $0.id })
        for id in removedIds {
            tabMetadata.removeValue(forKey: id)
        }
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
