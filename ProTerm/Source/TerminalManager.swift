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
    
    /// Reference to shell manager for creating new sessions
    private var shellManager: ShellManager?

    /// Restore persisted session IDs (or create a default session).
    init() {
        let savedIDs = SessionPersistence.shared.load()
        if savedIDs.isEmpty {
            addSession()               // create a default first session
        } else {
            for _ in savedIDs { addSession() }
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
            return
        }
        let session = TerminalSession(shellManager: shellManager)
        sessions.append(session)
    }

    func closeSession(at index: Int) {
        guard sessions.indices.contains(index) else { return }
        NotificationHelper.shared.notify(
            title: "Session Closed",
            body: "Closed session \(index + 1)"
        )
        sessions.remove(at: index)
    }

    // MARK: – Helper
    func reportCompletion(of cmd: String) {
        NotificationHelper.shared.notify(
            title: "Command Finished",
            body: "\(cmd) completed."
        )
    }
}
