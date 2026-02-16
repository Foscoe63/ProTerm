import Combine
import Darwin
import Foundation
import SwiftUI

/// Ultra-minimal terminal session with consolidated PTY handling
final class TerminalSession: NSObject, ObservableObject, Identifiable, @unchecked Sendable {
  let id = UUID()

  @Published var output: String = ""
  @Published var isProcessRunning: Bool = false
  @Published var lastCommandExecutionTime: TimeInterval? = nil

  // Limit output size to prevent performance issues
  private var maxOutputLength: Int {
    if isSSHSession {
      return 10000000 // 10MB for SSH sessions
    }

    let limit = UserDefaults.standard.integer(forKey: "ProTermScrollbackLimit")
    let enabled = UserDefaults.standard.object(forKey: "ProTermScrollbackEnabled") as? Bool ?? true

    if enabled {
        if limit < 10000 { return 1000000 } // Default 1MB
        return limit
    }
    return 100000 // Fallback if disabled
  }
  
  private var commandStartTime: Date?
  var cwd: URL = FileManager.default.homeDirectoryForCurrentUser
  private let shellManager: ShellManager

  // Terminal width for COLUMNS environment variable
  var terminalWidth: CGFloat = 80 {
    didSet {
      let defaults = UserDefaults.standard
      let hasConfiguredColumns = defaults.object(forKey: "ProTermTerminalColumns") != nil
      if !hasConfiguredColumns {
        updateColumns()
      }
      applyTTYSettingsIfNeeded()
    }
  }

  var terminalHeight: CGFloat = 400 {
    didSet {
      updateRows()
      applyTTYSettingsIfNeeded()
    }
  }

  // Character size for accurate calculation
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
  
  var characterHeight: CGFloat = 16 {
    didSet {
      updateRows()
      applyTTYSettingsIfNeeded()
    }
  }

  private var columns: Int = 80
  private var rows: Int = 24

  // State flags and resources
  private var isShuttingDown: Bool = false
  private var ptyProcess: PTYProcess?
  private var oscSequenceRemainder = ""
  var isSSHSession: Bool = false // Internal, used by TerminalManager
  private var bracketedPasteEnabled: Bool
  private var mouseReportingEnabled: Bool
  private var ioFeaturesApplied = false
  private var ioSettingsObserver: NSObjectProtocol?
  private var pendingCR = false // Track for cross-chunk Carriage Return handling
  private var ansiRemainder = "" // Track incomplete ANSI sequences

  // For non-PTY processes
  private var currentRun: ProcessRunner.Run?
  var commandHistory: [String] = []
  var lastCommand: String? { commandHistory.last }

  private enum IOSettingKey {
    static let bracketed = "ProTermBracketedPaste"
    static let mouse = "ProTermMouseReporting"
  }

  init(shellManager: ShellManager) {
    self.shellManager = shellManager
    let defaults = UserDefaults.standard
    self.bracketedPasteEnabled = defaults.object(forKey: IOSettingKey.bracketed) as? Bool ?? true
    self.mouseReportingEnabled = defaults.object(forKey: IOSettingKey.mouse) as? Bool ?? false
    super.init()
    
    let configuredColumns = defaults.object(forKey: "ProTermTerminalColumns") as? Int ?? 80
    self.columns = max(40, min(200, configuredColumns))
    output = ""
    
    setupObservers()
  }

  private func setupObservers() {
    ioSettingsObserver = NotificationCenter.default.addObserver(
      forName: .proTermIOSettingsDidChange,
      object: nil,
      queue: .main
    ) { [weak self] _ in
      MainActor.assumeIsolated {
        self?.refreshIOFeatureFlags()
      }
    }

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
        self.applyTTYSettingsIfNeeded()
      }
    }
  }

  deinit {
    if let observer = ioSettingsObserver {
      NotificationCenter.default.removeObserver(observer)
    }
  }

  private func updateColumns() {
    let availableWidth = max(40, terminalWidth)
    let charWidth = max(1.0, characterWidth)
    let calculatedColumns = Int(availableWidth / charWidth)
    self.columns = max(40, min(500, calculatedColumns))
  }

  private func updateRows() {
    let availableHeight = max(100, terminalHeight)
    let charHeight = max(1.0, characterHeight)
    let calculatedRows = Int(availableHeight / charHeight)
    self.rows = max(10, min(200, calculatedRows))
  }

  private func ensureSingleTrailingNewline() {
    var out = self.output
    while out.hasSuffix("\r\n") || out.hasSuffix("\n") || out.hasSuffix("\r") {
      if out.hasSuffix("\r\n") {
        out = String(out.dropLast(2))
      } else {
        out = String(out.dropLast(1))
      }
    }
    guard !out.isEmpty else {
      self.output = ""
      return
    }
    self.output = limitOutputSize(out + "\n")
  }

  private func currentShellPath() -> String {
    if Thread.isMainThread {
      return MainActor.assumeIsolated { shellManager.selectedShell.executablePath }
    }
    var path = "/bin/zsh"
    DispatchQueue.main.sync {
      path = MainActor.assumeIsolated { shellManager.selectedShell.executablePath }
    }
    return path
  }

  private func applyTTYSettingsIfNeeded() {
    ptyProcess?.setWindowSize(rows: rows, cols: columns)
  }

  private func refreshIOFeatureFlags() {
    let defaults = UserDefaults.standard
    let newBracketed = defaults.object(forKey: IOSettingKey.bracketed) as? Bool ?? true
    let newMouse = defaults.object(forKey: IOSettingKey.mouse) as? Bool ?? false
    let flagsChanged = (newBracketed != bracketedPasteEnabled) || (newMouse != mouseReportingEnabled)
    bracketedPasteEnabled = newBracketed
    mouseReportingEnabled = newMouse
    if flagsChanged && hasActivePTY {
      tearDownIOFeatures()
      configureIOFeaturesForActivePTY()
    }
  }

  private func configureIOFeaturesForActivePTY() {
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

  @MainActor
  func runCommand(_ command: String) {
    let sanitized = command.sanitizedTerminalCommand()
    let trimmed = sanitized.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else { return }
    
    commandHistory.append(trimmed)

    if isProcessRunning {
      if hasActivePTY {
        return // Input handled by TerminalView
      } else {
        return // Blocking non-PTY process
      }
    }

    ensureSingleTrailingNewline()
    appendOutput("\(sanitized)\n")

    if trimmed.hasPrefix("cd ") {
      let target = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
      changeDirectory(to: target)
      return
    }

    if trimmed.lowercased().hasPrefix("sudo") {
      runInteractiveCommand(sanitized)
      return
    }

    let interactiveCommands = ["python", "python3", "node", "irb", "ruby", "ghci", "ipython", "ssh", "opencode", "htop", "top", "vim", "vi", "nano", "emacs", "docker", "git"]
    let commandName = trimmed.components(separatedBy: .whitespaces).first?.lowercased() ?? ""
    if interactiveCommands.contains(commandName) || trimmed.hasPrefix("./") {
      runInteractiveCommand(sanitized)
      return
    }

    runStandardCommand(sanitized, trimmed: trimmed)
  }

  @MainActor
  private func runStandardCommand(_ command: String, trimmed: String) {
    var commandToRun = command
    if trimmed == "ls" || trimmed.hasPrefix("ls ") {
      if !trimmed.contains(" -C") && !trimmed.contains(" -l") && !trimmed.contains(" -1") {
        commandToRun = command.replacingOccurrences(of: "ls", with: "ls -C", options: .anchored)
      }
    }

    self.isProcessRunning = true
    self.commandStartTime = Date()

    let runner = ProcessRunner()
    self.currentRun = runner.run(
      shellPath: currentShellPath(),
      command: commandToRun,
      cwd: cwd,
      columns: columns,
      rows: rows,
      onOutput: { [weak self] chunk in
        Task { @MainActor in self?.handleOutputChunkOnMain(chunk) }
      },
      onBell: { },
      onComplete: { [weak self] in
        Task { @MainActor in
          guard let self = self else { return }
          self.isProcessRunning = false
          self.currentRun = nil
          if let start = self.commandStartTime {
            self.lastCommandExecutionTime = Date().timeIntervalSince(start)
          }
          self.ensureSingleTrailingNewline()
        }
      },
      onError: { [weak self] error in
        Task { @MainActor in
          guard let self = self else { return }
          self.appendOutput("\nError: \(error.localizedDescription)\n")
          self.isProcessRunning = false
          self.currentRun = nil
        }
      }
    )
  }

  @MainActor
  private func startPTYSession(command: String? = nil, isSSH: Bool = false, env: [String: String]? = nil) {
    let pty = PTYProcess()
    attachPTY(pty, isSSH: isSSH)
    
    if isSSH { return } // SSH sessions started externally

    self.commandStartTime = Date()
    do {
      let shell = currentShellPath()
      if let cmd = command {
        try pty.startShellCommand(shellPath: shell, command: cmd, rows: rows, cols: columns, cwd: cwd, onOutput: { [weak self] text in
          Task { @MainActor in self?.handleOutputChunkOnMain(text) }
        })
      } else {
        try pty.startPersistentShell(shellPath: shell, rows: rows, cols: columns, cwd: cwd, env: env, onOutput: { [weak self] text in
          Task { @MainActor in self?.handleOutputChunkOnMain(text) }
        })
      }
    } catch {
      appendOutput("\nError: \(error.localizedDescription)\n")
      handlePTYExit()
    }
  }

  @MainActor
  func attachPTY(_ process: PTYProcess, isSSH: Bool = false) {
    self.ptyProcess = process
    self.isProcessRunning = true
    self.isSSHSession = isSSH

    process.onExit = { [weak self] in
      Task { @MainActor in self?.handlePTYExit() }
    }

    process.onOutput = { [weak self] text in
      Task { @MainActor in self?.handleOutputChunkOnMain(text) }
    }

    process.setWindowSize(rows: rows, cols: columns)
    if !isSSH { configureIOFeaturesForActivePTY() }
  }

  @MainActor
  private func handlePTYExit() {
    guard isProcessRunning else { return }
    isShuttingDown = true
    tearDownIOFeatures()
    isProcessRunning = false
    ptyProcess = nil
    
    if isSSHSession {
      isSSHSession = false
      NotificationCenter.default.post(name: Notification.Name("ProTermSSHSessionClosed"), object: self.id)
    }
    
    ensureSingleTrailingNewline()
    isShuttingDown = false
    NotificationCenter.default.post(name: .focusCommandInput, object: self.id)
    
    if let start = commandStartTime {
      lastCommandExecutionTime = Date().timeIntervalSince(start)
    }
  }

  @MainActor
  private func runInteractiveCommand(_ command: String) {
    startPTYSession(command: command)
  }

  func sendInput(_ input: String) {
    ptyProcess?.write(input)
  }

  var hasActivePTY: Bool {
    return isProcessRunning && ptyProcess?.isRunning ?? false
  }

  func sendSignal(_ signal: Int32) {
    if let pty = ptyProcess {
      pty.sendSignal(signal)
    } else if let run = currentRun, run.process.isRunning {
      _ = kill(run.process.processIdentifier, signal)
    }
  }

  func interruptCurrentProcess() {
    sendSignal(SIGINT)
  }

  func terminate() {
    ptyProcess?.stop()
    currentRun?.stop()
    isProcessRunning = false
  }

  func resumeProcess() {
    sendSignal(SIGCONT)
  }

  var prompt: String {
    if isSSHSession { return "" }
    let user = NSUserName()
    let host = Host.current().localizedName ?? "localhost"
    let homePath = FileManager.default.homeDirectoryForCurrentUser.path
    var displayPath = cwd.path.replacingOccurrences(of: homePath, with: "~")
    if displayPath.isEmpty { displayPath = "~" }
    
    var gitInfo = ""
    if GitIntegration.isGitRepository(cwd), let branch = GitIntegration.getCurrentBranch(in: cwd) {
      gitInfo = " [\(branch)]"
    }
    return "\(user)@\(host) \(displayPath)\(gitInfo) % "
  }

  @MainActor
  private func handleOutputChunkOnMain(_ chunk: String) {
    guard !isShuttingDown else { return }

    // Clear buffer if "Clear Screen" (CSI 2 J) or "Reset" (ESC c) is detected.
    if chunk.contains("\u{001B}[2J") || chunk.contains("\u{001B}c") {
      self.output = ""
    }

    if chunk.contains("\u{0007}") {
      NotificationCenter.default.post(name: .terminalBell, object: self.id)
    }
    processOSCSequences(in: chunk)
    let (normalized, nextPendingCR, nextRemainder) = ANSIParser.normalizeControlCharacters(ansiRemainder + chunk, pendingCR: self.pendingCR)
    self.pendingCR = nextPendingCR
    self.ansiRemainder = nextRemainder
    appendOutput(normalized)
  }

  @MainActor
  func appendOutput(_ chunk: String) {
    guard !chunk.isEmpty else { return }
    output = limitOutputSize(output + chunk)
  }

  private func limitOutputSize(_ text: String) -> String {
    if text.count <= maxOutputLength { return text }
    let startIndex = text.index(text.endIndex, offsetBy: -maxOutputLength)
    return String(text[startIndex...])
  }

  private func processOSCSequences(in chunk: String) {
    guard chunk.contains("\u{001B}]") || !oscSequenceRemainder.isEmpty else { return }
    let combined = oscSequenceRemainder + chunk
    oscSequenceRemainder = ""
    
    var searchStart = combined.startIndex
    while let escRange = combined.range(of: "\u{001B}]", range: searchStart..<combined.endIndex) {
      let startIndex = escRange.lowerBound
      // Look for terminator: \u{0007} (BEL) or \u{001B}\\ (ST)
      var terminatorRange: Range<String.Index>?
      if let belRange = combined.range(of: "\u{0007}", range: escRange.upperBound..<combined.endIndex) {
        terminatorRange = belRange
      } else if let stRange = combined.range(of: "\u{001B}\\", range: escRange.upperBound..<combined.endIndex) {
        terminatorRange = stRange
      }
      
      if let tr = terminatorRange {
        let sequence = combined[startIndex..<tr.upperBound]
        handleOSCCommand(String(sequence))
        // Move search start forward but don't remove from buffer 
        // to ensure ANSIParser in UI can still see it (e.g. for links)
        searchStart = tr.upperBound
      } else {
        // Partial sequence, save for later
        oscSequenceRemainder = String(combined[startIndex...])
        break
      }
    }
  }
  
  private func handleOSCCommand(_ sequence: String) {
    // Basic title support: \u{001B}]0;TITLE\u{0007} or \u{001B}]2;TITLE\u{0007}
    if sequence.hasPrefix("\u{001B}]0;") || sequence.hasPrefix("\u{001B}]2;") {
      var title = sequence.replacingOccurrences(of: "\u{001B}]0;", with: "")
                        .replacingOccurrences(of: "\u{001B}]2;", with: "")
      title = title.replacingOccurrences(of: "\u{0007}", with: "")
                   .replacingOccurrences(of: "\u{001B}\\", with: "")
      
      NotificationCenter.default.post(name: .terminalTitleDidChange, object: self.id, userInfo: ["title": title])
    }
  }

  @MainActor
  private func changeDirectory(to path: String) {
    let newURL: URL
    if path == "~" || path.isEmpty {
      newURL = FileManager.default.homeDirectoryForCurrentUser
    } else if path.hasPrefix("/") {
      newURL = URL(fileURLWithPath: path, isDirectory: true)
    } else {
      newURL = cwd.appendingPathComponent(path, isDirectory: true)
    }
    
    let resolved = newURL.standardizedFileURL
    var isDir: ObjCBool = false
    if FileManager.default.fileExists(atPath: resolved.path, isDirectory: &isDir), isDir.boolValue {
      self.cwd = resolved
    } else {
      appendOutput("cd: \(path): No such file or directory\n")
    }
  }

  func clearOutput() {
    output = ""
  }

  func getSystemInfo() -> String {
    let os = ProcessInfo.processInfo.operatingSystemVersionString
    let host = Host.current().localizedName ?? "localhost"
    return "ProTerm Session Info\n------------------\nHost: \(host)\nOS: \(os)\nCWD: \(cwd.path)"
  }
}
