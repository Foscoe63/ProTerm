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
        didSet { persistSnapshot() }
    }
    
    /// Tab metadata (names, colors) indexed by session ID
    @Published var tabMetadata: [UUID: TabMetadata] = [:]
    
    /// Scroll positions indexed by session ID (0.0 = top, 1.0 = bottom)
    @Published var scrollPositions: [UUID: Double] = [:]
    
    /// Scroll offsets (points) of tabs the user had scrolled away from the bottom when leaving them.
    var savedScrollOffsets: [UUID: CGFloat] = [:]
    
    /// Version counter to force TabView updates when metadata changes
    @Published var tabMetadataVersion: Int = 0
    
    /// Reference to shell manager for creating new sessions
    private var shellManager: ShellManager?
    private var didBootstrapSessions = false
    private var titleObserver: NSObjectProtocol?
    private var willTerminateObserver: NSObjectProtocol?
    private var isRestoring = false

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
        isRestoring = true
        let snapshots = SessionPersistence.shared.load()
        if snapshots.isEmpty {
            addSession()
        } else {
            for snapshot in snapshots {
                var directory: URL?
                if let path = snapshot.cwd {
                    var isDir: ObjCBool = false
                    if FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                        directory = URL(fileURLWithPath: path)
                    }
                }
                addSession(
                    initialCWD: directory,
                    name: snapshot.title,
                    color: snapshot.color.flatMap { TabColor(rawValue: $0) } ?? .default
                )
            }
        }
        isRestoring = false
        persistSnapshot()
        willTerminateObserver = NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.persistSnapshot() }
        }
    }

    /// Saves titles, colors and working directories so tabs can be restored on next launch.
    func persistSnapshot() {
        guard !isRestoring else { return }
        let snapshots = sessions.map { session -> SessionSnapshot in
            let meta = tabMetadata[session.id]
            return SessionSnapshot(
                id: session.id,
                title: meta?.name ?? "Session",
                cwd: session.isSSHSession ? nil : session.cwd.path,
                color: meta?.color.rawValue
            )
        }
        SessionPersistence.shared.save(snapshots: snapshots)
    }

    // MARK: – Session handling
    @discardableResult
    func addSession(
        initialCWD: URL? = nil,
        name: String? = nil,
        color: TabColor = .default,
        environment: [String: String] = [:]
    ) -> TerminalSession {
        let session = TerminalSession(
            shellManager: shellManager ?? ShellManager(),
            initialCWD: initialCWD ?? FileManager.default.homeDirectoryForCurrentUser
        )
        session.extraEnvironment = environment
        // Metadata must exist before the append so the persisted snapshot includes the real title.
        tabMetadata[session.id] = TabMetadata(name: name ?? "Session \(sessions.count + 1)", color: color)
        sessions.append(session)
        return session
    }
    
    /// Opens a new tab from a template: working directory, environment, then the initial commands
    /// once the shell is ready. The caller should select the new tab so its shell starts.
    @discardableResult
    func addSession(from template: ProductivityTools.SessionTemplate) -> TerminalSession {
        var directory: URL?
        if let path = template.workingDirectory?.trimmingCharacters(in: .whitespaces), !path.isEmpty {
            let expanded = (path as NSString).expandingTildeInPath
            var isDir: ObjCBool = false
            if FileManager.default.fileExists(atPath: expanded, isDirectory: &isDir), isDir.boolValue {
                directory = URL(fileURLWithPath: expanded)
            }
        }
        let session = addSession(
            initialCWD: directory, name: template.name, color: .default, environment: template.environment)
        let commands = template.initialCommands
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
        runStartupCommands(commands, on: session)
        return session
    }
    
    /// Waits (up to ~8s) for the login shell, then types each command.
    private func runStartupCommands(_ commands: [String], on session: TerminalSession) {
        guard !commands.isEmpty else { return }
        Task { @MainActor [weak session] in
            // Wait up to ~8s for the login shell to come up.
            for _ in 0..<80 {
                if let session, session.hasActivePTY, session.canAcceptLoginShellInput { break }
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard let session, session.hasActivePTY else { return }
            for command in commands {
                session.runCommand(command)
                try? await Task.sleep(nanoseconds: 200_000_000)
            }
        }
    }
    
    // MARK: - Workspaces
    
    /// Local tabs only: SSH tabs can't be reopened without reconnecting, so they are skipped.
    func workspaceTabs() -> [ProductivityTools.WorkspaceTab] {
        sessions.compactMap { session in
            guard !session.isSSHSession else { return nil }
            let meta = getTabMetadata(for: session.id)
            return ProductivityTools.WorkspaceTab(title: meta.name, color: meta.color.rawValue, cwd: session.cwd.path)
        }
    }
    
    /// Opens the workspace's tabs after the existing ones and returns the index of the first new tab.
    @discardableResult
    func openWorkspace(_ workspace: ProductivityTools.Workspace) -> Int {
        let first = sessions.count
        for tab in workspace.tabs {
            var directory: URL?
            var isDir: ObjCBool = false
            if let path = tab.cwd, FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue {
                directory = URL(fileURLWithPath: path)
            }
            addSession(initialCWD: directory, name: tab.title, color: TabColor(rawValue: tab.color) ?? .default)
        }
        return first
    }
    
    func updateTabName(for sessionId: UUID, name: String) {
        if var metadata = tabMetadata[sessionId] {
            metadata.name = name
            tabMetadata[sessionId] = metadata
            persistSnapshot()
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
        persistSnapshot()
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
