import Foundation

/// Errors that can occur while launching an SSH session.
enum SSHError: LocalizedError {
  case launchFailed(Error)
  case invalidHost(String)  // Empty or malformed host string

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
  ///   - port: Optional port number (defaults to 22 if not specified).
  ///   - keyPath: Optional path to SSH private key file.
  ///   - password: Optional password; when provided the function will try to use
  ///               `sshpass` (if installed) to supply it non‑interactively.
  ///   - shellManager: The app‑wide `ShellManager` used to create the
  ///                   `TerminalSession`.
  /// - Returns: `.success` with a configured `TerminalSession` or `.failure`
  ///            with an `SSHError`.
  func startSSH(
    to host: String,
    user: String? = nil,
    port: Int? = nil,
    keyPath: String? = nil,
    password: String? = nil,
    shellManager: ShellManager
  ) -> Result<TerminalSession, SSHError> {

    // Guard against an empty host string – this would produce the
    // "Could not resolve hostname" error we saw before.
    guard !host.isEmpty else { return .failure(.invalidHost(host)) }

    // Create the session that will own the PTY.
    let session = TerminalSession(shellManager: shellManager)

    // -----------------------------------------------------------------
    // Build the ssh command using a dedicated builder (unifies logic).
    // -----------------------------------------------------------------
    let builder = SSHArgsBuilder()
    let opts = SSHArgsBuilder.Options(
      host: host,
      user: user,
      port: port,
      identityFile: keyPath,
      password: password,
      strictHostKeyChecking: false,
      serverAliveInterval: 60,
      serverAliveCountMax: 3,
      connectTimeout: 30,
      preferredAuthentications: "password,publickey,keyboard-interactive"
    )
    let cmd = builder.build(opts)
    let execPath = cmd.execPath
    let args = cmd.args

    // -----------------------------------------------------------------
    // Launch the command via PTYWrapper.
    // -----------------------------------------------------------------

    // Set up environment for SSH
    // SSH_ASKPASS: Path to helper script that will prompt for password
    // DISPLAY: Required for SSH_ASKPASS to work
    // TERM: Terminal type. Using 'xterm' instead of 'xterm-256color'
    // for better compatibility with older Cisco/ASA devices.
    let askpassPath = Bundle.main.path(forResource: "ssh-askpass", ofType: "sh") ?? ""
    var sshEnv = [
      "TERM": "xterm",
      "SSH_ASKPASS": askpassPath,
      "DISPLAY": ":0",
      "SSH_ASKPASS_REQUIRE": "force",
    ]

    // If a password is provided, pass it in the environment so the askpass script can use it
    if let pwd = password, !pwd.isEmpty {
      sshEnv["PROTERM_SSH_PASSWORD"] = pwd
    }


    let handler = PTYWrapper(command: execPath, args: args, env: sshEnv)


    // Get session ID for use in closures (avoid capturing session object)
    let sessionId = session.id

    // Attach the PTY to the session (stores master FD, child PID, etc.).
    // Must call on main actor since attachPTY is @MainActor
    // PTYWrapper is now @unchecked Sendable, so passing it is safe
    // isSSH=true completely disables IO features for SSH sessions

    // Use a semaphore to wait for main-thread setup completion
    let semaphore = DispatchSemaphore(value: 0)

    DispatchQueue.main.async {
      session.attachPTY(handler, isSSH: true)

      handler.startReading { [sessionId] text in
        DispatchQueue.main.async {
          NotificationCenter.default.post(
            name: .sshPTYOutput, object: sessionId, userInfo: ["text": text])
        }
      }

      semaphore.signal()
    }

    // Wait for setup to complete (with short timeout)
    _ = semaphore.wait(timeout: .now() + 1.0)


    // Monitor child exit – post a notification for the session so the
    // session can perform cleanup on the main actor. Avoid capturing
    // `session` or `handler` into this background handler.
    let monitor = DispatchSource.makeProcessSource(
      identifier: handler.childPID,
      eventMask: .exit,
      queue: DispatchQueue.global(qos: .userInitiated))
    monitor.setEventHandler {
      DispatchQueue.main.async {
        NotificationCenter.default.post(name: .sshPTYExit, object: sessionId)
      }
    }
    monitor.resume()

    // Verify the SSH process is still running after initialization
    // Give it a brief moment to fail if there's an immediate error
    usleep(100_000)  // 100ms

    if !handler.isRunning {
      monitor.cancel()
      return .failure(
        .launchFailed(
          NSError(
            domain: "SSHSessionManager",
            code: 1,
            userInfo: [
              NSLocalizedDescriptionKey:
                "SSH process exited immediately. Check your connection settings, hostname, and credentials."
            ]
          )))
    }

    return .success(session)
  }
}
