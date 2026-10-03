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

  @Published var output: String = "" {
    didSet { if output.isEmpty && !commandMarkers.isEmpty { commandMarkers.removeAll() } }
  }
  /// Where the user submitted commands (for collapsible sections). Not persisted.
  var commandMarkers: [CommandMarker] = []
  /// Sections the user has folded; the view re-renders when this changes.
  @Published var collapsedSections: Set<UUID> = []
  @Published private(set) var isRecording: Bool = false
  private var recorder: SessionRecorder?
  @Published var isProcessRunning: Bool = false
  @Published var isLoginShellActive: Bool = false
  /// Latest PS1 from the login-shell PTY (not stored in scrollback).
  @Published var shellPromptLine: String = ""
  @Published var lastCommandExecutionTime: TimeInterval? = nil

  // Limit output size to prevent performance issues
  // Read from UserDefaults to respect user's scrollback settings
  private var maxOutputLength: Int {
    // For SSH sessions, use a much larger limit to preserve scrollback during pagination
    // SSH pagination (like "show run" on Cisco devices) requires users to be able to
    // scroll back through multiple pages of output
    if isSSHSession {
      return 10000000 // 10MB for SSH sessions to handle large configuration outputs
    }

    let limit = UserDefaults.standard.integer(forKey: "ProTermScrollbackLimit")
    let enabled = UserDefaults.standard.object(forKey: "ProTermScrollbackEnabled") as? Bool ?? true

    if enabled {
        // Enforce a sensible minimum to prevent "single page" bugs if UserDefault is weird
        if limit < 10000 { return 1000000 } // Default 1MB if unconfigured or too small
        return limit
    }
    return 100000 // Fallback if disabled (should be enough for a few pages)
  }
  
  // Terminal.app style: if true, show raw PTY output without prompt filtering
  private var useTerminalAppPromptStyle: Bool {
    return UserDefaults.standard.object(forKey: "ProTermTerminalAppStyle") as? Bool ?? false
  }
  private var commandStartTime: Date?

  var cwd: URL = FileManager.default.homeDirectoryForCurrentUser
  /// Extra environment variables for the login shell (e.g. from a session template).
  var extraEnvironment: [String: String] = [:]
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

  // Terminal height and line height to compute rows
  var terminalHeight: CGFloat = 600 {
    didSet {
      updateRows()
      applyTTYSettingsIfNeeded()
    }
  }

  var lineHeight: CGFloat = 16.0 {
    didSet {
      updateRows()
      applyTTYSettingsIfNeeded()
    }
  }

  private func updateRows() {
    // Calculate rows based on terminal height and line height
    let availableHeight = max(120, terminalHeight) // Minimum 120 points
    let lh = max(8.0, lineHeight)                  // Avoid division by zero and tiny lines
    let calculatedRows = Int(availableHeight / lh)
    // Clamp to a reasonable terminal range
    self.rows = max(12, min(200, calculatedRows))
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
  var childPID: pid_t = 0  // Made internal for interrupt checking
  private var childExitSource: DispatchSourceProcess?

  // Thread-safe shutdown flag for PTY readers
  // Accessed across threads; write from main actor, read from background queues.
  private let shutdownFlag = AtomicBool(false)

  // Cached rows estimate (height). We don’t track actual pixel height here,
  // use a sensible default; can be exposed later for dynamic sizing
  private var rows: Int = 40

  private var bracketedPasteEnabled: Bool
  private var mouseReportingEnabled: Bool
  private var ioFeaturesApplied = false
  private var ioSettingsObserver: NSObjectProtocol?
  private var externalPTYOutputObserver: NSObjectProtocol?
  private var externalPTYExitObserver: NSObjectProtocol?
  private var pendingCR = false // Track for cross-chunk Carriage Return handling
  private var didPostAttachWinch = false // One-shot guard for post-attach TTY size push
  private var isInAltScreen = false // Track alternate screen buffer state for TUIs
  private var loginShellIOFeaturesScheduled = false

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

  /// Environment for forked login shells. Finder-launched apps often have a minimal PATH unlike Xcode runs.
  private func loginShellEnvironment() -> [String: String] {
    var env = ProcessInfo.processInfo.environment
    let shellPath = currentShellPath()
    env["TERM"] = env["TERM"] ?? "xterm-256color"
    env["COLUMNS"] = "\(columns)"
    env["LINES"] = "\(rows)"
    env["SHELL"] = shellPath
    env["PWD"] = cwd.path
    let home = FileManager.default.homeDirectoryForCurrentUser.path
    if env["HOME"] == nil || env["HOME"]?.isEmpty == true { env["HOME"] = home }
    let username = NSUserName()
    if env["USER"] == nil || env["USER"]?.isEmpty == true { env["USER"] = username }
    if env["LOGNAME"] == nil || env["LOGNAME"]?.isEmpty == true { env["LOGNAME"] = username }
    if env["PATH"] == nil || env["PATH"]?.isEmpty == true {
      env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
    }
    env.merge(extraEnvironment) { _, new in new }
    return env
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

  // Ensure the child process sees the final window size after PTY attach/first output
  @MainActor
  private func postAttachWinchIfNeeded() {
    guard !didPostAttachWinch else { return }
    didPostAttachWinch = true
    if masterFD >= 0 {
      setWindowSize(fd: masterFD, cols: UInt16(columns), rows: UInt16(rows))
    } else if slaveFD >= 0 {
      setWindowSize(fd: slaveFD, cols: UInt16(columns), rows: UInt16(rows))
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
    // Bracketed-paste toggles make zsh echo `?2004h` into scrollback; skip on local login shell.
    if bracketedPasteEnabled, !isLoginShellActive {
      sendInput("\u{001B}[?2004h")
    }
    if mouseReportingEnabled {
      sendInput("\u{001B}[?1000h")
      sendInput("\u{001B}[?1006h")
    }
    ioFeaturesApplied = true
  }

  /// Enable bracketed-paste/mouse after zsh has drawn PS1 (avoids `?2004h` corrupting the prompt).
  @MainActor
  private func scheduleLoginShellIOFeaturesIfNeeded() {
    guard isLoginShellActive, !isSSHSession, hasActivePTY, !ioFeaturesApplied else { return }
    guard !loginShellIOFeaturesScheduled else { return }
    loginShellIOFeaturesScheduled = true
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { [weak self] in
      Task { @MainActor [weak self] in
        guard let self, self.isLoginShellActive, self.hasActivePTY else {
          self?.loginShellIOFeaturesScheduled = false
          return
        }
        self.configureIOFeaturesForActivePTY()
      }
    }
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
        guard let strongSelf = self else { return }
        // On first visible output, ensure the child sees the final window size
        strongSelf.postAttachWinchIfNeeded()
        strongSelf.handleOutputChunkOnMain(s)
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
            ProTermPTYDebug.log(
              "[ProTermPTY] PTY read \(normalized.count) bytes preview=\(ProTermPTYDebug.repr(normalized, maxLength: 80))")
            appendOnMain(normalized)
          }
        } else if n == 0 {
          ProTermPTYDebug.log("[ProTermPTY] PTY read EOF (n=0) — child may have exited")
          source.cancel()
          break
        } else {
          if errno == EAGAIN || errno == EWOULDBLOCK { break }
          ProTermPTYDebug.log("[ProTermPTY] PTY read error errno=\(errno)")
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
        strongSelf.isLoginShellActive = false
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

  // Force apply window size and basic env to the child’s session FDs
  @MainActor
  private func forceApplyTTYSizeAndEnv() {
    // Push to both ends if available
    if masterFD >= 0 { setWindowSize(fd: masterFD, cols: UInt16(columns), rows: UInt16(rows)) }
    if slaveFD >= 0 { setWindowSize(fd: slaveFD, cols: UInt16(columns), rows: UInt16(rows)) }
  }

  /// Scrollback text for the UI — never includes the live inline PS1.
  var loginShellDisplayScrollback: String {
    guard isLoginShellActive, !isSSHSession else { return output }
    var text = PromptBuilder.stripTrailingPromptOnlyLines(
      output,
      matchingPrompt: shellPromptLine
    )
    text = PromptBuilder.scrollbackRemovingPromptOnlyLines(text)
    return text.trimmingCharacters(in: .newlines)
  }

  /// Cache key for login-shell attributed output (scrollback + inline PS1).
  var loginShellDisplayCacheKey: String {
    loginShellDisplayScrollback + "\u{1E}" + shellPromptLine
  }

  /// Store PS1 for the inline field and purge it from scrollback storage.
  @MainActor
  private func applyLoginShellPromptLine(_ prompt: String) {
    guard isLoginShellActive, !isSSHSession else { return }
    let normalized = PromptBuilder.normalizedPromptLine(prompt)
    guard !normalized.isEmpty else { return }
    let purged = limitOutputSize(
      PromptBuilder.stripTrailingPromptOnlyLines(
        PromptBuilder.scrollbackRemovingPromptOnlyLines(output),
        matchingPrompt: normalized
      )
    )
    // Set PS1 before purging scrollback so display filters never flash the prompt in history.
    shellPromptLine = normalized
    if output != purged {
      output = purged
    }
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

  init(
    shellManager: ShellManager,
    startLoginShell: Bool = true,
    initialCWD: URL = FileManager.default.homeDirectoryForCurrentUser
  ) {
    self.shellManager = shellManager
    self.cwd = initialCWD
    let defaults = UserDefaults.standard
    self.bracketedPasteEnabled = defaults.object(forKey: IOSettingKey.bracketed) as? Bool ?? true
    self.mouseReportingEnabled = defaults.object(forKey: IOSettingKey.mouse) as? Bool ?? false
    super.init()
    // Initialize columns from UserDefaults preference (default: 80)
    let configuredColumns = defaults.object(forKey: "ProTermTerminalColumns") as? Int ?? 80
    self.columns = max(40, min(200, configuredColumns))  // Clamp to valid range

    // Initialize rows from UserDefaults preference if present (default: 40)
    if let configuredRows = defaults.object(forKey: "ProTermTerminalRows") as? Int {
      self.rows = max(12, min(200, configuredRows))
    }

    // Don't add prompt to output - it's shown inline in the input area
    output = ""
    ioSettingsObserver = NotificationCenter.default.addObserver(
      forName: .proTermIOSettingsDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshIOFeatureFlags()
      }
    }

    // Observe terminal columns preference changes
    NotificationCenter.default.addObserver(
      forName: .proTermTerminalColumnsDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let self = self else { return }
        let defaults = UserDefaults.standard
        let configuredColumns = defaults.object(forKey: "ProTermTerminalColumns") as? Int ?? 80
        self.columns = max(40, min(200, configuredColumns))
        // Update COLUMNS environment variable for future commands
        // Apply window size changes to active PTY if needed
        self.applyTTYSettingsIfNeeded()
      }
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
      let noteSessionId = note.object as? UUID
      let text = note.userInfo?["text"] as? String
      
      MainActor.assumeIsolated {
        guard let self = self else { return }
        // Filter by session ID manually to ensure we only process our own notifications
        guard let noteSessionId = noteSessionId, noteSessionId == self.id else {
          return
        }
        guard let text = text else {
          return
        }
        
        // Append chunk exactly as received - do NOT add local newlines between chunks
        // as it breaks character-at-a-time echoing in interactive sessions.
        self.handleOutputChunkOnMain(text)
      }
    }

    externalPTYExitObserver = NotificationCenter.default.addObserver(
      forName: .sshPTYExit,
      object: self.id,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        guard let strongSelf = self else { return }
        strongSelf.isShuttingDown = true
        strongSelf.shutdownFlag.set(true)
        strongSelf.tearDownIOFeatures()
        if let handler = strongSelf.ptyHandler {
          handler.stop()
          strongSelf.ptyHandler = nil
        }
        strongSelf.isProcessRunning = false
        strongSelf.isLoginShellActive = false

        // If this is an SSH session, reset the flag and notify IntegrationFeatures to disconnect
        if strongSelf.isSSHSession {
          strongSelf.isSSHSession = false  // Reset so prompt will show after SSH exits
          NotificationCenter.default.post(
            name: .sshSessionClosed,
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
          name: .focusCommandInput, object: strongSelf.id)
      }
    }

    if startLoginShell {
      Task { @MainActor [weak self] in
        self?.startLoginShellIfNeeded()
      }
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

  /// Clear stale `isProcessRunning` / FD state so commands are not silently dropped.
  @MainActor
  func reconcileStalePTYState() {
    guard isProcessRunning else { return }

    if hasActivePTY { return }

    var processStillRunning = false
    if let proc = process {
      processStillRunning = proc.isRunning
    } else if let handler = ptyHandler {
      processStillRunning = handler.isRunning
    } else if childPID > 0 {
      processStillRunning = isPIDAlive(childPID)
    }

    let masterUsable = masterFD >= 0 && isFDValid(masterFD)
    let handlerMaster = ptyHandler?.masterFD ?? -1
    let handlerMasterUsable = handlerMaster >= 0 && isFDValid(handlerMaster)

    if processStillRunning && (masterUsable || handlerMasterUsable) {
      if !isProcessRunning {
        isProcessRunning = true
      }
      if !isSSHSession, masterUsable || handlerMasterUsable {
        isLoginShellActive = true
      }
      ProTermPTYDebug.log(
        "[ProTermPTY] reconcileStalePTYState: process alive but PTY inactive — resetting read source")
      ptyReadSource?.cancel()
      ptyReadSource = nil
      if masterUsable {
        startPTYReadSource(masterFD: masterFD)
      }
      return
    }

    ProTermPTYDebug.log(
      "[ProTermPTY] reconcileStalePTYState: clearing stale flags \(ptyDebugFlags())")
    tearDownStalePTYAfterChildExit()
  }

  /// Call before handling Enter so we never leave `isProcessRunning` without a usable PTY.
  @MainActor
  func prepareForCommandSubmission() {
    reconcileStalePTYState()
    if !isSSHSession, !hasActivePTY, isLoginShellActive || childPID > 0 || masterFD >= 0 {
      if !isLoginShellActive {
        isLoginShellActive = true
      }
      startLoginShellIfNeeded()
    }
  }

  @MainActor
  private func tearDownStalePTYAfterChildExit() {
    isShuttingDown = true
    shutdownFlag.set(true)
    tearDownIOFeatures()
    ptyReadSource?.cancel()
    ptyReadSource = nil
    ptyReadHandle?.readabilityHandler = nil
    if let handler = ptyHandler {
      handler.stop()
      ptyHandler = nil
    }
    let closeMaster = masterFD
    masterFD = -1
    if closeMaster >= 0 {
      DispatchQueue.global(qos: .userInitiated).async {
        close(closeMaster)
      }
    }
    if slaveFD >= 0 {
      let fd = slaveFD
      slaveFD = -1
      DispatchQueue.global(qos: .userInitiated).async {
        close(fd)
      }
    }
    childExitSource?.cancel()
    childExitSource = nil
    childPID = 0
    process = nil
    isProcessRunning = false
    isLoginShellActive = false
    isShuttingDown = false
    shutdownFlag.set(false)
    pendingCR = false
    didPostAttachWinch = false
    loginShellIOFeaturesScheduled = false
  }

  @MainActor
  func startLoginShellIfNeeded() {
    if hasActivePTY {
      ProTermPTYDebug.log(
        "[ProTermPTY] startLoginShellIfNeeded skipped — PTY already active \(ptyDebugFlags())")
      return
    }

    if childPID > 0, isPIDAlive(childPID), masterFD >= 0, isFDValid(masterFD) {
      ProTermPTYDebug.log(
        "[ProTermPTY] startLoginShellIfNeeded reattaching read source to existing shell")
      isProcessRunning = true
      isLoginShellActive = true
      isSSHSession = false
      startPTYReadSource(masterFD: masterFD)
      return
    }

    if childPID > 0 || masterFD >= 0 {
      ProTermPTYDebug.log(
        "[ProTermPTY] startLoginShellIfNeeded clearing stale PTY handles before relaunch")
      tearDownStalePTYAfterChildExit()
    }

    ProTermPTYDebug.log("[ProTermPTY] startLoginShellIfNeeded launching shell")

    let shellPath = currentShellPath()
    let args = [shellPath, "-l"]
    let cArgs = args.map { strdup($0) }
    let argvPointers: [UnsafeMutablePointer<CChar>?] = cArgs.map { $0 } + [nil]

    let env = loginShellEnvironment()
    let cEnvStrings = env.map { strdup("\($0.key)=\($0.value)") }
    let envPointers: [UnsafeMutablePointer<CChar>?] = cEnvStrings.map { $0 } + [nil]

    var master: Int32 = -1
    let pid = argvPointers.withUnsafeBufferPointer { argvBuf in
      envPointers.withUnsafeBufferPointer { envvBuf in
        proterm_forkpty_exec_in_dir(
          shellPath,
          UnsafeMutablePointer(mutating: argvBuf.baseAddress),
          UnsafeMutablePointer(mutating: envvBuf.baseAddress),
          cwd.path,
          &master,
          UInt16(rows),
          UInt16(columns)
        )
      }
    }

    for ptr in cArgs { free(ptr) }
    for ptr in cEnvStrings { free(ptr) }

    guard pid > 0, master >= 0 else {
      ProTermPTYDebug.log("[ProTermPTY] startLoginShellIfNeeded FAILED pid=\(pid) master=\(master)")
      appendOutputChunk("Error: Failed to start login shell\n")
      return
    }

    ProTermPTYDebug.log("[ProTermPTY] startLoginShellIfNeeded OK pid=\(pid) masterFD=\(master)")
    self.masterFD = master
    self.childPID = pid
    self.isProcessRunning = true
    self.isLoginShellActive = true
    self.isSSHSession = false
    if !output.isEmpty {
      let peeled = PromptBuilder.splitTrailingPromptFromChunk(output)
      if !peeled.prompt.isEmpty {
        applyLoginShellPromptLine(peeled.prompt)
      }
    }
    self.process = nil
    setNonBlocking(master)
    setWindowSize(fd: master, cols: UInt16(columns), rows: UInt16(rows))
    monitorChildProcess(pid: pid)
    startPTYReadSource(masterFD: master)
    loginShellIOFeaturesScheduled = false

    didPostAttachWinch = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      Task { @MainActor [weak self] in
        self?.postAttachWinchIfNeeded()
      }
    }
  }

  @MainActor
  func submitToActivePTY(_ command: String, payload: String? = nil) {
    let sanitized = command.sanitizedTerminalCommand()
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      ProTermPTYDebug.log("[ProTermPTY] submitToActivePTY ignored empty command")
      return
    }
    commandHistory.append(trimmed)
    // A separate `payload` means the typed text is not what goes on the wire (e.g. a password).
    if payload == nil { markCommandSubmitted(trimmed) }
    recordPTYSubmission(command: sanitized, payload: payload)
    let wire = (payload ?? sanitized) + "\n"
    ProTermPTYDebug.log(
      "[ProTermPTY] submitToActivePTY wire=\(ProTermPTYDebug.repr(wire)) \(ptyDebugFlags())")
    sendInput(wire)
  }

  /// Record an empty Return in the local login-shell UI (prompt-only line in scrollback).
  @MainActor
  func recordPTYSubmissionNewline() {
    recordPTYSubmission(command: "", payload: nil)
  }

  /// Empty Return: advance scrollback with a newline only (PS1 stays inline).
  @MainActor
  private func recordPTYSubmission(command: String, payload: String?) {
    guard isLoginShellActive && !isSSHSession else { return }
    let typed = (payload ?? command).sanitizedTerminalCommand()
    guard typed.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
    var combined = output
    if !combined.isEmpty, !combined.hasSuffix("\n") {
      combined += "\n"
    }
    output = limitOutputSize(
      PromptBuilder.stripTrailingPromptOnlyLines(combined, matchingPrompt: shellPromptLine))
    ProTermPTYDebug.log("[ProTermPTY] recordPTYSubmission appended blank line outputLen=\(output.count)")
  }

  @MainActor
  func runCommand(_ command: String) {
    let sanitized = command.sanitizedTerminalCommand()
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    // Record history of commands submitted
    commandHistory.append(trimmed)
    markCommandSubmitted(trimmed)

    prepareForCommandSubmission()

    if hasActivePTY || (isLoginShellActive && !isSSHSession && canAcceptLoginShellInput) {
      sendInput(sanitized + "\n")
      return
    }

    if isProcessRunning && !hasActivePTY {
      reconcileStalePTYState()
      if hasActivePTY {
        sendInput(sanitized + "\n")
        return
      }
      if isProcessRunning {
        ProTermPTYDebug.log("[ProTermPTY] runCommand blocked — shell still busy after reconcile")
        appendOutputChunk("\nError: Shell is not ready. Wait a moment or open a new tab.\n")
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

    // Terminal.app runs commands attached to a pseudo-terminal. Use the PTY path
    // for all remaining commands so tools that inspect isatty(), use pagers,
    // emit ANSI color, or need interactive stdin behave like they do there.
    if !output.hasSuffix("\n") {
      output.append("\n")
    }
    self.commandStartTime = Date()
    runInteractiveCommand(sanitized)
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
      self.isLoginShellActive = false
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

      // Allow one more size push after attach so fast-starting TUIs get final rows
      didPostAttachWinch = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        Task { @MainActor [weak self] in
          self?.postAttachWinchIfNeeded()
        }
      }
    } else {
      // Use PTY for other interactive commands via shell
      runPTYCommandWithForkPTY(command)
    }
  }





  @MainActor
  private func runSudoCommand(_ command: String) {
    // Sudo requires a real controlling terminal to read passwords
    // Use the C helper proterm_forkpty_exec which properly sets up the controlling terminal
    
    let shellPath = currentShellPath()
    
    // Build arguments for shell execution
    let args = [shellPath, "-l", "-i", "-c", command]
    let cArgs = args.map { strdup($0) }
    let argvPointers: [UnsafeMutablePointer<CChar>?] = cArgs.map { $0 } + [nil]
    
    // Build environment with proper terminal settings
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = "xterm-256color"
    env["COLUMNS"] = "\(columns)"
    env["LINES"] = "\(rows)"
    env["SHELL"] = shellPath
    env["PWD"] = cwd.path
    
    let cEnvStrings = env.map { strdup("\($0.key)=\($0.value)") }
    let envPointers: [UnsafeMutablePointer<CChar>?] = cEnvStrings.map { $0 } + [nil]
    
    var master: Int32 = -1
    
    let pid = argvPointers.withUnsafeBufferPointer { argvBuf in
      envPointers.withUnsafeBufferPointer { envvBuf in
        proterm_forkpty_exec_in_dir(
          shellPath,
          UnsafeMutablePointer(mutating: argvBuf.baseAddress),
          UnsafeMutablePointer(mutating: envvBuf.baseAddress),
          cwd.path,
          &master,
          UInt16(rows),
          UInt16(columns)
        )
      }
    }
    
    // Cleanup C strings
    for ptr in cArgs { free(ptr) }
    for ptr in cEnvStrings { free(ptr) }
    
    guard pid > 0, master >= 0 else {
      appendOutputChunk("\nError: Failed to start sudo command\n")
      return
    }
    
    self.masterFD = master
    self.childPID = pid
    self.isProcessRunning = true
    self.isLoginShellActive = false
    self.process = nil
    
    // Set non-blocking
    setNonBlocking(master)
    
    // Monitor the child process
    monitorChildProcess(pid: pid)
    
    // Start reading from PTY
    startPTYReadSource(masterFD: master)
    
    // DO NOT configure IO features for sudo
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

      // Configure PTY window size for proper TUI behavior
      if self.masterFD >= 0 {
        self.setWindowSize(fd: self.masterFD, cols: UInt16(self.columns), rows: UInt16(self.rows))
        // Some TUIs read size before first output; immediately send another WINCH
        self.forceApplyTTYSizeAndEnv()
      }

      self.childPID = handler.childPID
      self.isProcessRunning = true
      self.isLoginShellActive = false
      self.process = nil  // Not using Foundation.Process in forkpty path

      // Monitor the child process to detect when it exits
      monitorChildProcess(pid: handler.childPID)

      // Start reading PTY output and forward it to the UI
      handler.startReading { [weak self] text in
        Task { @MainActor [weak self] in
          guard let strongSelf = self else { return }
          strongSelf.postAttachWinchIfNeeded()
          strongSelf.handleOutputChunkOnMain(text)
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
      // Reset one-shot flag and schedule a size re-push shortly after attach
      didPostAttachWinch = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        Task { @MainActor [weak self] in
          self?.postAttachWinchIfNeeded()
        }
      }
    } catch {
      self.appendOutputChunk(
        "\nError: Failed to start PTY session: \(error.localizedDescription)\n")
    }
  }

  @MainActor
  private func runPTYCommandWithHelper(_ command: String) {
    // Use PTYWrapper for consistent environment handling
    // This ensures commands run through a login shell (-l) which loads
    // the user's full PATH and environment from .zshrc, .bash_profile, etc.
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
      self.masterFD = handler.masterFD

      // Configure PTY window size for proper TUI behavior
      if self.masterFD >= 0 {
        self.setWindowSize(fd: self.masterFD, cols: UInt16(self.columns), rows: UInt16(self.rows))
        self.forceApplyTTYSizeAndEnv()
      }

      self.childPID = handler.childPID
      self.isProcessRunning = true
      self.isLoginShellActive = false
      self.process = nil
      
      // Monitor the child process to detect when it exits
      monitorChildProcess(pid: handler.childPID)
      
      // Start reading PTY output and forward it to the UI
      handler.startReading { [weak self] text in
        Task { @MainActor [weak self] in
          guard let strongSelf = self else { return }
          strongSelf.postAttachWinchIfNeeded()
          strongSelf.handleOutputChunkOnMain(text)
        }
      }
      
      // Check if this is a command that should NOT have IO features
      // Commands like sudo, mysql, psql, mongo, redis-cli, telnet, nc, netcat need raw terminal input
      let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
      let noIOFeatureCommands = ["sudo", "mysql", "psql", "mongo", "redis-cli", "telnet", "nc", "netcat"]
      let shouldSkipIOFeatures = noIOFeatureCommands.contains { trimmed.hasPrefix($0) }
      
      if !shouldSkipIOFeatures {
        // Configure IO features for this PTY session
        configureIOFeaturesForActivePTY()
      }

      // Reset one-shot flag and schedule a size re-push shortly after attach
      didPostAttachWinch = false
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
        Task { @MainActor [weak self] in
          self?.postAttachWinchIfNeeded()
        }
      }
    } catch {
      self.appendOutputChunk(
        "\nError: Failed to start PTY session: \(error.localizedDescription)\n")
    }
  }

  // New: Use forkpty-based helper to guarantee controlling TTY and non-zero window size
  @MainActor
  private func runPTYCommandWithForkPTY(_ command: String) {
    let shellPath = currentShellPath()
    // Build arguments for a login interactive shell executing the command
    // Keep command as-is; we’ll perform a single post-attach stty as a fallback
    let args = [shellPath, "-l", "-i", "-c", command]
    let cArgs = args.map { strdup($0) }
    let argvPointers: [UnsafeMutablePointer<CChar>?] = cArgs.map { $0 } + [nil]

    // Build environment with terminal settings
    var env = ProcessInfo.processInfo.environment
    env["TERM"] = env["TERM"] ?? "xterm-256color"
    env["COLUMNS"] = "\(columns)"
    env["LINES"] = "\(rows)"
    env["SHELL"] = shellPath
    env["PWD"] = cwd.path

    let cEnvStrings = env.map { strdup("\($0.key)=\($0.value)") }
    let envPointers: [UnsafeMutablePointer<CChar>?] = cEnvStrings.map { $0 } + [nil]

    var master: Int32 = -1

    let pid = argvPointers.withUnsafeBufferPointer { argvBuf in
      envPointers.withUnsafeBufferPointer { envvBuf in
        proterm_forkpty_exec_in_dir(
          shellPath,
          UnsafeMutablePointer(mutating: argvBuf.baseAddress),
          UnsafeMutablePointer(mutating: envvBuf.baseAddress),
          cwd.path,
          &master,
          UInt16(rows),
          UInt16(columns)
        )
      }
    }

    // Cleanup duplicated C strings
    for ptr in cArgs { free(ptr) }
    for ptr in cEnvStrings { free(ptr) }

    guard pid > 0, master >= 0 else {
      appendOutputChunk("\nError: Failed to start interactive PTY session\n")
      return
    }

    self.masterFD = master
    self.childPID = pid
    self.isProcessRunning = true
    self.isLoginShellActive = false
    self.process = nil

    // Non-blocking master FD
    setNonBlocking(master)

    // Apply window size immediately and reinforce
    setWindowSize(fd: master, cols: UInt16(columns), rows: UInt16(rows))
    forceApplyTTYSizeAndEnv()

    // Monitor child and start reading
    monitorChildProcess(pid: pid)
    startPTYReadSource(masterFD: master)

    // Post-attach size push
    didPostAttachWinch = false
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
      Task { @MainActor [weak self] in
        self?.postAttachWinchIfNeeded()
      }
    }

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
        self.isLoginShellActive = false
        if let startTime = self.commandStartTime {
          self.lastCommandExecutionTime = Date().timeIntervalSince(startTime)
          self.commandStartTime = nil
        }
        self.pendingCR = false
        self.didPostAttachWinch = false
        self.utf8Remainder.removeAll(keepingCapacity: false)
        self.oscSequenceRemainder.removeAll(keepingCapacity: false)
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
          name: .focusCommandInput, object: self.id)
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
      ProTermPTYDebug.log(
        "[ProTermPTY] sendInput via ptyHandler len=\(input.count) \(ProTermPTYDebug.repr(input))")
      handler.write(input)
      return
    }
    guard masterFD >= 0, let data = input.data(using: .utf8) else {
      ProTermPTYDebug.log(
        "[ProTermPTY] sendInput DROPPED masterFD=\(masterFD) childPID=\(childPID) "
          + "running=\(isProcessRunning) loginShell=\(isLoginShellActive) wire=\(ProTermPTYDebug.repr(input))")
      Task { @MainActor [weak self] in
        self?.reconcileStalePTYState()
        if let self, self.isLoginShellActive, !self.isSSHSession, !self.hasActivePTY {
          self.startLoginShellIfNeeded()
        }
      }
      return
    }
    data.withUnsafeBytes { buffer in
      guard let base = buffer.baseAddress else { return }
      errno = 0
      let written = Darwin.write(masterFD, base, data.count)
      if written < 0 {
        let err = errno
        ProTermPTYDebug.log(
          "[ProTermPTY] sendInput WRITE FAILED fd=\(masterFD) errno=\(err) "
            + "\(String(cString: strerror(err))) wire=\(ProTermPTYDebug.repr(input))")
      } else if written != data.count {
        ProTermPTYDebug.log(
          "[ProTermPTY] sendInput partial write \(written)/\(data.count) fd=\(masterFD)")
      } else {
        ProTermPTYDebug.log(
          "[ProTermPTY] sendInput OK fd=\(masterFD) bytes=\(written) \(ProTermPTYDebug.repr(input))")
      }
    }
  }

  /// True when the local login-shell PTY accepts keyboard input (including before read source attaches).
  var canAcceptLoginShellInput: Bool {
    guard isLoginShellActive, !isSSHSession else { return false }
    if hasActivePTY { return true }
    let fdOk = masterFD >= 0 && isFDValid(masterFD)
    let pidOk = childPID > 0 && isPIDAlive(childPID)
    return fdOk && pidOk
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
    // First, try to send SIGINT to the child process if it exists
    if childPID > 0 && isPIDAlive(childPID) {
      _ = kill(childPID, SIGINT)
    }
    
    // Also try to interrupt the Foundation.Process if it exists
    if let proc = process, proc.isRunning {
      proc.interrupt()
    }
    
    // If we have a PTY handler, try to send Ctrl+C through it
    if let handler = ptyHandler, handler.isRunning {
      // Send Ctrl+C (ASCII 3) to the PTY
      handler.write("\u{0003}")
    }
    
    // If we have a master FD but no handler, send Ctrl+C directly
    if masterFD >= 0, isFDValid(masterFD), ptyHandler == nil {
      let ctrlC = "\u{0003}"
      if let data = ctrlC.data(using: .utf8) {
        data.withUnsafeBytes { buffer in
          guard let base = buffer.baseAddress else { return }
          _ = Darwin.write(masterFD, base, data.count)
        }
      }
    }
    
    // If nothing worked after a short delay, try SIGTERM as a fallback
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) { [weak self] in
      guard let self = self else { return }
      
      // Check if process is still running
      var stillRunning = false
      if self.childPID > 0 {
        stillRunning = self.isPIDAlive(self.childPID)
      } else if let proc = self.process {
        stillRunning = proc.isRunning
      }
      
      if stillRunning {
        // SIGINT didn't work, try SIGTERM
        if self.childPID > 0 {
          _ = kill(self.childPID, SIGTERM)
        }
        if let proc = self.process, proc.isRunning {
          proc.terminate()
        }
      } else {
        // Process stopped, clean up state
        self.isProcessRunning = false
        self.isLoginShellActive = false
      }
    }
  }

  @MainActor
  func forceKillCurrentProcess() {
    // Force kill with SIGKILL - this cannot be caught or ignored
    if childPID > 0 && isPIDAlive(childPID) {
      _ = kill(childPID, SIGKILL)
    }
    
    if let proc = process, proc.isRunning {
      proc.terminate()
      // Give it a moment, then force kill the PID if still alive
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
        guard let self = self else { return }
        if let p = self.process?.processIdentifier, p > 0, self.isPIDAlive(p) {
          _ = kill(p, SIGKILL)
        }
      }
    }
    
    if let handler = ptyHandler {
      handler.stop()
      self.ptyHandler = nil
    }
    
    // Clean up PTY resources
    ptyReadSource?.cancel()
    ptyReadSource = nil
    
    let closeMaster = self.masterFD
    self.masterFD = -1
    if closeMaster >= 0 {
      DispatchQueue.global(qos: .userInitiated).async {
        close(closeMaster)
      }
    }
    
    self.slaveFD = -1
    self.childPID = 0
    self.isProcessRunning = false
    self.isLoginShellActive = false
    self.process = nil
    
    self.ensureSingleTrailingNewline()
    self.appendOutputChunk("\n[Process force killed]\n")
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
    self.isLoginShellActive = false
    self.process = nil
    self.isSSHSession = isSSH

    // Configure PTY window size and notify process
    if masterFD >= 0 {
      setWindowSize(fd: masterFD, cols: UInt16(columns), rows: UInt16(rows))
      forceApplyTTYSizeAndEnv()
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
    shellPromptLine = ""
    // Don't add prompt to output - it's shown inline in the input area
  }

  /// Append text to output with automatic size limiting
  // Output throttling - debounce rapid output chunks
  private var lastOutputTime: Date = .init()
  private let outputThrottleInterval: TimeInterval = 0.1

  @MainActor
  func appendOutput(_ text: String) {
    appendOutputChunk(text)
  }

  @MainActor
  private func handleOutputChunkOnMain(_ chunk: String) {
    guard !isShuttingDown && masterFD >= 0 else {
      ProTermPTYDebug.log(
        "[ProTermPTY] handleOutputChunkOnMain DROPPED shuttingDown=\(isShuttingDown) masterFD=\(masterFD) "
          + "chunkLen=\(chunk.count)")
      return
    }
    if let recorder, !recorder.record(chunk) { stopRecording() }
    // Pre-handle minimal TUI control sequences (clear screen, alt-screen toggle)
    var processed = processTUIControlSequences(chunk)
    if isLoginShellActive && !isSSHSession {
      processed = PromptBuilder.stripBracketedPasteModeSequences(processed)
      if PromptBuilder.isBracketedPasteModeOnlyChunk(processed) {
        pendingCR = false
        ProTermPTYDebug.log(
          "[ProTermPTY] handleOutputChunkOnMain skipped bracketed-paste mode echo len=\(processed.count)")
        return
      }
      if PromptBuilder.isPromptPaddingOnlyChunk(processed) {
        pendingCR = false
        ProTermPTYDebug.log(
          "[ProTermPTY] handleOutputChunkOnMain skipped zsh padding before normalize len=\(processed.count)")
        return
      }
    }

    // zsh redraws prompts with bare `\r`; we must always overwrite the current line (not append).
    let (normalized, nextPendingCR) = ANSIParser.normalizeControlCharacters(
      processed,
      pendingCR: self.pendingCR,
      onlyClearPromptLikeLines: false
    )
    self.pendingCR = nextPendingCR

    if isLoginShellActive && !isSSHSession {
      let cleaned = PromptBuilder.stripIncompleteCSITail(
        PromptBuilder.stripBracketedPasteModeSequences(normalized)
      )
      if PromptBuilder.isBracketedPasteModeOnlyChunk(cleaned) {
        ProTermPTYDebug.log(
          "[ProTermPTY] handleOutputChunkOnMain skipped bracketed-paste after normalize")
        return
      }
      if PromptBuilder.isShellPromptLine(cleaned)
        || cleaned.contains("@") && cleaned.contains("%")
      {
        scheduleLoginShellIOFeaturesIfNeeded()
      }
      if cleaned != normalized {
        ProTermPTYDebug.log(
          "[ProTermPTY] handleOutputChunkOnMain bracketed-paste cleanup "
            + "\(ProTermPTYDebug.repr(normalized)) → \(ProTermPTYDebug.repr(cleaned))")
      }
      ProTermPTYDebug.log(
        "[ProTermPTY] handleOutputChunkOnMain in=\(chunk.count) norm=\(cleaned.count) "
          + "pendingCR=\(nextPendingCR) preview=\(ProTermPTYDebug.repr(cleaned))")
      self.appendOutputChunk(cleaned)
      return
    }

    ProTermPTYDebug.log(
      "[ProTermPTY] handleOutputChunkOnMain in=\(chunk.count) norm=\(normalized.count) "
        + "pendingCR=\(nextPendingCR) preview=\(ProTermPTYDebug.repr(normalized))")
    self.appendOutputChunk(normalized)
  }

  // Minimal handling for common full-screen TUI sequences so output isn’t permanently jumbled
  // - Clear screen: ESC[2J, ESC[3J, ESC[J  => wipe current output buffer
  // - Alt screen on:  ESC[?1049h or ESC[?47h => clear and mark alt screen
  // - Alt screen off: ESC[?1049l or ESC[?47l => exit alt screen (no special action other than flag)
  @MainActor
  private func processTUIControlSequences(_ chunk: String) -> String {
    var s = chunk
    // Clear screen patterns
    let clearSeqs = ["\u{001B}[2J", "\u{001B}[3J", "\u{001B}[J"]
    var didClear = false
    for seq in clearSeqs {
      if s.contains(seq) {
        didClear = true
        s = s.replacingOccurrences(of: seq, with: "")
      }
    }
    if didClear {
      // zsh redraws the prompt with ESC[J after every command; never wipe login-shell scrollback.
      let preserveScrollback = isLoginShellActive && !isSSHSession
      if preserveScrollback {
        ProTermPTYDebug.log(
          "[ProTermPTY] clear-screen sequence stripped (scrollback preserved) chunkLen=\(chunk.count)")
      } else {
        self.output = ""
      }
      self.pendingCR = false
    }

    // Alternate screen enable
    let altOnSeqs = ["\u{001B}[?1049h", "\u{001B}[?47h"]
    for seq in altOnSeqs {
      if s.contains(seq) {
        isInAltScreen = true
        s = s.replacingOccurrences(of: seq, with: "")
        if !(isLoginShellActive && !isSSHSession) {
          self.output = ""
          self.pendingCR = false
        }
      }
    }

    // Alternate screen disable
    let altOffSeqs = ["\u{001B}[?1049l", "\u{001B}[?47l"]
    for seq in altOffSeqs {
      if s.contains(seq) {
        isInAltScreen = false
        s = s.replacingOccurrences(of: seq, with: "")
        // Login shell keeps PS1 inline only — avoid a blank scrollback row above the input.
        if !(isLoginShellActive && !isSSHSession), !self.output.hasSuffix("\n") {
          self.output += "\n"
        }
      }
    }

    return s
  }

  /// Append login-shell PTY text incrementally. Never re-run full-buffer compaction (that erased `ls` output).
  @MainActor
  private func appendLoginShellOutputChunk(_ chunk: String, beforeLen: Int) {
    var chunk = PromptBuilder.stripBracketedPasteModeSequences(chunk)
    chunk = PromptBuilder.stripIncompleteCSITail(chunk)

    if PromptBuilder.isBracketedPasteModeOnlyChunk(chunk) {
      ProTermPTYDebug.log("[ProTermPTY] appendOutputChunk skipped bracketed-paste-only chunk")
      return
    }

    if PromptBuilder.isNewlineOnlyChunk(chunk), output.hasSuffix("\n") {
      ProTermPTYDebug.log("[ProTermPTY] appendOutputChunk skipped duplicate newline echo")
      return
    }

    if PromptBuilder.isPromptPaddingOnlyChunk(chunk) {
      ProTermPTYDebug.log(
        "[ProTermPTY] appendOutputChunk skipped zsh padding chunk len=\(chunk.count)")
      return
    }

    if PromptBuilder.isLoginShellPromptNoiseChunk(chunk) {
      let livePrompt = PromptBuilder.lastShellPrompt(in: chunk)
      if !livePrompt.isEmpty {
        applyLoginShellPromptLine(livePrompt)
      }
      ProTermPTYDebug.log(
        "[ProTermPTY] appendOutputChunk prompt-noise chunk "
          + "prompt=\(ProTermPTYDebug.repr(shellPromptLine)) output \(beforeLen)→\(output.count)")
      return
    }

    let peeled = PromptBuilder.splitTrailingPromptFromChunk(chunk)
    if !peeled.prompt.isEmpty {
      applyLoginShellPromptLine(peeled.prompt)
    } else {
      let livePrompt = PromptBuilder.lastShellPrompt(in: chunk)
      if !livePrompt.isEmpty {
        applyLoginShellPromptLine(livePrompt)
      }
    }

    if PromptBuilder.isShellPromptOnlyChunk(chunk) {
      ProTermPTYDebug.log(
        "[ProTermPTY] appendOutputChunk prompt-only chunk "
          + "peeledPrompt=\(ProTermPTYDebug.repr(peeled.prompt)) "
          + "output \(beforeLen)→\(output.count)")
      return
    }

    let toAppend = PromptBuilder.loginShellScrollbackToAppend(from: peeled.scrollback)
    guard !toAppend.isEmpty else {
      ProTermPTYDebug.log(
        "[ProTermPTY] appendOutputChunk no scrollback lines "
          + "peeledPrompt=\(ProTermPTYDebug.repr(peeled.prompt)) "
          + "chunk=\(ProTermPTYDebug.repr(chunk, maxLength: 80))")
      return
    }

    ProTermPTYDebug.log(
      "[ProTermPTY] appendOutputChunk append=\(toAppend.count) "
        + "peeledPrompt=\(ProTermPTYDebug.repr(peeled.prompt)) "
        + "chunk=\(ProTermPTYDebug.repr(chunk, maxLength: 80))")

    var combined = output
    if !combined.isEmpty, !combined.hasSuffix("\n"), !toAppend.hasPrefix("\n") {
      let lastChar = combined.last
      let firstChar = toAppend.first
      if lastChar != "\n", firstChar != "\n", peeled.prompt.isEmpty {
        combined += "\n"
      }
    }
    combined += toAppend
    combined = PromptBuilder.capTrailingNewlines(combined, maxTrailing: 2)
    combined = PromptBuilder.stripTrailingPromptOnlyLines(
      combined, matchingPrompt: shellPromptLine)
    output = limitOutputSize(combined)
    ProTermPTYDebug.log(
      "[ProTermPTY] appendOutputChunk output \(beforeLen)→\(output.count) loginShell=true "
        + "shellPrompt=\(ProTermPTYDebug.repr(shellPromptLine))")
  }

  @MainActor
  private func appendOutputChunk(_ chunk: String) {
    guard !chunk.isEmpty else { return }

    let beforeLen = output.count
    if isLoginShellActive && !isSSHSession {
      appendLoginShellOutputChunk(chunk, beforeLen: beforeLen)
      return
    }

    var combined = output + chunk
    if hasActivePTY || isLoginShellActive {
      combined = PromptBuilder.collapseRepeatedPrompts(in: combined)
    }
    output = limitOutputSize(combined)
    ProTermPTYDebug.log(
      "[ProTermPTY] appendOutputChunk output \(beforeLen)→\(output.count) loginShell=\(isLoginShellActive)")
  }

  @MainActor
  func ptyDebugFlags() -> ProTermPTYDebug.PTYFlags {
    ProTermPTYDebug.PTYFlags(
      isProcessRunning: isProcessRunning,
      isLoginShellActive: isLoginShellActive,
      isSSHSession: isSSHSession,
      isShuttingDown: isShuttingDown,
      masterFD: masterFD,
      childPID: childPID,
      pidAlive: childPID > 0 ? isPIDAlive(childPID) : false,
      fdValid: masterFD >= 0 ? isFDValid(masterFD) : false,
      hasPTYHandler: ptyHandler != nil,
      outputLength: output.count,
      shellPromptLine: shellPromptLine
    )
  }

  private func limitOutputSize(_ text: String) -> String {
    if text.count <= maxOutputLength {
      return text
    }

    // Keep the last portion of the output to maintain recent history
    let startIndex = text.index(text.endIndex, offsetBy: -maxOutputLength)
    shiftCommandMarkers(by: text.utf16.distance(from: text.startIndex, to: startIndex))
    return String(text[startIndex...])
  }

  /// Output was trimmed from the front: move markers with it and drop those that scrolled off.
  private func shiftCommandMarkers(by removed: Int) {
    guard !commandMarkers.isEmpty, removed > 0 else { return }
    commandMarkers = commandMarkers.compactMap { marker in
      guard marker.offset >= removed else { return nil }
      var moved = marker
      moved.offset -= removed
      return moved
    }
    collapsedSections.formIntersection(Set(commandMarkers.map(\.id)))
  }

  // MARK: - Command markers

  @MainActor
  func markCommandSubmitted(_ command: String) {
    let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    commandMarkers.append(CommandMarker(offset: output.utf16.count, command: trimmed))
    if commandMarkers.count > 2000 { commandMarkers.removeFirst(commandMarkers.count - 2000) }
  }

  func collapseAllSections() { collapsedSections = Set(commandMarkers.map(\.id)) }
  func expandAllSections() { collapsedSections = [] }

  // MARK: - Recording

  @MainActor
  @discardableResult
  func startRecording(title: String) -> URL? {
    guard recorder == nil else { return recorder?.url }
    guard let recorder = SessionRecorder(columns: columns, rows: rows, title: title) else { return nil }
    self.recorder = recorder
    isRecording = true
    return recorder.url
  }

  @MainActor
  @discardableResult
  func stopRecording() -> URL? {
    guard let recorder else { return nil }
    recorder.stop()
    self.recorder = nil
    isRecording = false
    return recorder.url
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
