import Combine
import Darwin
import Foundation
import SwiftUI

// Note: We'll use availableData directly with shutdown flag checks
// The shutdown flag prevents reading from closed FDs

// PTY constants
private let TIOCSCTTY: UInt = 0x2000_7461
private let TIOCSWINSZ: UInt = 0x8008_7467

/// Ultra-minimal terminal session with ZERO complexity
final class TerminalSession: NSObject, ObservableObject, Identifiable, @unchecked Sendable {
  let id = UUID()

  @Published var output: String = ""
  @Published var isProcessRunning: Bool = false
  @Published var lastCommandExecutionTime: TimeInterval? = nil

  // Limit output size to prevent performance issues
  // Read from UserDefaults to respect user's scrollback settings
  private var maxOutputLength: Int {
    let limit = UserDefaults.standard.integer(forKey: "ProTermScrollbackLimit")
    let enabled = UserDefaults.standard.object(forKey: "ProTermScrollbackEnabled") as? Bool ?? true
    
    if enabled {
        // Enforce a sensible minimum to prevent "single page" bugs if UserDefault is weird
        if limit < 10000 { return 1000000 } // Default 1MB if unconfigured or too small
        return limit
    }
    return 100000 // Fallback if disabled (should be enough for a few pages)
  }
  private var commandStartTime: Date?

  var cwd: URL = FileManager.default.homeDirectoryForCurrentUser
  private let shellManager: ShellManager

  // Terminal width for COLUMNS environment variable
  var terminalWidth: CGFloat = 80 {
    didSet {
      // Only update columns from width if no preference is set
      // Otherwise, respect the user's configured preference
      let defaults = UserDefaults.standard
      let hasConfiguredColumns = defaults.object(forKey: "ProTermTerminalColumns") != nil
      if !hasConfiguredColumns {
        updateColumns()
      }
      // Propagate window-size changes to the PTY if active
      applyTTYSettingsIfNeeded()
    }
  }

  // Character width for accurate column calculation
  var characterWidth: CGFloat = 7.2 {
    didSet {
      let defaults = UserDefaults.standard
      let hasConfiguredColumns = defaults.object(forKey: "ProTermTerminalColumns") != nil
      if !hasConfiguredColumns {
        updateColumns()
      }
      applyTTYSettingsIfNeeded()
    }
  }

  private var columns: Int = 80

  // Strong references for running process and I/O to ensure handlers fire
  private var outputReadHandle: FileHandle?

  // PTY support for interactive commands like sudo
  private var masterFD: Int32 = -1
  private var slaveFD: Int32 = -1
  private var ptyHandler: PTYWrapper?
  private var ptyReadHandle: FileHandle?
  private var ptyReadSource: DispatchSourceRead?
  // PTY wrapper handling interactive sessions

  private let ptyReadQueue = DispatchQueue(label: "proterm.pty.read")
  private var utf8Remainder = Data()
  private var oscSequenceRemainder = ""
  private var isShuttingDown: Bool = false
  // Child PID for forkpty-based interactive sessions
  private var childPID: pid_t = 0
  private var childExitSource: DispatchSourceProcess?

  // Thread-safe shutdown flag for PTY readers
  // Accessed across threads; write from main actor, read from background queues.
  private let shutdownFlag = AtomicBool(false)

  // Cached rows estimate (height). We don’t track actual pixel height here,
  // use a sensible default; can be exposed later for dynamic sizing
  private var rows: Int = 24

  private var bracketedPasteEnabled: Bool
  private var mouseReportingEnabled: Bool
  private var ioFeaturesApplied = false
  private var ioSettingsObserver: NSObjectProtocol?
  private var externalPTYOutputObserver: NSObjectProtocol?
  private var externalPTYExitObserver: NSObjectProtocol?
  private var pendingCR = false // Track for cross-chunk Carriage Return handling

  private enum IOSettingKey {
    static let bracketed = "ProTermBracketedPaste"
    static let mouse = "ProTermMouseReporting"
  }



  private func updateColumns() {
    // Calculate columns based on terminal width
    // Use the actual character width provided by the view
    // The terminalWidth passed in already accounts for padding and line numbers
    let availableWidth = max(40, terminalWidth)  // Minimum 40 points
    let charWidth = max(1.0, characterWidth)     // Avoid division by zero
    let calculatedColumns = Int(availableWidth / charWidth)
    
    // Clamp to reasonable range for a terminal
    self.columns = max(40, min(500, calculatedColumns))
  }

  // Ensure the output ends with exactly one newline (no prompt is appended here)
  // Idempotent: multiple calls will not add extra blank lines.
  // IMPORTANT: If the output is currently empty, do NOT append a newline.
  // Otherwise the very first command would start on line 2 visually.
  private func ensureSingleTrailingNewline() {
    var out = self.output
    // Remove all trailing newlines (\n, \r\n, or \r)
    while out.hasSuffix("\r\n") || out.hasSuffix("\n") || out.hasSuffix("\r") {
      if out.hasSuffix("\r\n") {
        out = String(out.dropLast(2))
      } else {
        out = String(out.dropLast(1))
      }
    }
    // If there's no content yet, keep it empty (no leading blank line)
    guard !out.isEmpty else {
      self.output = ""
      return
    }
    // Otherwise, append exactly one newline
    self.output = self.limitOutputSize(out + "\n")
  }

  // Access the selected shell path safely with respect to MainActor isolation
  private func currentShellPath() -> String {
    // If we're already on the main thread, read via MainActor.assumeIsolated
    // to satisfy static actor isolation checks.
    if Thread.isMainThread {
      return MainActor.assumeIsolated { shellManager.selectedShell.executablePath }
    }
    // Otherwise, synchronously hop to the main queue and read under MainActor.
    var path = "/bin/zsh"
    DispatchQueue.main.sync {
      path = MainActor.assumeIsolated { shellManager.selectedShell.executablePath }
    }
    return path
  }

  // Apply TTY attributes (raw mode, window size) when we have an active PTY
  private func applyTTYSettingsIfNeeded() {
    let sfd = self.slaveFD
    if sfd >= 0 {
      setWindowSize(fd: sfd, cols: UInt16(columns), rows: UInt16(rows))
      setRawMode(fd: sfd)
      return
    }
    if self.masterFD >= 0 {
      setWindowSize(fd: self.masterFD, cols: UInt16(columns), rows: UInt16(rows))
    }
  }

  // Set the terminal window size using C shim (ioctl wrapper)
  private func setWindowSize(fd: Int32, cols: UInt16, rows: UInt16) {
    var ws = winsize()
    ws.ws_col = cols
    ws.ws_row = rows
    ws.ws_xpixel = 0
    ws.ws_ypixel = 0
    _ = ioctl(fd, TIOCSWINSZ, &ws)
    // Notify child of resize so TUIs react immediately
    var targetPid: pid_t = 0
    if childPID > 0 {
      targetPid = childPID
    } else if let p = process?.processIdentifier, p > 0 {
      targetPid = p
    }
    
    // For attached PTYs (like SSH), childPID is set. Ensure we signal it.
    if targetPid > 0 {
      _ = kill(targetPid, SIGWINCH)
    }
  }

  // Put an FD into non-blocking mode to avoid blocking reads/writes in I/O loops
  private func setNonBlocking(_ fd: Int32) {
    let current = fcntl(fd, F_GETFL)
    if current >= 0 {
      _ = fcntl(fd, F_SETFL, current | O_NONBLOCK)
    }
  }

  // Validate that a file descriptor is still open/valid
  private func isFDValid(_ fd: Int32) -> Bool {
    if fd < 0 { return false }
    errno = 0
    let flags = fcntl(fd, F_GETFL)
    if flags != -1 { return true }
    // If EBADF, the descriptor is invalid/closed
    return errno != EBADF
  }

  // Check if a PID is still alive (returns true if process exists)
  private func isPIDAlive(_ pid: pid_t) -> Bool {
    if pid <= 0 { return false }
    let result = kill(pid, 0)
    if result == 0 { return true }
    return errno != ESRCH
  }

  private func refreshIOFeatureFlags() {
    let defaults = UserDefaults.standard
    let newBracketed = defaults.object(forKey: IOSettingKey.bracketed) as? Bool ?? true
    let newMouse = defaults.object(forKey: IOSettingKey.mouse) as? Bool ?? false
    let flagsChanged =
      (newBracketed != bracketedPasteEnabled) || (newMouse != mouseReportingEnabled)
    bracketedPasteEnabled = newBracketed
    mouseReportingEnabled = newMouse
    if flagsChanged && hasActivePTY {
      tearDownIOFeatures()
      configureIOFeaturesForActivePTY()
    }
  }

  private func configureIOFeaturesForActivePTY() {
    // Never configure IO features for SSH sessions
    guard hasActivePTY, !ioFeaturesApplied, !isSSHSession else { return }
    if bracketedPasteEnabled {
      sendInput("\u{001B}[?2004h")
    }
    if mouseReportingEnabled {
      sendInput("\u{001B}[?1000h")
      sendInput("\u{001B}[?1006h")
    }
    ioFeaturesApplied = true
  }

  private func tearDownIOFeatures() {
    guard ioFeaturesApplied, hasActivePTY else {
      ioFeaturesApplied = false
      return
    }
    if bracketedPasteEnabled {
      sendInput("\u{001B}[?2004l")
    }
    if mouseReportingEnabled {
      sendInput("\u{001B}[?1000l")
      sendInput("\u{001B}[?1006l")
    }
    ioFeaturesApplied = false
  }

  // MARK: - PTY Read Source (DispatchSourceRead)
  private func startPTYReadSource(masterFD: Int32) {
    // Cancel any existing source first
    ptyReadSource?.cancel()
    ptyReadSource = nil

    guard masterFD >= 0 else { return }

    let source = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: ptyReadQueue)
    ptyReadSource = source
    // Keep a local UTF-8 remainder buffer to avoid accessing MainActor state from this queue
    var localUTF8Remainder = Data()
    // Prepare main-thread append closure
    let appendOnMain: (String) -> Void = { [weak self] s in
      Task { @MainActor [weak self] in
        self?.handleOutputChunkOnMain(s)
      }
    }

    source.setEventHandler {
      var buffer = [UInt8](repeating: 0, count: 8192)
      while true {
        let n = read(masterFD, &buffer, buffer.count)
        if n > 0 {
          let chunkData = Data(buffer[0..<n])
          
          // Combine with any previous remainder to handle split UTF-8 sequences
          var combined = Data()
          if !localUTF8Remainder.isEmpty { combined.append(localUTF8Remainder) }
          combined.append(chunkData)

          var toAppend = ""
          if let full = String(data: combined, encoding: .utf8) {
            localUTF8Remainder.removeAll(keepingCapacity: true)
            toAppend = full
          } else {
            // If decoding fails, it might be a partial multibyte character at the end
            var cut = combined.count
            let maxTail = min(4, combined.count)
            var decoded: String? = nil
            
            // Try to find the last valid split point
            for tail in 1...maxTail {
              let headCount = combined.count - tail
              if headCount <= 0 { break }
              if let s = String(data: combined.prefix(headCount), encoding: .utf8) {
                decoded = s
                cut = headCount
                break
              }
            }
            
            if let d = decoded {
              toAppend = d
              localUTF8Remainder = combined.suffix(combined.count - cut)
            } else {
              // Complete failure, force decode as much as possible
              toAppend = String(decoding: combined, as: UTF8.self)
              localUTF8Remainder.removeAll()
            }
          }

          if !toAppend.isEmpty {
            let normalized = toAppend.precomposedStringWithCanonicalMapping
            appendOnMain(normalized)
          }
        } else if n == 0 {
          source.cancel()
          break
        } else {
          if errno == EAGAIN || errno == EWOULDBLOCK { break }
          source.cancel()
          break
        }
      }
    }

    source.setCancelHandler { [weak self] in
      // Cleanup PTY and restore prompt on main
      DispatchQueue.main.async { [weak self] in
        guard let strongSelf = self else { return }
        strongSelf.isShuttingDown = true
        strongSelf.shutdownFlag.set(true)
        strongSelf.tearDownIOFeatures()
        let closeMaster = strongSelf.masterFD
        strongSelf.masterFD = -1
        if closeMaster >= 0 {
          DispatchQueue.global(qos: .userInitiated).async {
            close(closeMaster)
          }
        }
        strongSelf.isProcessRunning = false
        // Reset SSH session flag if this was an SSH session
        if strongSelf.isSSHSession {
          strongSelf.isSSHSession = false
          // Notify IntegrationFeatures to disconnect
          NotificationCenter.default.post(
            name: Notification.Name("ProTermSSHSessionClosed"),
            object: strongSelf.id
          )
        }
        strongSelf.ensureSingleTrailingNewline()
        strongSelf.ptyReadHandle = nil
        strongSelf.slaveFD = -1
        strongSelf.childPID = 0
        strongSelf.childExitSource?.cancel()
        strongSelf.childExitSource = nil
        strongSelf.isShuttingDown = false
        strongSelf.shutdownFlag.set(false)
      }
    }

    source.resume()
  }

  // Put the TTY into a raw-like mode (no echo, canonical processing off)
  private func setRawMode(fd: Int32) {
    var tio = termios()
    if tcgetattr(fd, &tio) != 0 { return }
    // Use system helper to configure raw mode safely
    cfmakeraw(&tio)
    _ = tcsetattr(fd, TCSAFLUSH, &tio)
  }

  var prompt: String {
    // For SSH sessions, don't show a local prompt - the remote server provides its own
    if isSSHSession {
      return ""
    }

    // Check for custom prompt
    let useCustom = UserDefaults.standard.bool(forKey: "ProTermUseCustomPrompt")
    if useCustom, let customPrompt = UserDefaults.standard.string(forKey: "ProTermCustomPrompt"),
      !customPrompt.isEmpty
    {
      return expandCustomPrompt(customPrompt)
    }

    // Default prompt
    let user = NSUserName()
    let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    var displayPath = cwd.path.replacingOccurrences(of: homePath, with: "~")
    if displayPath.isEmpty { displayPath = "~" }

    // Add git branch if in a git repository
    var gitInfo = ""
    if GitIntegration.isGitRepository(cwd),
      let branch = GitIntegration.getCurrentBranch(in: cwd)
    {
      gitInfo = " [\(branch)]"
    }

    return "\(user)@\(host) \(displayPath)\(gitInfo) % "
  }

  private func expandCustomPrompt(_ format: String) -> String {
    let user = NSUserName()
    let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    var displayPath = cwd.path.replacingOccurrences(of: homePath, with: "~")
    if displayPath.isEmpty { displayPath = "~" }

    var gitBranch = ""
    if GitIntegration.isGitRepository(cwd),
      let branch = GitIntegration.getCurrentBranch(in: cwd)
    {
      gitBranch = branch
    }

    return
      format
      .replacingOccurrences(of: "%u", with: user)
      .replacingOccurrences(of: "%h", with: host)
      .replacingOccurrences(of: "%d", with: displayPath)
      .replacingOccurrences(of: "%b", with: gitBranch.isEmpty ? "" : "[\(gitBranch)]")
  }

  init(shellManager: ShellManager) {
    self.shellManager = shellManager
    let defaults = UserDefaults.standard
    self.bracketedPasteEnabled = defaults.object(forKey: IOSettingKey.bracketed) as? Bool ?? true
    self.mouseReportingEnabled = defaults.object(forKey: IOSettingKey.mouse) as? Bool ?? false
    super.init()
    // Initialize columns from UserDefaults preference (default: 80)
    let configuredColumns = defaults.object(forKey: "ProTermTerminalColumns") as? Int ?? 80
    self.columns = max(40, min(200, configuredColumns))  // Clamp to valid range
    // Don't add prompt to output - it's shown inline in the input area
    output = ""
    ioSettingsObserver = NotificationCenter.default.addObserver(
      forName: .proTermIOSettingsDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      self?.refreshIOFeatureFlags()
    }

    // Observe terminal columns preference changes
    NotificationCenter.default.addObserver(
      forName: .proTermTerminalColumnsDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      guard let self = self else { return }
      let defaults = UserDefaults.standard
      let configuredColumns = defaults.object(forKey: "ProTermTerminalColumns") as? Int ?? 80
      self.columns = max(40, min(200, configuredColumns))
      // Update COLUMNS environment variable for future commands
      // Apply window size changes to active PTY if needed
      self.applyTTYSettingsIfNeeded()
    }

    // Observe external PTY output (e.g., SSH sessions launched by
    // `SSHSessionManager`). The manager posts notifications with the
    // session id as the object so we avoid sending the `TerminalSession`
    // reference into background closures.
    externalPTYOutputObserver = NotificationCenter.default.addObserver(
      forName: .sshPTYOutput,
      object: nil,
      queue: .main
    ) { [weak self] note in
      guard let self = self else { return }
      // Filter by session ID manually to ensure we only process our own notifications
      guard let noteSessionId = note.object as? UUID, noteSessionId == self.id else {
        return
      }
      guard let text = note.userInfo?["text"] as? String else {
        return
      }
      
      // Append chunk exactly as received - do NOT add local newlines between chunks
      // as it breaks character-at-a-time echoing in interactive sessions.
      Task { @MainActor in
        self.appendOutputChunk(text)
      }
    }

    externalPTYExitObserver = NotificationCenter.default.addObserver(
      forName: .sshPTYExit,
      object: self.id,
      queue: .main
    ) { [weak self] _ in
      guard let strongSelf = self else { return }
      strongSelf.isShuttingDown = true
      strongSelf.shutdownFlag.set(true)
      strongSelf.tearDownIOFeatures()
      if let handler = strongSelf.ptyHandler {
        handler.stop()
        strongSelf.ptyHandler = nil
      }
      strongSelf.isProcessRunning = false

      // If this is an SSH session, reset the flag and notify IntegrationFeatures to disconnect
      if strongSelf.isSSHSession {
        strongSelf.isSSHSession = false  // Reset so prompt will show after SSH exits
        NotificationCenter.default.post(
          name: Notification.Name("ProTermSSHSessionClosed"),
          object: strongSelf.id
        )
      }

      let closeMaster = strongSelf.masterFD
      strongSelf.masterFD = -1
      if closeMaster >= 0 {
        DispatchQueue.global(qos: .userInitiated).async {
          close(closeMaster)
        }
      }
      strongSelf.slaveFD = -1
      strongSelf.childPID = 0
      strongSelf.ensureSingleTrailingNewline()
      strongSelf.isShuttingDown = false
      strongSelf.shutdownFlag.set(false)

      // After an interactive session ends, proactively refocus the command input
      NotificationCenter.default.post(
        name: Notification.Name("ProTermFocusCommandInput"), object: strongSelf.id)
    }
  }

  deinit {
    if let observer = ioSettingsObserver {
      NotificationCenter.default.removeObserver(observer)
    }
    if let obs = externalPTYOutputObserver {
      NotificationCenter.default.removeObserver(obs)
    }
    if let obs = externalPTYExitObserver {
      NotificationCenter.default.removeObserver(obs)
    }
  }

  @MainActor
  func runCommand(_ command: String) {
    let sanitized = command.sanitizedTerminalCommand()
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // Record history of commands submitted
    commandHistory.append(trimmed)

    // Prevent re-execution, but also check if process is actually still running
    if isProcessRunning {
      // Safety check: verify the process or PTY handler is still active
      var processStillRunning = false
      if let proc = process {
        processStillRunning = proc.isRunning
      } else if let handler = ptyHandler {
        processStillRunning = handler.isRunning
      } else if childPID > 0 {
        processStillRunning = isPIDAlive(childPID)
      }

      // We only need a valid masterFD; slaveFD is typically closed in the parent process
      let hasValidFD = masterFD >= 0 || (ptyHandler?.masterFD ?? -1) >= 0

      if !processStillRunning || !hasValidFD {
        // Process has terminated or FDs are invalid - clean up immediately
        isProcessRunning = false
        ptyReadHandle?.readabilityHandler = nil
        shutdownFlag.set(true)
        isShuttingDown = true

        // Close file descriptors
        if slaveFD >= 0 {
          let fd = slaveFD
          DispatchQueue.global(qos: .userInitiated).async {
            close(fd)
          }
          slaveFD = -1
        }
        if masterFD >= 0 {
          let fd = masterFD
          DispatchQueue.global(qos: .userInitiated).async {
            close(fd)
          }
          masterFD = -1
        }

        ptyReadHandle = nil
        process = nil
        isShuttingDown = false
        shutdownFlag.set(false)

        // Ensure a single trailing newline (no prompt appended)
        ensureSingleTrailingNewline()

        // Continue with the command
      } else if hasActivePTY {
        // Process is running and has active PTY - allow input to be sent to it
        // This is handled in TerminalView
        return
      } else {
        // Process is running but no active PTY - don't allow new commands
        return
      }
    }

    // Record the command in the output buffer on its own line
    // Ensure we are at a new line first, then append the command and a newline
    ensureSingleTrailingNewline()
    appendOutputChunk("\(sanitized)\n")

    // Handle cd command
    if trimmed.hasPrefix("cd ") {
      let target = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
      changeDirectory(to: target)
      // After changing directory, just end the line; inline prompt handles display
      if !output.hasSuffix("\n") { output.append("\n") }
      return
    }

    // Handle sudo command with PTY (case-insensitive)
    if trimmed.lowercased().hasPrefix("sudo") {
      runSudoCommand(sanitized)
      return
    }

    // Handle interactive commands with PTY (python, python3, node, ssh, etc.)
    let interactiveCommands = [
      "python", "python3", "node", "irb", "ruby", "ghci", "ipython", "ssh",
    ]
    let commandName = trimmed.components(separatedBy: .whitespaces).first?.lowercased() ?? ""
    if interactiveCommands.contains(commandName) {
      // Add newline after command so output appears on next line
      if !output.hasSuffix("\n") {
        output.append("\n")
      }
      runInteractiveCommand(sanitized)
      return
    }

    // Handle ls command - force column output since we're not a real TTY
    var commandToRun = sanitized
    if trimmed == "ls" || trimmed.hasPrefix("ls ") {
      // Check if column formatting flags are already specified
      let hasColumnFlag =
        trimmed.contains(" -C") || trimmed.contains(" -x") || trimmed.contains(" -1")
        || trimmed.contains(" -l") || trimmed.contains(" -la") || trimmed.contains(" -lh")
        || trimmed.contains(" -lt") || trimmed.contains(" -ltr")

      if !hasColumnFlag {
        // Add -C flag to force column output (horizontal and vertical)
        if trimmed == "ls" {
          commandToRun = "ls -C"
        } else {
          // Insert -C after "ls" but before any other arguments
          let parts = command.components(separatedBy: .whitespaces)
          if parts.first?.lowercased() == "ls" {
            var newParts = [parts[0], "-C"]
            newParts.append(contentsOf: parts.dropFirst())
            commandToRun = newParts.joined(separator: " ")
          }
        }
      }
    }

    // Run other commands via ProcessRunner (asynchronously; do NOT block the main actor)
    let shellPath = currentShellPath()
    let effectiveColumns = max(80, columns)

    // Mark running and command start time
    self.isProcessRunning = true
    self.commandStartTime = Date()

    let runner = ProcessRunner()
    _ = runner.run(
      shellPath: shellPath,
      command: commandToRun,
      cwd: cwd,
      columns: effectiveColumns,
      rows: 24,
      onOutput: { [weak self] chunk in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          var outputToAdd = chunk
          if !self.output.hasSuffix("\n") && !self.output.isEmpty {
            outputToAdd = "\n" + chunk
          }
          self.appendOutputChunk(outputToAdd)
        }
      },
      onBell: { [weak self] in
        guard let self = self else { return }
        NotificationCenter.default.post(
          name: Notification.Name("ProTermTerminalBell"), object: self.id)
      },
      onComplete: { [weak self] in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          self.isProcessRunning = false
          if let startTime = self.commandStartTime {
            self.lastCommandExecutionTime = Date().timeIntervalSince(startTime)
            self.commandStartTime = nil
          }
          self.ensureSingleTrailingNewline()
        }
      },
      onError: { [weak self] error in
        Task { @MainActor [weak self] in
          guard let self = self else { return }
          ErrorHandler.shared.logError(
            message: "Failed to execute command: \(sanitized)",
            type: .commandExecution,
            command: sanitized,
            sessionId: self.id
          )
          // Ensure current output line ends, then append the error
          var current = self.output
          while current.hasSuffix("\n") || current.hasSuffix("\r\n") || current.hasSuffix("\r") {
            if current.hasSuffix("\r\n") {
              current = String(current.dropLast(2))
            } else {
              current = String(current.dropLast(1))
            }
          }
          self.output = current
          self.appendOutputChunk("\nError: \(error.localizedDescription)\n")
          self.isProcessRunning = false
        }
      }
    )
  }

  @MainActor
  private func changeDirectory(to path: String) {
    guard !path.isEmpty else {
      // Empty path means cd to home directory
      self.cwd = FileManager.default.homeDirectoryForCurrentUser
      return
    }

    var newURL = self.cwd
    if path == "~" {
      newURL = FileManager.default.homeDirectoryForCurrentUser
    } else if path.hasPrefix("/") {
      // Absolute path
      newURL = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      // Relative path - append to current directory
      newURL = self.cwd.appendingPathComponent(path, isDirectory: true)
    }

    // Resolve symlinks and standardize the path
    newURL = newURL.standardizedFileURL

    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: newURL.path, isDirectory: &isDir), isDir.boolValue {
      self.cwd = newURL
    } else {
      // Enhanced error handling
      DispatchQueue.main.async {
        ErrorHandler.shared.logError(
          message: "cd: \(path): No such file or directory",
          type: .fileSystem,
          command: "cd \(path)",
          sessionId: self.id
        )
      }
      if !self.output.hasSuffix("\n") {
        self.appendOutputChunk("\n")
      }
      self.appendOutputChunk("cd: \(path): No such file or directory\n")
    }
  }

  // MARK: - PTY-based command execution

  @MainActor
  private func runInteractiveCommand(_ command: String) {
    // Detect SSH commands and run them directly (not through shell)
    // SSH needs direct execution to maintain proper PTY connection
    let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
    let isSSHCommand = trimmedCommand.hasPrefix("ssh ") || trimmedCommand.hasPrefix("SSH ")

    if isSSHCommand {
      // Parse SSH command and build direct execution args
      let parts = trimmedCommand.components(separatedBy: .whitespaces).filter { !$0.isEmpty }
      
      var sshArgs = ["/usr/bin/ssh", "-tt"]
      // Inject standard compatibility flags for Cisco / legacy gear
      sshArgs.append(contentsOf: [
        "-o", "PreferredAuthentications=password,keyboard-interactive",
        "-o", "PubkeyAuthentication=no",
        "-o", "StrictHostKeyChecking=no",
        "-o", "NumberOfPasswordPrompts=3",
        "-o", "KexAlgorithms=+diffie-hellman-group1-sha1,diffie-hellman-group14-sha1",
        "-o", "HostKeyAlgorithms=+ssh-rsa",
        "-o", "Ciphers=+aes128-cbc,3des-cbc,aes256-cbc"
      ])
      
      // Add user's original arguments (skip "ssh")
      sshArgs.append(contentsOf: parts.dropFirst())
      
      
      // Setup C-style args
      let cArgs = sshArgs.map { strdup($0) }
      let argvPointers: [UnsafeMutablePointer<CChar>?] = cArgs.map { $0 } + [nil]
      
      // Environment
      let envVars = ["TERM": "xterm"]
      let cEnvStrings = envVars.map { strdup("\($0.key)=\($0.value)") }
      let envPointers: [UnsafeMutablePointer<CChar>?] = cEnvStrings.map { $0 } + [nil]
      
      var master: Int32 = -1
      
      let pid = argvPointers.withUnsafeBufferPointer { argvBuf in
        envPointers.withUnsafeBufferPointer { envvBuf in
          proterm_forkpty_exec("/usr/bin/ssh", 
                               UnsafeMutablePointer(mutating: argvBuf.baseAddress),
                               UnsafeMutablePointer(mutating: envvBuf.baseAddress),
                               &master, UInt16(rows), UInt16(columns))
        }
      }
      
      // Cleanup C strings after exec finishes
      for ptr in cArgs { free(ptr) }
      for ptr in cEnvStrings { free(ptr) }
      
      guard pid > 0, master >= 0 else {
        appendOutputChunk("\nError: Failed to start SSH session\n")
        return
      }
      
      self.masterFD = master
      self.childPID = pid
      self.isProcessRunning = true
      self.isSSHSession = true
      
      // Set PTY to non-blocking mode
      setNonBlocking(master)
      
      // Set window size for the PTY (important for SSH)
      // Note: We don't set raw mode here - SSH will configure the TTY as needed
      setWindowSize(fd: master, cols: UInt16(columns), rows: UInt16(rows))
      
      // Monitor the child process to detect when it exits
      monitorChildProcess(pid: pid)
      
      // Start reading from PTY
      startPTYReadSource(masterFD: master)
    } else {
      // Use PTY for other interactive commands via shell
      runPTYCommandWithHelper(command)
    }
  }





  @MainActor
  private func runSudoCommand(_ command: String) {
    // Use PTY for sudo with full terminal setup (needs helper for setsid)
    runPTYCommandWithHelper(command)
  }

  @MainActor
  private func runPTYCommandSimple(_ command: String) {
    do {
      let handler = try PTYWrapper(
        shellPath: self.currentShellPath(),
        command: command,
        rows: self.rows,
        columns: self.columns,
        cwd: self.cwd
      )
      // Keep reference for later use (e.g., sending input, termination)
      self.ptyHandler = handler
      // Preserve old properties for compatibility with other parts of the code
      self.masterFD = handler.masterFD
      self.childPID = handler.childPID
      self.isProcessRunning = true
      self.process = nil  // Not using Foundation.Process in forkpty path

      // Monitor the child process to detect when it exits
      monitorChildProcess(pid: handler.childPID)

      // Start reading PTY output and forward it to the UI
      handler.startReading { [weak self] text in
        Task { @MainActor [weak self] in
          guard let strongSelf = self else { return }
          var outputToAdd = text
          if !strongSelf.output.hasSuffix("\n") && !strongSelf.output.isEmpty {
            outputToAdd = "\n" + text
          }
          strongSelf.appendOutputChunk(outputToAdd)
        }
      }

      // Detect if this is an SSH command - completely disable IO features for SSH
      // Terminal control sequences interfere with SSH handshake
      let trimmedCommand = command.trimmingCharacters(in: .whitespacesAndNewlines)
      let isSSHCommand = trimmedCommand.hasPrefix("ssh ") || trimmedCommand.hasPrefix("SSH ")

      if isSSHCommand {
        // Mark as SSH session and skip IO features entirely
        self.isSSHSession = true
      } else {
        // Configure IO features immediately for non-SSH commands
        configureIOFeaturesForActivePTY()
      }
    } catch {
      self.appendOutputChunk(
        "\nError: Failed to start PTY session: \(error.localizedDescription)\n")
    }
  }

  @MainActor
  private func runPTYCommandWithHelper(_ command: String) {
    let shellPath = currentShellPath()
    var master: Int32 = -1
    let pid = proterm_forkpty_spawn(shellPath, command, &master, UInt16(rows), UInt16(columns))
    guard pid > 0, master >= 0 else {
      self.appendOutputChunk("\nError: Failed to start PTY session\n")
      return
    }

    self.masterFD = master
    self.slaveFD = -1
    self.childPID = pid
    self.ptyHandler = nil
    self.process = nil
    self.isProcessRunning = true

    setNonBlocking(master)
    proterm_set_winsize(master, UInt16(rows), UInt16(columns))

    startPTYReadSource(masterFD: master)
    monitorChildProcess(pid: pid)
    configureIOFeaturesForActivePTY()
  }

  private func monitorChildProcess(pid: pid_t) {
    childExitSource?.cancel()
    let source = DispatchSource.makeProcessSource(
      identifier: pid, eventMask: .exit, queue: DispatchQueue.global(qos: .userInitiated))
    source.setEventHandler { [weak self] in
      guard let self = self else { return }
      var status: Int32 = 0
      _ = waitpid(pid, &status, 0)
      DispatchQueue.main.async {
        // Verify this notification matches the current childPID
        // This prevents a stale handler from clearing state if a new process started immediately
        guard self.childPID == pid else {
          return
        }

        self.isShuttingDown = true
        self.shutdownFlag.set(true)
        self.tearDownIOFeatures()
        // Cancel read source (triggers its cancel handler) and also perform
        // immediate, defensive cleanup here to avoid any stale state
        // that could block the next sudo/PTY command.
        self.ptyReadSource?.cancel()
        // Clean up PTYWrapper if it exists
        if let handler = self.ptyHandler {
          handler.stop()
          self.ptyHandler = nil
        }
        // Defensive cleanup (idempotent with cancel handler):
        self.isProcessRunning = false
        let closeMaster = self.masterFD
        self.masterFD = -1
        if closeMaster >= 0 {
          DispatchQueue.global(qos: .userInitiated).async {
            close(closeMaster)
          }
        }
        self.slaveFD = -1
        self.childPID = 0
        // Ensure clean output termination (no prompt appended here)
        self.ensureSingleTrailingNewline()

        // If this is an SSH session, notify IntegrationFeatures to disconnect
        // and reset the SSH session flag so the prompt will show again
        if self.isSSHSession {
          self.isSSHSession = false  // Reset so prompt will show after SSH exits
          NotificationCenter.default.post(
            name: Notification.Name("ProTermSSHSessionClosed"),
            object: self.id
          )
        }

        // After an interactive session ends, proactively refocus the command input
        NotificationCenter.default.post(
          name: Notification.Name("ProTermFocusCommandInput"), object: self.id)
      }
    }
    source.setCancelHandler {
      _ = waitpid(pid, nil, WNOHANG)
    }
    childExitSource = source
    source.resume()
  }

  // Required compatibility methods
  public func sendInput(_ input: String) {
    if let handler = ptyHandler {
      handler.write(input)
      return
    }
    guard masterFD >= 0, let data = input.data(using: .utf8) else {
      return
    }
    data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      let written = Darwin.write(masterFD, base, data.count)
      if written < 0 {
        // Write failed
      } else {
        // Ensure the write is complete - for PTYs, the write should be immediate
        // but we verify it completed successfully
        if written != data.count {
          // Partial write
        }
      }
    }
  }

  // Check if we have an active PTY (for interactive processes)
  public var hasActivePTY: Bool {
    // Consider PTY active only while the session is running and the FD is valid
    if let handler = ptyHandler {
      let result = isProcessRunning && handler.isRunning
      return result
    }
    let pidAlive = isPIDAlive(childPID)
    let fdOk = masterFD >= 0 && isFDValid(masterFD)
    let result = isProcessRunning && childPID > 0 && pidAlive && fdOk
    return result
  }

  func sendSignal(_ signal: Int32) {
    if childPID > 0 {
      _ = kill(childPID, signal)
      return
    }
    if let pid = process?.processIdentifier, pid > 0 {
      _ = kill(pid, signal)
    }
  }

  func interruptCurrentProcess() {
    sendSignal(SIGINT)
    process?.interrupt()
  }

  // Track if this is an SSH session to skip IO features entirely
  var isSSHSession: Bool = false

  // MARK: - PTY attachment helper
  /// Attach a PTYWrapper that was created outside of this class (e.g., by
  /// `SSHSessionManager`). This sets the internal PTY references and marks the
  /// session as running so UI components can interact with it.
  /// - Parameter handler: The PTYWrapper instance to attach
  /// - Parameter isSSH: If true, this is an SSH session and IO features will be disabled
  @MainActor
  func attachPTY(_ handler: PTYWrapper, isSSH: Bool = false) {
    // Store the PTY handler and related file descriptors.
    self.ptyHandler = handler
    self.masterFD = handler.masterFD
    self.childPID = handler.childPID
    // The session is now running; we are not using a Foundation.Process.
    self.isProcessRunning = true
    self.process = nil
    self.isSSHSession = isSSH

    // Configure PTY window size and notify process
    if masterFD >= 0 {
      setWindowSize(fd: masterFD, cols: UInt16(columns), rows: UInt16(rows))
    }

    // Monitor the child process to detect when it exits
    // This is critical for SSH sessions created by SSHSessionManager
    // to ensure proper cleanup when the user types 'exit'
    monitorChildProcess(pid: handler.childPID)

    // For SSH sessions, completely skip IO feature configuration
    // Terminal control sequences interfere with SSH handshake and connection
    if !isSSH {
      configureIOFeaturesForActivePTY()
    }
  }

  func suspendCurrentProcess() {
    sendSignal(SIGTSTP)
  }

  func terminate() {
    // Try graceful termination first
    sendSignal(SIGTERM)
    // Fallback to interrupt for interactive programs
    DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
      guard let self = self else { return }
      if self.process?.isRunning == true {
        self.sendSignal(SIGINT)
      }
    }
  }

  func resumeProcess() {
    // No-op for now; could send SIGCONT to stopped jobs
    sendSignal(SIGCONT)
  }

  func getSystemInfo() -> String {
    let hostName = ProcessInfo.processInfo.hostName
    let userName = NSUserName()
    let osVersion = ProcessInfo.processInfo.operatingSystemVersionString
    return """
      Host: \(hostName)
      User: \(userName)
      OS: \(osVersion)
      Current Directory: \(cwd.path)
      """
  }

  var commandHistory: [String] = []
  var lastCommand: String? { return commandHistory.last }
  var process: Process?
  var inputPipe: Pipe?

  func clearOutput() {
    output = ""
    // Don't add prompt to output - it's shown inline in the input area
  }

  /// Append text to output with automatic size limiting
  @MainActor
  func appendOutput(_ text: String) {
    appendOutputChunk(text)
  }

  @MainActor
  private func handleOutputChunkOnMain(_ chunk: String) {
    guard !isShuttingDown && masterFD >= 0 else { return }
    
    // Pass the stateful pendingCR flag to the normalization
    let (normalized, nextPendingCR) = ANSIParser.normalizeControlCharacters(chunk, pendingCR: self.pendingCR)
    self.pendingCR = nextPendingCR
    
    self.appendOutputChunk(normalized)
  }

  @MainActor
  private func appendOutputChunk(_ chunk: String) {
    guard !chunk.isEmpty else { return }
    
    output = limitOutputSize(output + chunk)
  }

  private func limitOutputSize(_ text: String) -> String {
    if text.count <= maxOutputLength {
      return text
    }

    // Keep the last portion of the output to maintain recent history
    let startIndex = text.index(text.endIndex, offsetBy: -maxOutputLength)
    return String(text[startIndex...])
  }

  @MainActor
  private func processOSCSequences(in chunk: String) {
    guard chunk.contains("\u{001B}]") || !oscSequenceRemainder.isEmpty else { return }
    var combined = oscSequenceRemainder + chunk
    oscSequenceRemainder.removeAll(keepingCapacity: true)

    while let escIndex = combined.firstIndex(of: "\u{001B}") {
      let nextIndex = combined.index(after: escIndex)
      guard nextIndex < combined.endIndex else {
        oscSequenceRemainder = String(combined[escIndex...])
        return
      }
      let indicator = combined[nextIndex]
      guard indicator == "]" else {
        combined = String(combined[combined.index(after: escIndex)...])
        continue
      }

      var cursor = combined.index(after: nextIndex)
      var payload = ""
      var terminatorFound = false
      while cursor < combined.endIndex {
        let symbol = combined[cursor]
        if symbol == "\u{0007}" {
          terminatorFound = true
          break
        } else if symbol == "\u{001B}" {
          let lookAhead = combined.index(after: cursor)
          if lookAhead < combined.endIndex && combined[lookAhead] == "\\" {
            terminatorFound = true
            cursor = lookAhead
            break
          }
        }
        payload.append(symbol)
        cursor = combined.index(after: cursor)
      }

      if !terminatorFound {
        oscSequenceRemainder = String(combined[escIndex...])
        return
      }

      handleOSCCommand(payload)
      if cursor < combined.endIndex {
        combined = String(combined[combined.index(after: cursor)...])
      } else {
        combined = ""
      }
    }
  }

  @MainActor
  private func handleOSCCommand(_ payload: String) {
    guard !payload.isEmpty else { return }
    let components = payload.split(separator: ";", omittingEmptySubsequences: false)
    guard let command = components.first else { return }

    switch command {
    case "0", "2":
      // Window title/icon label
      let title = components.dropFirst().joined(separator: ";")
      guard !title.isEmpty else { return }
      NotificationCenter.default.post(
        name: .terminalTitleDidChange, object: id, userInfo: ["title": title])
    default:
      break
    }
  }
}

// MARK: - Notification extensions
extension Notification.Name {
  static let directoryChanged = Notification.Name("ProTermDirectoryChanged")
  static let terminalTitleDidChange = Notification.Name("ProTermTerminalTitleDidChange")
  static let sshPTYOutput = Notification.Name("ProTermSSHPTYOutput")
  static let sshPTYExit = Notification.Name("ProTermSSHPTYExit")
  static let proTermTerminalColumnsDidChange = Notification.Name("ProTermTerminalColumnsDidChange")
}
