import SwiftUI
import Foundation
import Combine
import Darwin

// Note: We'll use availableData directly with shutdown flag checks
// The shutdown flag prevents reading from closed FDs

// PTY constants
private let TIOCSCTTY: UInt = 0x20007461

/// Ultra-minimal terminal session with ZERO complexity
@MainActor
class TerminalSession: NSObject, ObservableObject, Identifiable {
    let id = UUID()
    
    @Published var output: String = ""
    @Published var isProcessRunning: Bool = false
    
    // Limit output size to prevent performance issues
    private let maxOutputLength = 50000 // 50KB limit
    
    var cwd: URL = FileManager.default.homeDirectoryForCurrentUser
    private let shellManager: ShellManager
    
    // Terminal width for COLUMNS environment variable
    var terminalWidth: CGFloat = 80 {
        didSet {
            // Update COLUMNS when width changes
            updateColumns()
        }
    }
    private var columns: Int = 80
    
    // Strong references for running process and I/O to ensure handlers fire
    private var outputReadHandle: FileHandle?
    
    // PTY support for interactive commands like sudo
    private var masterFD: Int32 = -1
    private var slaveFD: Int32 = -1
    private var ptyReadHandle: FileHandle?
    private var isShuttingDown: Bool = false
    
    // Thread-safe shutdown flag for readability handlers
    private nonisolated(unsafe) var shutdownFlag: Bool = false
    
    private func updateColumns() {
        // Calculate columns based on terminal width
        // Menlo 12pt font: average character width is approximately 7.2 points
        // Account for padding (20 points total: 10 on each side)
        let availableWidth = max(40, terminalWidth - 20) // Minimum 40 points
        columns = max(40, Int(availableWidth / 7.2)) // Minimum 40 columns
    }
    
    var prompt: String {
        let user = NSUserName()
        let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var displayPath = cwd.path.replacingOccurrences(of: homePath, with: "~")
        if displayPath.isEmpty { displayPath = "~" }
        return "\(user)@\(host) \(displayPath) % "
    }

    init(shellManager: ShellManager) {
        self.shellManager = shellManager
        super.init()
        // Initialize columns based on default width
        updateColumns()
        // Show an initial prompt so the terminal never looks empty
        output = "\(prompt)"
    }
    
    func runCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
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
                shutdownFlag = true
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
                shutdownFlag = false
                
                // Add prompt if needed
                if !output.hasSuffix("\n") {
                    output.append("\n")
                }
                if !output.hasSuffix(prompt) {
                    output = limitOutputSize(output + prompt)
                }
                
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
        
        // Echo the command on the same line as the prompt (no newline yet)
        // The output will naturally start on the next line
        let currentOutput = output
        if currentOutput.hasSuffix(prompt) {
            // Command goes on the same line as the prompt
            output = limitOutputSize(currentOutput + "\(command)")
        } else {
            // If no prompt, just add the command
            output = limitOutputSize(currentOutput + "\(command)")
        }
        
        // Handle cd command
        if trimmed.hasPrefix("cd ") {
            let target = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            changeDirectory(to: target)
            // Add newline and prompt after cd (output already has the command on the same line)
            if !output.hasSuffix("\n") {
                output.append("\n")
            }
            output = limitOutputSize(output + "\(prompt)")
            return
        }
        
        // Handle sudo command with PTY (case-insensitive)
        if trimmed.lowercased().hasPrefix("sudo") {
            runSudoCommand(command)
            return
        }
        
        // Handle interactive commands with PTY (python, python3, node, etc.)
        let interactiveCommands = ["python", "python3", "node", "irb", "ruby", "ghci", "ipython"]
        let commandName = trimmed.components(separatedBy: .whitespaces).first?.lowercased() ?? ""
        if interactiveCommands.contains(commandName) {
            // Add newline after command so output appears on next line
            if !output.hasSuffix("\n") {
                output.append("\n")
            }
            runInteractiveCommand(command)
            return
        }

        // Handle ls command - force column output since we're not a real TTY
        var commandToRun = command
        if trimmed == "ls" || trimmed.hasPrefix("ls ") {
            // Check if -C (force column) or -1 (one column) is already specified
            if !trimmed.contains(" -C") && !trimmed.contains(" -1") && !trimmed.contains(" -l") && !trimmed.contains(" -la") && !trimmed.contains(" -lh") {
                // Replace "ls" with "ls -C" to force column output
                commandToRun = command.replacingOccurrences(of: "^ls\\b", with: "ls -C", options: .regularExpression)
            }
        }
        
        // Run other commands (asynchronously; do NOT block the main actor)
        let proc = Process()
        let shellPath = shellManager.selectedShell.executablePath
        
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = ["-l", "-c", commandToRun]  // Use -l (login shell) to load .zshrc/.bash_profile
        proc.currentDirectoryURL = cwd

        // Inherit environment and force color-friendly settings similar to Terminal
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["COLUMNS"] = "\(columns)"          // Set terminal width for column-based output (ls, etc.)
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
            guard let self = self else { return }
            let data = fh.availableData
            guard !data.isEmpty else { return }
            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
            
            DispatchQueue.main.async {
                // Ensure output starts on a new line if command is still on the same line
                var outputToAdd = chunk
                if !self.output.hasSuffix("\n") && !self.output.isEmpty {
                    // Command is still on the same line, add newline before output
                    outputToAdd = "\n" + chunk
                }
                self.output = self.limitOutputSize(self.output + outputToAdd)
            }
        }

        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            // Stop the readability handler
            handle.readabilityHandler = nil
            
            // Read all remaining data - this is critical for fast commands
            // Use a background queue to avoid blocking
            DispatchQueue.global(qos: .userInitiated).async {
                // Read any remaining buffered data
                var remainingData = Data()
                var attempts = 0
                while attempts < 10 {
                    let chunk = handle.availableData
                    if chunk.isEmpty {
                        attempts += 1
                        if attempts < 10 {
                            Thread.sleep(forTimeInterval: 0.01)
                        }
                    } else {
                        attempts = 0
                        remainingData.append(chunk)
                    }
                }
                
                // Final read to get everything
                let finalChunk = handle.readDataToEndOfFile()
                if !finalChunk.isEmpty {
                    remainingData.append(finalChunk)
                }
                
                // Update UI on main thread
                if !remainingData.isEmpty,
                   let remainingString = String(data: remainingData, encoding: .utf8),
                   !remainingString.isEmpty {
                    DispatchQueue.main.async {
                        // Ensure output starts on a new line if command is still on the same line
                        var outputToAdd = remainingString
                        if !self.output.hasSuffix("\n") && !self.output.isEmpty {
                            // Command is still on the same line, add newline before output
                            outputToAdd = "\n" + remainingString
                        }
                        self.output = self.limitOutputSize(self.output + outputToAdd)
                    }
                }
                
            DispatchQueue.main.async {
                    self.isProcessRunning = false
                    // Ensure output ends with a newline before adding the prompt
                    if !self.output.hasSuffix("\n") {
                        self.output.append("\n")
                    }
                    // Add the new prompt on a new line
                    self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                    // Release retained resources
                    self.outputReadHandle = nil
                    self.inputPipe = nil
                    self.process = nil
                }
            }
        }

        do {
            isProcessRunning = true
            try proc.run()
            
            // Safety check: verify process is still running after a delay
            // This ensures isProcessRunning is reset even if terminationHandler doesn't fire
            DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                Task { @MainActor in
                    if self.isProcessRunning {
                        if let proc = self.process, !proc.isRunning {
                            // Process finished but handler didn't fire - reset manually
                            self.isProcessRunning = false
                            if !self.output.hasSuffix("\n") {
                                self.output.append("\n")
                            }
                            self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                        }
                    }
                }
            }
        } catch {
            handle.readabilityHandler = nil
            isProcessRunning = false
            output = limitOutputSize(output + "Error: \(error.localizedDescription)\n\(prompt)")
            // Release retained resources
            self.outputReadHandle = nil
            self.inputPipe = nil
            self.process = nil
        }
    }
    
    private func changeDirectory(to path: String) {
        guard !path.isEmpty else {
            // Empty path means cd to home directory
            cwd = FileManager.default.homeDirectoryForCurrentUser
            return
        }
        
        var newURL = cwd
        if path == "~" {
            newURL = FileManager.default.homeDirectoryForCurrentUser
        } else if path.hasPrefix("/") {
            // Absolute path
            newURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            // Relative path - append to current directory
            newURL = cwd.appendingPathComponent(path, isDirectory: true)
        }

        // Resolve symlinks and standardize the path
        newURL = newURL.standardizedFileURL
        
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: newURL.path, isDirectory: &isDir), isDir.boolValue {
            cwd = newURL
        } else {
            // Error message - ensure it's on a new line
            if !output.hasSuffix("\n") {
                output.append("\n")
            }
            output = limitOutputSize(output + "cd: \(path): No such file or directory\n")
        }
    }
    
    // MARK: - PTY-based command execution
    
    private func runInteractiveCommand(_ command: String) {
        // Use PTY for interactive commands - simpler setup, no helper needed
        runPTYCommandSimple(command)
    }
    
    private func runSudoCommand(_ command: String) {
        // Use PTY for sudo with full terminal setup (needs helper for setsid)
        runPTYCommandWithHelper(command)
    }
    
    private func runPTYCommandSimple(_ command: String) {
        // Create a PTY (pseudo-terminal) for interactive commands
        masterFD = posix_openpt(O_RDWR)
        guard masterFD >= 0 else {
            output = limitOutputSize(output + "\nError: Failed to create PTY\n\(prompt)")
            return
        }
        
        guard grantpt(masterFD) == 0 else {
            close(masterFD)
            masterFD = -1
            output = limitOutputSize(output + "\nError: Failed to grant PTY\n\(prompt)")
            return
        }
        
        guard unlockpt(masterFD) == 0 else {
            close(masterFD)
            masterFD = -1
            output = limitOutputSize(output + "\nError: Failed to unlock PTY\n\(prompt)")
            return
        }
        
        guard let slaveNameCString = ptsname(masterFD) else {
            close(masterFD)
            masterFD = -1
            output = limitOutputSize(output + "\nError: Failed to get PTY name\n\(prompt)")
            return
        }
        
        let slaveName = String(cString: slaveNameCString)
        slaveFD = open(slaveName, O_RDWR)
        guard slaveFD >= 0 else {
            close(masterFD)
            masterFD = -1
            output = limitOutputSize(output + "\nError: Failed to open slave PTY\n\(prompt)")
            return
        }
        
        // Set up the process with the pseudo-terminal
        // Run through shell to ensure proper environment and PATH resolution
        let proc = Process()
        let shellPath = shellManager.selectedShell.executablePath
        
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = ["-l", "-c", command]
        proc.currentDirectoryURL = cwd
        
        // Set up PTY environment variables
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PWD"] = cwd.path
        environment["OLDPWD"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["TTY"] = slaveName
        environment["SSH_TTY"] = slaveName
        environment["LINES"] = "24"
        environment["COLUMNS"] = "\(columns)"
        // Force Python to use unbuffered output so we see it immediately
        environment["PYTHONUNBUFFERED"] = "1"
        proc.environment = environment
        
        // Connect stdin, stdout, stderr to the slave PTY
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        
        isProcessRunning = true
        self.process = proc
        
        // Create a file handle for reading from the master PTY
        ptyReadHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        
        // Capture values for termination handler
        let capturedSlaveFD = slaveFD
        let capturedMasterFD = masterFD
        
        // Stream output from the master PTY
        ptyReadHandle?.readabilityHandler = { [weak self] fh in
            guard let self = self else {
                fh.readabilityHandler = nil
                return
            }
            
            // Check shutdown flag FIRST - if set, stop immediately without reading
            // This prevents calling availableData on a closed FD
            if self.shutdownFlag {
                fh.readabilityHandler = nil
                return
            }
            
            // Double-check FD is still valid
            if capturedMasterFD < 0 {
                fh.readabilityHandler = nil
                return
            }
            
            // Read data - we've already checked shutdown flag and FD validity
            // If shutdown flag is set, we wouldn't have gotten here
            // availableData can throw NSException if FD is closed, but we check shutdown flag first
            let data = fh.availableData
            
            // Check again after reading
            if self.shutdownFlag || capturedMasterFD < 0 {
                fh.readabilityHandler = nil
                return
            }
            
            // Empty data means EOF - stop the handler
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
            
            Task { @MainActor in
                // Final check before updating output
                guard !self.isShuttingDown && self.masterFD >= 0 else { return }
                
                var outputToAdd = chunk
                if !self.output.hasSuffix("\n") && !self.output.isEmpty {
                    outputToAdd = "\n" + chunk
                }
                self.output = self.limitOutputSize(self.output + outputToAdd)
            }
        }
        
        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            
            // Set shutdown flag FIRST to prevent handler from reading
            Task { @MainActor in
                self.isShuttingDown = true
                self.shutdownFlag = true  // Set nonisolated flag for handler
                self.ptyReadHandle?.readabilityHandler = nil
            }
            
            // Wait a bit to ensure handler has fully stopped before closing FDs
            DispatchQueue.global(qos: .userInitiated).async {
                // Wait longer for handler to stop and any in-flight reads to complete
                // This gives time for any queued handler calls to check the shutdown flag
                Thread.sleep(forTimeInterval: 0.5)
                
                // Don't try to read remaining data - the readability handler should have already read everything
                // Just close the file descriptors
                if capturedSlaveFD >= 0 {
                    close(capturedSlaveFD)
                }
                if capturedMasterFD >= 0 {
                    close(capturedMasterFD)
                }
                
                // Final cleanup on main thread
                Task { @MainActor in
                    self.isProcessRunning = false
                    if !self.output.hasSuffix("\n") {
                        self.output.append("\n")
                    }
                    self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                    self.ptyReadHandle = nil
                    self.process = nil
                    self.slaveFD = -1
                    self.masterFD = -1
                    self.isShuttingDown = false
                    self.shutdownFlag = false
                }
            }
        }
        
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
                
                // Periodic check to detect when process exits (for interactive processes like Python)
                // This ensures we detect exit even if terminationHandler is delayed
                // Check more frequently for faster detection
                func checkProcess() {
                    Task { @MainActor in
                        if self.isProcessRunning {
                            if let proc = self.process, !proc.isRunning {
                                // Process finished - trigger cleanup immediately
                                // Set shutdown flag FIRST to prevent handler from reading
                                self.isShuttingDown = true
                                self.shutdownFlag = true  // Set nonisolated flag for handler
                                // Stop readability handler before closing file descriptors
                                self.ptyReadHandle?.readabilityHandler = nil
                                
                                // Capture FD values before entering background queue
                                let capturedSlaveFD = self.slaveFD
                                let capturedMasterFD = self.masterFD
                                
                                // Small delay to ensure handler has stopped
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    // Now safe to close file descriptors
                                    DispatchQueue.global(qos: .userInitiated).async {
                                        if capturedSlaveFD >= 0 {
                                            close(capturedSlaveFD)
                                        }
                                        if capturedMasterFD >= 0 {
                                            close(capturedMasterFD)
                                        }
                                        
                                        Task { @MainActor in
                                            self.isProcessRunning = false
                                            if !self.output.hasSuffix("\n") {
                                                self.output.append("\n")
                                            }
                                            self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                                            self.ptyReadHandle = nil
                                            self.process = nil
                                            self.slaveFD = -1
                                            self.masterFD = -1
                                            self.isShuttingDown = false
                                            self.shutdownFlag = false
                                        }
                                    }
                                }
                            } else {
                                // Process still running, check again in 0.1 seconds (very frequent)
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                    checkProcess()
                                }
                            }
                        }
                    }
                }
                
                // Start checking immediately and then every 0.1 seconds for faster detection
                checkProcess()  // Check immediately
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    checkProcess()
                }
            } catch {
                Task { @MainActor in
                    self.isShuttingDown = true
                    self.shutdownFlag = true  // Set nonisolated flag for handler
                    self.ptyReadHandle?.readabilityHandler = nil
                    self.isProcessRunning = false
                    self.output = self.limitOutputSize(self.output + "\nError: \(error.localizedDescription)\n\(self.prompt)")
                    
                    // Capture FD values before entering background queue
                    let capturedSlaveFD = self.slaveFD
                    let capturedMasterFD = self.masterFD
                    
                    DispatchQueue.global(qos: .userInitiated).async {
                        if capturedSlaveFD >= 0 {
                            close(capturedSlaveFD)
                        }
                        if capturedMasterFD >= 0 {
                            close(capturedMasterFD)
                        }
                        
                        Task { @MainActor in
                            self.slaveFD = -1
                            self.masterFD = -1
                            self.ptyReadHandle = nil
                            self.process = nil
                            self.isShuttingDown = false
                            self.shutdownFlag = false
                        }
                    }
                }
            }
        }
    }
    
    private func runPTYCommandWithHelper(_ command: String) {
        // Create a PTY (pseudo-terminal) for interactive commands
        masterFD = posix_openpt(O_RDWR)
        guard masterFD >= 0 else {
            output = limitOutputSize(output + "\nError: Failed to create PTY\n\(prompt)")
            return
        }
        
        guard grantpt(masterFD) == 0 else {
            close(masterFD)
            masterFD = -1
            output = limitOutputSize(output + "\nError: Failed to grant PTY\n\(prompt)")
            return
        }
        
        guard unlockpt(masterFD) == 0 else {
            close(masterFD)
            masterFD = -1
            output = limitOutputSize(output + "\nError: Failed to unlock PTY\n\(prompt)")
            return
        }
        
        guard let slaveNameCString = ptsname(masterFD) else {
            close(masterFD)
            masterFD = -1
            output = limitOutputSize(output + "\nError: Failed to get PTY name\n\(prompt)")
            return
        }
        
        let slaveName = String(cString: slaveNameCString)
        slaveFD = open(slaveName, O_RDWR)
        guard slaveFD >= 0 else {
            close(masterFD)
            masterFD = -1
            output = limitOutputSize(output + "\nError: Failed to open slave PTY\n\(prompt)")
            return
        }
        
        // Create a C helper program that sets up the controlling terminal
        // This is necessary because macOS doesn't have setsid, and we need
        // to call setsid() and ioctl(TIOCSCTTY) from within the child process
        let helperSource = """
        #include <unistd.h>
        #include <stdlib.h>
        #include <stdio.h>
        #include <fcntl.h>
        #include <sys/ioctl.h>
        #include <sys/wait.h>
        
        #ifndef TIOCSCTTY
        #define TIOCSCTTY 0x20007461
        #endif
        
        int main(int argc, char *argv[]) {
            if (argc < 2) {
                fprintf(stderr, "Usage: %s <command> [args...]\\n", argv[0]);
                exit(1);
            }
            
            // Fork to create a child process
            pid_t pid = fork();
            if (pid < 0) {
                perror("fork");
                exit(1);
            }
            
            if (pid == 0) {
                // Child process: create new session and set controlling terminal
                if (setsid() == -1) {
                    // If setsid fails, continue anyway - might already be in a session
                    // perror("setsid");
                }
                
                // Set controlling terminal (this must be done in the child process)
                // stdin should already be connected to the slave PTY by the Process class
                // We just need to set it as the controlling terminal
                // Try stdin first (should be the slave PTY)
                if (ioctl(STDIN_FILENO, TIOCSCTTY, 0) == -1) {
                    // If stdin doesn't work, try opening the slave PTY from environment
                    char *slavePath = getenv("PROTERM_SLAVE_PTY");
                    if (slavePath) {
                        int slaveFD = open(slavePath, O_RDWR);
                        if (slaveFD >= 0) {
                            ioctl(slaveFD, TIOCSCTTY, 0);
                            // Don't close - keep it open for the exec'd process
                            // The file descriptor will be inherited
                        }
                    }
                }
                
                // Execute the command (stdin/stdout/stderr are already set by Process class)
                execvp(argv[1], &argv[1]);
                perror("execvp");
                exit(1);
            } else {
                // Parent process: wait for child
                int status;
                waitpid(pid, &status, 0);
                exit(WIFEXITED(status) ? WEXITSTATUS(status) : 1);
            }
        }
        """
        
        // Compile the helper program
        let helperURL = FileManager.default.temporaryDirectory.appendingPathComponent("proterm_helper_\(UUID().uuidString)")
        let sourceURL = helperURL.appendingPathExtension("c")
        let binaryURL = helperURL.appendingPathExtension("out")
        
        do {
            try helperSource.write(to: sourceURL, atomically: true, encoding: .utf8)
            
            // Compile the C program synchronously (this is fast)
            let compileProc = Process()
            compileProc.executableURL = URL(fileURLWithPath: "/usr/bin/cc")
            compileProc.arguments = ["-o", binaryURL.path, sourceURL.path]
            
            // Capture compilation errors
            let compilePipe = Pipe()
            compileProc.standardError = compilePipe
            compileProc.standardOutput = compilePipe
            
            try compileProc.run()
            compileProc.waitUntilExit()
            
            if compileProc.terminationStatus != 0 {
                let errorData = compilePipe.fileHandleForReading.readDataToEndOfFile()
                let errorString = String(data: errorData, encoding: .utf8) ?? "Unknown compilation error"
                output = limitOutputSize(output + "\nError: Failed to compile helper program: \(errorString)\n\(prompt)")
                try? FileManager.default.removeItem(at: sourceURL)
                return
            }
            
            // Clean up source file
            try? FileManager.default.removeItem(at: sourceURL)
            
            // Make binary executable
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: binaryURL.path)
        } catch {
            output = limitOutputSize(output + "\nError: Failed to create helper program: \(error.localizedDescription)\n\(prompt)")
            return
        }
        
        // Set up the process with the helper
        let proc = Process()
        let shellPath = shellManager.selectedShell.executablePath
        
        // Use the helper to run the shell with proper terminal setup
        proc.executableURL = binaryURL
        proc.arguments = [shellPath, "-l", "-c", command]
        proc.currentDirectoryURL = cwd
        
        // Set up PTY environment variables so sudo recognizes it as a real terminal
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PWD"] = cwd.path
        environment["OLDPWD"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["TTY"] = slaveName
        environment["SSH_TTY"] = slaveName
        environment["PROTERM_SLAVE_PTY"] = slaveName  // Pass slave PTY path to helper
        environment["LINES"] = "24"
        environment["COLUMNS"] = "\(columns)"
        // Force Python to use unbuffered output so we see it immediately
        environment["PYTHONUNBUFFERED"] = "1"
        proc.environment = environment
        
        // Connect stdin, stdout, stderr to the slave PTY
        // All three use the same slave FD (this is correct for PTY)
        let slaveHandle = FileHandle(fileDescriptor: slaveFD, closeOnDealloc: false)
        proc.standardInput = slaveHandle
        proc.standardOutput = slaveHandle
        proc.standardError = slaveHandle
        
        isProcessRunning = true
        self.process = proc
        
        // Create a file handle for reading from the master PTY
        ptyReadHandle = FileHandle(fileDescriptor: masterFD, closeOnDealloc: false)
        
        // Capture values we need for the termination handler BEFORE setting it
        // (to avoid accessing main actor properties from Sendable closure)
        let capturedSlaveFD = slaveFD
        let capturedMasterFD = masterFD
        let capturedBinaryURL = binaryURL  // Capture for cleanup
        
        // Stream output from the master PTY
        ptyReadHandle?.readabilityHandler = { [weak self] fh in
            guard let self = self else {
                fh.readabilityHandler = nil
                return
            }
            
            // Check shutdown flag FIRST - if set, stop immediately without reading
            // This prevents calling availableData on a closed FD
            if self.shutdownFlag {
                fh.readabilityHandler = nil
                return
            }
            
            // Double-check FD is still valid
            if capturedMasterFD < 0 {
                fh.readabilityHandler = nil
                return
            }
            
            // Read data - we've already checked shutdown flag and FD validity
            // If shutdown flag is set, we wouldn't have gotten here
            // availableData can throw NSException if FD is closed, but we check shutdown flag first
            let data = fh.availableData
            
            // Check again after reading
            if self.shutdownFlag || capturedMasterFD < 0 {
                fh.readabilityHandler = nil
                return
            }
            
            // Empty data means EOF - stop the handler
            guard !data.isEmpty else {
                fh.readabilityHandler = nil
                return
            }
            guard let chunk = String(data: data, encoding: .utf8), !chunk.isEmpty else { return }
            
            Task { @MainActor in
                // Final check before updating output
                guard !self.isShuttingDown && self.masterFD >= 0 else { return }
                
                var outputToAdd = chunk
                if !self.output.hasSuffix("\n") && !self.output.isEmpty {
                    outputToAdd = "\n" + chunk
                }
                self.output = self.limitOutputSize(self.output + outputToAdd)
            }
        }
        
        proc.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            
            // Set shutdown flag FIRST to prevent handler from reading
            Task { @MainActor in
                self.isShuttingDown = true
                self.shutdownFlag = true  // Set nonisolated flag for handler
                self.ptyReadHandle?.readabilityHandler = nil
            }
            
            // Wait a bit to ensure handler has fully stopped before closing FDs
            DispatchQueue.global(qos: .userInitiated).async {
                // Wait longer for handler to stop and any in-flight reads to complete
                // This gives time for any queued handler calls to check the shutdown flag
                Thread.sleep(forTimeInterval: 0.5)
                
                // Don't try to read remaining data - the readability handler should have already read everything
                // Just close the file descriptors
                if capturedSlaveFD >= 0 {
                    close(capturedSlaveFD)
                }
                if capturedMasterFD >= 0 {
                    close(capturedMasterFD)
                }
                
                // Clean up helper binary
                try? FileManager.default.removeItem(at: capturedBinaryURL)
                
                // Final cleanup on main thread
                Task { @MainActor in
                    self.isProcessRunning = false
                    if !self.output.hasSuffix("\n") {
                        self.output.append("\n")
                    }
                    self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                    self.ptyReadHandle = nil
                    self.process = nil
                    // Clear the FDs on main actor
                    self.slaveFD = -1
                    self.masterFD = -1
                    self.isShuttingDown = false
                    self.shutdownFlag = false
                }
            }
        }
        
        // Run the process asynchronously
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try proc.run()
                // Process is now running - it will complete and trigger terminationHandler
                // We don't wait here to avoid blocking
                
                // Safety check: verify process is still running after a delay
                // This ensures isProcessRunning is reset even if terminationHandler doesn't fire
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                    Task { @MainActor in
                        if self.isProcessRunning {
                            if let proc = self.process, !proc.isRunning {
                                // Process finished but handler didn't fire - reset manually
                                self.isProcessRunning = false
                                if !self.output.hasSuffix("\n") {
                                    self.output.append("\n")
                                }
                                self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                            }
                        }
                    }
                }
            } catch {
                // Clean up on error
                Task { @MainActor in
                    self.isShuttingDown = true
                    self.shutdownFlag = true  // Set nonisolated flag for handler
                    self.ptyReadHandle?.readabilityHandler = nil
                    self.isProcessRunning = false
                    self.output = self.limitOutputSize(self.output + "\nError: \(error.localizedDescription)\n\(self.prompt)")
                    
                    // Capture FD values before entering background queue
                    let capturedSlaveFD = self.slaveFD
                    let capturedMasterFD = self.masterFD
                    
                    DispatchQueue.global(qos: .userInitiated).async {
                        if capturedSlaveFD >= 0 {
                            close(capturedSlaveFD)
                        }
                        if capturedMasterFD >= 0 {
                            close(capturedMasterFD)
                        }
                        
                        Task { @MainActor in
                            self.slaveFD = -1
                            self.masterFD = -1
                            self.ptyReadHandle = nil
                            self.process = nil
                            self.isShuttingDown = false
                            self.shutdownFlag = false
                        }
                    }
                }
            }
        }
    }
    
    // Required compatibility methods
    public func sendInput(_ input: String) {
        // Send input to the current process for interactive commands (sudo, python, etc.)
        // Use the captured masterFD to avoid main actor isolation issues
        let fd = masterFD
        guard fd >= 0 else { return }
        
        DispatchQueue.global(qos: .userInitiated).async {
            let data = (input + "\n").data(using: .utf8) ?? Data()
            let bytesWritten = data.withUnsafeBytes { bytes in
                write(fd, bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
            if bytesWritten < 0 {
                print("Error writing to PTY: \(String(cString: strerror(errno)))")
            }
        }
    }
    
    // Check if we have an active PTY (for interactive processes)
    public var hasActivePTY: Bool {
        return masterFD >= 0 && isProcessRunning
    }
    
    func sendSignal(_ signal: Int32) {}
    func terminate() {}
    func resumeProcess() {}
    
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
        output = limitOutputSize(output + "\(prompt)")
    }
    
    private func limitOutputSize(_ text: String) -> String {
        if text.count <= maxOutputLength {
            return text
        }
        
        // Keep the last portion of the output to maintain recent history
        let startIndex = text.index(text.endIndex, offsetBy: -maxOutputLength)
        return String(text[startIndex...])
    }
}

// MARK: - Notification extensions
extension Notification.Name {
    static let directoryChanged = Notification.Name("ProTermDirectoryChanged")
}