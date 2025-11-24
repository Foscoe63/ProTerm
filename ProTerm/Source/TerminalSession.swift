import SwiftUI
import Foundation
import Combine
import Darwin

// Note: We'll use availableData directly with shutdown flag checks
// The shutdown flag prevents reading from closed FDs

// PTY constants
private let TIOCSCTTY: UInt = 0x20007461
private let TIOCSWINSZ: UInt = 0x80087467

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
        if enabled && limit > 0 {
            return limit
        }
        return 50000 // Default 50KB limit
    }
    private var commandStartTime: Date?
    
    var cwd: URL = FileManager.default.homeDirectoryForCurrentUser
    private let shellManager: ShellManager
    
    // Terminal width for COLUMNS environment variable
    var terminalWidth: CGFloat = 80 {
        didSet {
            // Update COLUMNS when width changes
            updateColumns()
            // Propagate window-size changes to the PTY if active
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
    
    private enum IOSettingKey {
        static let bracketed = "ProTermBracketedPaste"
        static let mouse = "ProTermMouseReporting"
    }
    
#if DEBUG
    @inline(__always) private func debugLog(_ message: String) {
        print("[ProTerm][TerminalSession] \(message)")
    }

    // MARK: - Safety: reset stale running state
    // In rare cases after a PTY-based command (e.g., sudo) finishes, the UI may still think
    // a process is running due to timing of handlers. This helper makes the state consistent.
    @MainActor
    func resetStaleProcessState() {
        // If a Foundation.Process exists and is running, do nothing
        if let proc = process, proc.isRunning { return }

        // If we report running but there is no active PTY and no running Process, clean up
        if isProcessRunning && !hasActivePTY {
            // Stop readability/dispatch sources
            outputReadHandle?.readabilityHandler = nil
            ptyReadSource?.cancel()
            ptyReadSource = nil
            childExitSource?.cancel()
            childExitSource = nil

            // Close FDs if any
            let mfd = masterFD
            masterFD = -1
            if mfd >= 0 {
                DispatchQueue.global(qos: .userInitiated).async { close(mfd) }
            }
            let sfd = slaveFD
            slaveFD = -1
            if sfd >= 0 {
                DispatchQueue.global(qos: .userInitiated).async { close(sfd) }
            }

            // Clear handler/wrapper
            ptyHandler = nil
            process = nil
            inputPipe = nil

            // Update flags
            isShuttingDown = false
            shutdownFlag.set(false)
            childPID = 0
            isProcessRunning = false

            // Normalize trailing newline (no prompt appended here)
            ensureSingleTrailingNewline()
        }
    }
#else
    @inline(__always) private func debugLog(_ message: String) { }
#endif
    
    private func updateColumns() {
        // Calculate columns based on terminal width
        // Menlo 12pt font: average character width is approximately 7.2 points
        // Account for padding (20 points total: 10 on each side)
        let availableWidth = max(40, terminalWidth - 20) // Minimum 40 points
        columns = max(40, Int(availableWidth / 7.2)) // Minimum 40 columns
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
            proterm_set_winsize(self.masterFD, UInt16(rows), UInt16(columns))
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
        let flagsChanged = (newBracketed != bracketedPasteEnabled) || (newMouse != mouseReportingEnabled)
        bracketedPasteEnabled = newBracketed
        mouseReportingEnabled = newMouse
        if flagsChanged && hasActivePTY {
            tearDownIOFeatures()
            configureIOFeaturesForActivePTY()
        }
    }
    
    private func configureIOFeaturesForActivePTY() {
        guard hasActivePTY, !ioFeaturesApplied else { return }
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
        // Prepare main-thread append closure to avoid capturing self in the read handler
        let appendOnMain: (String) -> Void = { [weak self] s in
            DispatchQueue.main.async { [weak self] in
                guard let strongSelf = self else { return }
                guard !strongSelf.isShuttingDown && strongSelf.masterFD >= 0 else { return }
                var outputToAdd = s
                if !strongSelf.output.hasSuffix("\n") && !strongSelf.output.isEmpty {
                    outputToAdd = "\n" + s
                }
                strongSelf.appendOutputChunk(outputToAdd)
            }
        }

        source.setEventHandler {
            var buffer = [UInt8](repeating: 0, count: 8192)
            while true {
                let n = read(masterFD, &buffer, buffer.count)
                if n > 0 {
                    let chunkData = Data(buffer[0..<n])
                    // UTF-8 remainder handling
                    var combined = Data()
                    if !localUTF8Remainder.isEmpty { combined.append(localUTF8Remainder) }
                    combined.append(chunkData)

                    var toAppend = ""
                    if let full = String(data: combined, encoding: .utf8) {
                        // Entire buffer decodes
                        localUTF8Remainder.removeAll(keepingCapacity: true)
                        toAppend = full
                    } else {
                        // Keep up to last 4 bytes as remainder and decode the rest
                        var cut = combined.count
                        let maxTail = min(4, combined.count)
                        var decoded: String? = nil
                        for tail in 1...maxTail {
                            let headCount = combined.count - tail
                            if headCount <= 0 { break }
                            decoded = String(data: combined.prefix(headCount), encoding: .utf8)
                            if decoded != nil {
                                cut = headCount
                                break
                            }
                        }
                        toAppend = decoded ?? String(decoding: combined, as: UTF8.self)
                        localUTF8Remainder = combined.suffix(combined.count - cut)
                    }

                    // Append on main via prepared closure
                    if !toAppend.isEmpty {
                        let normalized = toAppend.precomposedStringWithCanonicalMapping
                        appendOnMain(normalized)
                    }
                    // Loop to drain kernel buffer; break if no more data will be available now
                } else if n == 0 {
                    // EOF
                    source.cancel()
                    break
                } else {
                    // Error or would block
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
        // Check for custom prompt
        let useCustom = UserDefaults.standard.bool(forKey: "ProTermUseCustomPrompt")
        if useCustom, let customPrompt = UserDefaults.standard.string(forKey: "ProTermCustomPrompt"), !customPrompt.isEmpty {
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
           let branch = GitIntegration.getCurrentBranch(in: cwd) {
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
           let branch = GitIntegration.getCurrentBranch(in: cwd) {
            gitBranch = branch
        }
        
        return format
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
        // Initialize columns based on default width
        updateColumns()
        // Don't add prompt to output - it's shown inline in the input area
        output = ""
        ioSettingsObserver = NotificationCenter.default.addObserver(
            forName: .proTermIOSettingsDidChange,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            self?.refreshIOFeatureFlags()
        }
    }
    
    deinit {
        if let observer = ioSettingsObserver {
            NotificationCenter.default.removeObserver(observer)
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
            // Safety check: if the process isn't actually running, reset the flag immediately
            var processStillRunning = false
            if let proc = process {
                processStillRunning = proc.isRunning
            }
            
            // Also check if we have valid file descriptors (if not, process is definitely dead)
            let hasValidFDs = masterFD >= 0 && slaveFD >= 0
            
            if !processStillRunning || !hasValidFDs {
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
            debugLog("Invoking sudo command: \(sanitized)")
            runSudoCommand(sanitized)
            return
        }
        
        // Handle interactive commands with PTY (python, python3, node, ssh, etc.)
        let interactiveCommands = ["python", "python3", "node", "irb", "ruby", "ghci", "ipython", "ssh"]
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
            let hasColumnFlag = trimmed.contains(" -C") || trimmed.contains(" -x") || trimmed.contains(" -1") || 
                               trimmed.contains(" -l") || trimmed.contains(" -la") || trimmed.contains(" -lh") ||
                               trimmed.contains(" -lt") || trimmed.contains(" -ltr")
            
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
        
        // Run other commands (asynchronously; do NOT block the main actor)
        let proc = Process()
        let shellPath = currentShellPath()
        
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = ["-l", "-c", commandToRun]  // Use -l (login shell) to load .zshrc/.bash_profile
        proc.currentDirectoryURL = cwd

        // Inherit environment and force color-friendly settings similar to Terminal
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        // Ensure COLUMNS is set correctly for column-based output (ls, etc.)
        // Use the calculated columns value, ensuring it's at least 80 for proper formatting
        let effectiveColumns = max(80, columns)
        env["COLUMNS"] = "\(effectiveColumns)"
        env["LINES"] = "24"                    // Set terminal height (default)
        env["CLICOLOR"] = "1"
        env["CLICOLOR_FORCE"] = "1"          // make ls and others emit color even if not a TTY
        env["LSCOLORS"] = env["LSCOLORS"] ?? "Gxfxcxdxbxegedabagacad"
        env["GIT_PAGER"] = "cat"               // avoid paging in non-PTY
        env["GIT_CONFIG_PARAMETERS"] = "'color.ui=always'"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe

        let handle = pipe.fileHandleForReading
        
        // Retain references so they live through the async run
        self.process = proc
        self.inputPipe = pipe
        self.outputReadHandle = handle

        // Stream output incrementally as it arrives
        handle.readabilityHandler = { [weak self] fh in
            guard let strongSelf = self else { return }
            
            // Read all available data in a loop to drain the buffer completely
            // This is critical for commands that produce a lot of output quickly
            var accumulatedData = Data()
            var hasBell = false
            
            while true {
                let data = fh.availableData
                if data.isEmpty {
                    break  // No more data available
                }
                
                accumulatedData.append(data)
                
                // Check for terminal bell (ASCII 7 or \a)
                if !hasBell && data.firstIndex(of: 7) != nil {
                    hasBell = true
                }
            }
            
            guard !accumulatedData.isEmpty else { return }
            
            // Post bell notification if detected
            if hasBell {
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: Notification.Name("ProTermTerminalBell"), object: strongSelf.id)
                }
            }
            
            guard let chunk = String(data: accumulatedData, encoding: .utf8), !chunk.isEmpty else { return }
            
                DispatchQueue.main.async {
                    var outputToAdd = chunk
                    if !strongSelf.output.hasSuffix("\n") && !strongSelf.output.isEmpty {
                        outputToAdd = "\n" + chunk
                    }
                    strongSelf.appendOutputChunk(outputToAdd)
                }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let strongSelf = self else { return }
            
            // Don't stop the readability handler immediately - let it continue reading
            // We'll stop it after we've confirmed all data is read
            weak var weakSelf = strongSelf
            
            // Wait a moment for any final output to arrive through the readability handler
            Task.detached(priority: .userInitiated) {
                // Give the readability handler time to process any final buffered data
                try? await Task.sleep(for: .milliseconds(200))
                
                // Now read any remaining data that the handler might have missed
                var remainingData = Data()
                var emptyReads = 0
                let maxEmptyReads = 30  // Increased from 10 to 30 for commands with lots of output
                
                while emptyReads < maxEmptyReads {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        emptyReads += 1
                        // Progressive delay - longer waits as we get more empty reads
                        if emptyReads < maxEmptyReads {
                            let delay = min(emptyReads * 10, 100)  // Up to 100ms delay
                            try? await Task.sleep(for: .milliseconds(delay))
                        }
                    } else {
                        emptyReads = 0  // Reset counter when we get data
                        remainingData.append(chunk)
                    }
                }
                
                // Stop the readability handler now that we've drained everything
                await MainActor.run { [weakSelf] in
                    weakSelf?.outputReadHandle?.readabilityHandler = nil
                }
                
                // Final read to get absolutely everything that might be buffered
                // Wait a bit more to ensure the process has fully flushed
                try? await Task.sleep(for: .milliseconds(150))
                
                let finalChunk = handle.readDataToEndOfFile()
                if !finalChunk.isEmpty {
                    remainingData.append(finalChunk)
                }
                
                // Update UI on main thread
                if !remainingData.isEmpty,
                   let remainingString = String(data: remainingData, encoding: .utf8),
                   !remainingString.isEmpty {
                    let outputToAdd = remainingString
                    // Check weakSelf before entering MainActor context
                    guard weakSelf != nil else { return }
                    await MainActor.run { [weakSelf] in
                        guard let strongSelf = weakSelf else { return }
                        // Ensure output starts on a new line if command is still on the same line
                        var finalOutputToAdd = outputToAdd
                        if !strongSelf.output.hasSuffix("\n") && !strongSelf.output.isEmpty {
                            // Command is still on the same line, add newline before output
                            finalOutputToAdd = "\n" + outputToAdd
                        }
                        var currentOutput = strongSelf.output
                        while currentOutput.hasSuffix("\n") || currentOutput.hasSuffix("\r\n") {
                            if currentOutput.hasSuffix("\r\n") {
                                currentOutput = String(currentOutput.dropLast(2))
                            } else {
                                currentOutput = String(currentOutput.dropLast(1))
                            }
                        }
                        strongSelf.output = currentOutput
                        strongSelf.appendOutputChunk(finalOutputToAdd)
                    }
                }
                
                // Check weakSelf before entering MainActor context
                guard weakSelf != nil else { return }
                await MainActor.run { [weakSelf] in
                    guard let strongSelf = weakSelf else { return }
                    strongSelf.isProcessRunning = false
                    // Calculate execution time
                    if let startTime = strongSelf.commandStartTime {
                        strongSelf.lastCommandExecutionTime = Date().timeIntervalSince(startTime)
                        strongSelf.commandStartTime = nil
                    }
                    strongSelf.ensureSingleTrailingNewline()
                    // Release retained resources
                    strongSelf.outputReadHandle = nil
                    strongSelf.inputPipe = nil
                    strongSelf.process = nil
                }
            }
        }

        do {
            self.isProcessRunning = true
            try proc.run()
            
            // Safety check: verify process is still running after a delay
            // This ensures isProcessRunning is reset even if terminationHandler doesn't fire
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) { [weak self] in
                DispatchQueue.main.async {
                    guard let strongSelf = self else { return }
                    if strongSelf.isProcessRunning {
                        if let proc = strongSelf.process, !proc.isRunning {
                            // Process finished but handler didn't fire - reset manually
                            strongSelf.isProcessRunning = false
                            strongSelf.ensureSingleTrailingNewline()
                        }
                    }
                }
            }
        } catch {
            // Enhanced error handling
            Task { @MainActor in
                ErrorHandler.shared.logError(
                    message: "Failed to execute command: \(sanitized)",
                    type: .commandExecution,
                    command: sanitized,
                    sessionId: self.id
                )
            }
            handle.readabilityHandler = nil
            self.isProcessRunning = false
            // Ensure current output line ends, then append the error and a single newline (no prompt)
            var current = self.output
            while current.hasSuffix("\n") || current.hasSuffix("\r\n") || current.hasSuffix("\r") {
                if current.hasSuffix("\r\n") { current = String(current.dropLast(2)) }
                else { current = String(current.dropLast(1)) }
            }
            self.output = current
            self.appendOutputChunk("\nError: \(error.localizedDescription)\n")
            // Release retained resources
            self.outputReadHandle = nil
            self.inputPipe = nil
            self.process = nil
        }
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
            Task { @MainActor in
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
        // Use PTY for interactive commands via forkpty-based spawn
        runPTYCommandSimple(command)
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
            self.process = nil // Not using Foundation.Process in forkpty path

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
            configureIOFeaturesForActivePTY()
        } catch {
            self.appendOutputChunk("\nError: Failed to start PTY session: \(error.localizedDescription)\n")
        }
    }
    
    @MainActor
    private func runPTYCommandWithHelper(_ command: String) {
        debugLog("runPTYCommandWithHelper start: \(command)")
        let shellPath = currentShellPath()
        var master: Int32 = -1
        let pid = proterm_forkpty_spawn(shellPath, command, &master, UInt16(rows), UInt16(columns))
        guard pid > 0, master >= 0 else {
            debugLog("proterm_forkpty_spawn failed")
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
        let source = DispatchSource.makeProcessSource(identifier: pid, eventMask: .exit, queue: DispatchQueue.global(qos: .userInitiated))
        source.setEventHandler { [weak self] in
            guard let self = self else { return }
            self.debugLog("Child process \(pid) exited")
            var status: Int32 = 0
            _ = waitpid(pid, &status, 0)
            DispatchQueue.main.async {
                // Verify this notification matches the current childPID
                // This prevents a stale handler from clearing state if a new process started immediately
                guard self.childPID == pid else {
                    self.debugLog("Ignoring stale exit for PID \(pid) (current: \(self.childPID))")
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
                // After an interactive session ends, proactively refocus the command input
                NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: self.id)
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
        guard masterFD >= 0, let data = input.data(using: .utf8) else { return }
        data.withUnsafeBytes { buffer in
            guard let base = buffer.baseAddress else { return }
            _ = Darwin.write(masterFD, base, data.count)
        }
    }
    
    // Check if we have an active PTY (for interactive processes)
    public var hasActivePTY: Bool {
        // Consider PTY active only while the session is running and the FD is valid
        if let handler = ptyHandler {
            return isProcessRunning && handler.isRunning
        }
        let pidAlive = isPIDAlive(childPID)
        let fdOk = masterFD >= 0 && isFDValid(masterFD)
        return isProcessRunning && childPID > 0 && pidAlive && fdOk
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

    // MARK: - PTY attachment helper
    /// Attach a PTYWrapper that was created outside of this class (e.g., by
    /// `SSHSessionManager`). This sets the internal PTY references and marks the
    /// session as running so UI components can interact with it.
    func attachPTY(_ handler: PTYWrapper) {
        // Store the PTY handler and related file descriptors.
        self.ptyHandler = handler
        self.masterFD = handler.masterFD
        self.childPID = handler.childPID
        // The session is now running; we are not using a Foundation.Process.
        self.isProcessRunning = true
        self.process = nil
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
    private func appendOutputChunk(_ chunk: String) {
        guard !chunk.isEmpty else { return }
        processOSCSequences(in: chunk)
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
            NotificationCenter.default.post(name: .terminalTitleDidChange, object: id, userInfo: ["title": title])
        default:
            break
        }
    }
}

// MARK: - Notification extensions
extension Notification.Name {
    static let directoryChanged = Notification.Name("ProTermDirectoryChanged")
    static let terminalTitleDidChange = Notification.Name("ProTermTerminalTitleDidChange")
}