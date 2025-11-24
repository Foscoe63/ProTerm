import Foundation

/// Errors that can occur while launching an SSH session.
enum SSHError: LocalizedError {
    case launchFailed(Error)
    case invalidHost(String)   // Empty or malformed host string

    var errorDescription: String? {
        switch self {
        case .launchFailed(let err):
            return "Failed to start SSH: \(err.localizedDescription)"
        case .invalidHost(let host):
            return "Invalid SSH host: ‘\(host)’. Please check the connection settings."
        }
    }
}

/// Minimal wrapper that spawns an `ssh` process and pipes its I/O into a
/// `TerminalSession`. The implementation now uses a PTY so the remote shell stays
/// interactive after authentication.
final class SSHSessionManager: @unchecked Sendable {
    static let shared = SSHSessionManager()

    /// Starts an SSH session.
    /// - Parameters:
    ///   - host: Remote hostname or IP address.
    ///   - user: Optional username; if supplied it is passed with `-l`.
    ///   - password: Optional password; when provided the function will try to use
    ///               `sshpass` (if installed) to supply it non‑interactively.
    ///   - shellManager: The app‑wide `ShellManager` used to create the
    ///                   `TerminalSession`.
    /// - Returns: `.success` with a configured `TerminalSession` or `.failure`
    ///            with an `SSHError`.
    func startSSH(to host: String,
                  user: String? = nil,
                  password: String? = nil,
                  shellManager: ShellManager) -> Result<TerminalSession, SSHError> {

        // Guard against an empty host string – this would produce the
        // "Could not resolve hostname" error we saw before.
        guard !host.isEmpty else { return .failure(.invalidHost(host)) }

        // Create the session that will own the PTY.
        let session = TerminalSession(shellManager: shellManager)

        // -----------------------------------------------------------------
        // Build the ssh command line that will be executed via PTYWrapper.
        // -----------------------------------------------------------------
        var execPath = "/usr/bin/ssh"
        var args: [String] = []

        // Allocate a PTY on the remote side so we get an interactive shell.
        args.append("-tt")

        // Username flag (if supplied).
        if let u = user { args += ["-l", u] }

        // Password handling – prefer sshpass when it exists.
        if let pwd = password {
            let possible = ["/usr/local/bin/sshpass",
                           "/opt/homebrew/bin/sshpass",
                           "/usr/bin/sshpass"]
            if let sshpass = possible.first(where: { FileManager.default.fileExists(atPath: $0) }) {
                execPath = sshpass
                args.append(contentsOf: ["-p", pwd, "ssh"])
            }
        }

        // Finally the host argument.
        args.append(host)

        // -----------------------------------------------------------------
        // Launch the command via PTYWrapper.
        // -----------------------------------------------------------------
        let handler = PTYWrapper(command: execPath, args: args)

        // Attach the PTY to the session (stores master FD, child PID, etc.).
        session.attachPTY(handler)

        // Forward PTY output to the UI.
        handler.startReading { [weak session] text in
            DispatchQueue.main.async {
                guard let s = session else { return }
                var out = s.output
                if !out.hasSuffix("\n") && !out.isEmpty { out += "\n" }
                s.output = out + text
            }
        }

        // Monitor child exit – when the remote shell ends we clear flags.
        let monitor = DispatchSource.makeProcessSource(identifier: handler.childPID,
                                                      eventMask: .exit,
                                                      queue: DispatchQueue.global(qos: .userInitiated))
        monitor.setEventHandler { [weak session] in
            DispatchQueue.main.async {
                session?.isProcessRunning = false
                handler.stop()
            }
        }
        monitor.resume()

        return .success(session)
    }
}
