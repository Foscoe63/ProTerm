import SwiftUI
import Foundation
import Combine
import Darwin

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
        output = prompt
    }
    
    func runCommand(_ command: String) {
        let trimmed = command.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        
        // Prevent re-execution
        if isProcessRunning {
            return
        }
        
        // Add command to output
        output = limitOutputSize(output + "\(prompt)\(command)\n")
        
        // Handle cd command
        if trimmed.hasPrefix("cd ") {
            let target = String(trimmed.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            changeDirectory(to: target)
            output = limitOutputSize(output + "\(prompt)")
            return
        }
        
        // Create a real PTY terminal - this IS a real terminal
        let masterFD = posix_openpt(O_RDWR)
        guard masterFD >= 0 else {
            output = limitOutputSize(output + "Error: Could not create pseudo-terminal\n\(prompt)")
            return
        }
        
        guard grantpt(masterFD) == 0 else {
            close(masterFD)
            output = limitOutputSize(output + "Error: Could not grant pseudo-terminal\n\(prompt)")
            return
        }
        
        guard unlockpt(masterFD) == 0 else {
            close(masterFD)
            output = limitOutputSize(output + "Error: Could not unlock pseudo-terminal\n\(prompt)")
            return
        }
        
        let slaveName = ptsname(masterFD)
        guard let slaveName = slaveName else {
            close(masterFD)
            output = limitOutputSize(output + "Error: Could not get slave name\n\(prompt)")
            return
        }
        
        let slaveFD = open(slaveName, O_RDWR)
        guard slaveFD >= 0 else {
            close(masterFD)
            output = limitOutputSize(output + "Error: Could not open slave terminal\n\(prompt)")
            return
        }
        
        // Set up the process with the pseudo-terminal directly
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shellManager.selectedShell.executablePath)
        proc.arguments = ["-l", "-c", command]
        proc.currentDirectoryURL = cwd
        proc.standardInput = FileHandle(fileDescriptor: slaveFD)
        proc.standardOutput = FileHandle(fileDescriptor: slaveFD)
        proc.standardError = FileHandle(fileDescriptor: slaveFD)
        
        // Set up PTY environment variables so sudo recognizes it as a real terminal
        var environment = ProcessInfo.processInfo.environment
        environment["TERM"] = "xterm-256color"
        environment["COLORTERM"] = "truecolor"
        environment["PWD"] = cwd.path
        environment["OLDPWD"] = FileManager.default.homeDirectoryForCurrentUser.path
        environment["TTY"] = String(cString: slaveName)
        environment["SSH_TTY"] = String(cString: slaveName)
        environment["LINES"] = "24"
        environment["COLUMNS"] = "80"
        
        // Additional environment variables that sudo might check
        environment["DISPLAY"] = ProcessInfo.processInfo.environment["DISPLAY"] ?? ""
        environment["SSH_CLIENT"] = ProcessInfo.processInfo.environment["SSH_CLIENT"] ?? ""
        environment["SSH_CONNECTION"] = ProcessInfo.processInfo.environment["SSH_CONNECTION"] ?? ""
        environment["SSH_TTY"] = String(cString: slaveName)
        
        // Force sudo to think it's interactive
        environment["SUDO_ASKPASS"] = "/usr/libexec/authopen"
        
        proc.environment = environment
        
        // Debug: Show PTY setup
        print("DEBUG: PTY Setup - Master FD: \(masterFD), Slave FD: \(slaveFD)")
        print("DEBUG: Slave name: \(String(cString: slaveName))")
        print("DEBUG: TTY env: \(String(cString: slaveName))")
        
        isProcessRunning = true
        
        // Store the master FD for input sending
        self.process = proc
        self.masterFD = masterFD
        self.inputPipe = Pipe()
        
        // Clean up will be handled in the background queue
        
        // Run the process
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                print("DEBUG: About to run process: \(proc.executableURL?.path ?? "unknown")")
                print("DEBUG: Process arguments: \(proc.arguments ?? [])")
                print("DEBUG: Process environment TTY: \(proc.environment?["TTY"] ?? "not set")")
                print("DEBUG: Process environment TERM: \(proc.environment?["TERM"] ?? "not set")")
                print("DEBUG: Command being executed: '\(command)'")
                
                try proc.run()
                print("DEBUG: Process started successfully")
                
                // Wait for process to complete
                proc.waitUntilExit()
                print("DEBUG: Process completed with status: \(proc.terminationStatus)")
                
                // Close slave FD to signal end of input
                close(slaveFD)
                print("DEBUG: Closed slave FD: \(slaveFD)")
                
                print("DEBUG: About to read output from master handle")
                
                // Read all output after process completes
                print("DEBUG: Creating master handle for FD: \(masterFD)")
                let masterHandle = FileHandle(fileDescriptor: masterFD)
                print("DEBUG: Master handle created successfully")
                
                print("DEBUG: About to call readDataToEndOfFile()")
                let allData = masterHandle.readDataToEndOfFile()
                print("DEBUG: Read \(allData.count) bytes from process")
                
                if let outputString = String(data: allData, encoding: .utf8), !outputString.isEmpty {
                    print("DEBUG: Process output: '\(outputString)'")
                    DispatchQueue.main.async {
                        self.output = self.limitOutputSize(self.output + outputString)
                        self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                        self.isProcessRunning = false
                        self.process = nil
                        self.inputPipe = nil
                        self.masterFD = -1
                    }
                } else {
                    print("DEBUG: No output from process (empty or encoding failed)")
                    // Check if this was a sudo command that failed
                    if command.hasPrefix("sudo ") && proc.terminationStatus == 1 {
                        let sudoMessage = """
                        
                        ⚠️  Sudo Command Failed
                        
                        ProTerm is a terminal emulator, but sudo requires a "real" terminal for security reasons.
                        
                        Alternatives:
                        • Use the system Terminal app for sudo commands
                        • Run: sudo -S (to read password from stdin)
                        • Configure sudo to not require a terminal
                        
                        """
                        print("DEBUG: Adding sudo error message")
                        DispatchQueue.main.async {
                            self.output = self.limitOutputSize(self.output + sudoMessage)
                            self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                            self.isProcessRunning = false
                            self.process = nil
                            self.inputPipe = nil
                            self.masterFD = -1
                        }
                    } else {
                        print("DEBUG: Adding regular prompt")
                        DispatchQueue.main.async {
                            self.output = self.limitOutputSize(self.output + "\(self.prompt)")
                            self.isProcessRunning = false
                            self.process = nil
                            self.inputPipe = nil
                            self.masterFD = -1
                        }
                    }
                }
                
                // Clean up
                close(masterFD)
                
            } catch {
                DispatchQueue.main.async {
                    self.isProcessRunning = false
                    self.output = self.limitOutputSize(self.output + "Error: \(error.localizedDescription)\n\(self.prompt)")
                }
                close(slaveFD)
                close(masterFD)
            }
        }
    }
    
    private func changeDirectory(to path: String) {
        var newURL = cwd
        if path == "~" {
            newURL = FileManager.default.homeDirectoryForCurrentUser
        } else if path.hasPrefix("/") {
            newURL = URL(fileURLWithPath: path, isDirectory: true)
        } else {
            newURL = cwd.appendingPathComponent(path, isDirectory: true)
        }
        
        var isDir: ObjCBool = false
        if FileManager.default.fileExists(atPath: newURL.path, isDirectory: &isDir), isDir.boolValue {
            cwd = newURL.standardizedFileURL
            // Post notification for status bar update
            let displayPath = getDisplayPath()
            NotificationCenter.default.post(name: .directoryChanged, object: displayPath)
        } else {
            output = limitOutputSize(output + "cd: \(path): No such file or directory\n")
        }
    }
    
    private func getDisplayPath() -> String {
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var displayPath = cwd.path.replacingOccurrences(of: homePath, with: "~")
        if displayPath.isEmpty { displayPath = "~" }
        return displayPath
    }
    
    // Required compatibility methods
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
    private var masterFD: Int32 = -1
    
    func clearOutput() {
        output = "Welcome to ProTerm!\n____________________\nType commands in the terminal…\n\(prompt)"
    }
    
    public func sendInput(_ input: String) {
        // Send input to the current process for interactive commands like sudo
        if let process = process, process.isRunning, masterFD >= 0 {
            // Write to the master FD of the PTY
            let data = (input + "\n").data(using: .utf8) ?? Data()
            let bytesWritten = data.withUnsafeBytes { bytes in
                write(masterFD, bytes.bindMemory(to: UInt8.self).baseAddress, data.count)
            }
            if bytesWritten < 0 {
                print("Error writing to PTY: \(String(cString: strerror(errno)))")
            }
        }
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