import Foundation
import Darwin

// Terminal control structures
#if os(macOS) || os(iOS)
import Darwin.C
#else
import Glibc
#endif

/// PTYWrapper encapsulates a pseudo‑terminal for interactive subprocesses.
final class PTYWrapper: @unchecked Sendable {
    // MARK: - Public API

    /// Closure called whenever the PTY produces output.
    var onOutput: ((String) -> Void)?

    /// Indicates whether the child process is still running.
    var isRunning: Bool {
        guard childPID > 0 else { return false }
        // kill with signal 0 checks existence without sending a signal
        return kill(childPID, 0) == 0
    }

    /// Initialise a PTY and spawn the given command.
    /// - Parameters:
    ///   - command: Full path to executable (e.g. `/bin/bash`).
    ///   - args: Arguments passed to the command.
    ///   - env: Optional environment dictionary.
    init(command: String, args: [String] = [], env: [String:String]? = nil) {
        // 1️⃣ Create master PTY
        var master: Int32 = -1
        master = posix_openpt(O_RDWR)
        guard master != -1 else {
            fatalError("posix_openpt failed")
        }

        // 2️⃣ Grant and unlock the slave side
        guard grantpt(master) == 0 else { fatalError("grantpt failed") }
        guard unlockpt(master) == 0 else { fatalError("unlockpt failed") }

        // 3️⃣ Obtain slave device name
        guard let slaveNameC = ptsname(master) else { fatalError("ptsname failed") }
        let slavePath = String(cString: slaveNameC)

        // 4️⃣ Open the slave side
        let slave = open(slavePath, O_RDWR)
        guard slave != -1 else { fatalError("open slave failed") }
        
        // Standard terminal attributes are obtained. 
        // We set the TTY to raw mode to disable local echo and line editing,
        // as ProTerm handles these locally via its UI components.
        var tio = termios()
        if tcgetattr(slave, &tio) == 0 {
            cfmakeraw(&tio)
            // Ensure we don't map CR to NL or vice versa on input/output
            // so the PTY passes characters through exactly as received.
            tio.c_iflag &= ~UInt(ICRNL | INLCR | IGNCR)
            tio.c_oflag &= ~UInt(ONLCR | OCRNL)
            _ = tcsetattr(slave, TCSANOW, &tio)
        }
        
        // Set window size on slave (SSH needs this)
        // Read configured columns from UserDefaults (default: 80)
        let defaults = UserDefaults.standard
        let configuredColumns = defaults.object(forKey: "ProTermTerminalColumns") as? Int ?? 80
        let columns = max(40, min(200, configuredColumns))  // Clamp to valid range
        
        var ws = winsize()
        ws.ws_row = 24  // Default rows
        ws.ws_col = UInt16(columns)  // Use configured columns
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0
        _ = ioctl(slave, TIOCSWINSZ, &ws)

        // 5️⃣ Use posix_spawn with proper file actions (fork() is unavailable in Swift on macOS toolchains)
        var pid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        // Duplicate slave to stdio in the child
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        // Close master and slave appropriately in the child
        posix_spawn_file_actions_addclose(&fileActions, master)

        // Build argv
        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(command))
        for a in args { cArgs.append(strdup(a)) }
        cArgs.append(nil)

        // Build environment
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        if let envDict = env {
            for (k, v) in envDict {
                cEnv.append(strdup("\(k)=\(v)"))
            }
        }
        cEnv.append(nil)

        // Spawn with a new session; on success, the slave duplicated to stdin becomes ctty
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let spawnResult = posix_spawn(&pid, command, &fileActions, &attr, cArgs, env != nil ? cEnv : nil)
        posix_spawnattr_destroy(&attr)

        // Free C strings
        for ptr in cArgs where ptr != nil { free(ptr) }
        if env != nil { for ptr in cEnv where ptr != nil { free(ptr) } }

        guard spawnResult == 0 else { fatalError("posix_spawn failed: \(spawnResult)") }

        childPID = pid
        // Close slave in parent
        close(slave)
        masterFD = master

        // Make master non‑blocking
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
    
    }

    // MARK: - Private state
    internal var masterFD: Int32 = -1
    internal var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?

    // MARK: - Reading
    private func beginReading() {
        guard masterFD != -1 else {
            return
        }
        // Cancel any existing read source to avoid duplicates
        readSource?.cancel()
        readSource = nil
        
        
        let queue = DispatchQueue(label: "com.proterm.pty.read")
        readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        readSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 4096)
            let bytes = read(self.masterFD, &buffer, buffer.count)
            if bytes > 0 {
                let data = Data(buffer[0..<bytes])
                if let str = String(data: data, encoding: .utf8) {
                    self.onOutput?(str)
                } else {
                }
            } else if bytes == 0 {
                // EOF – child exited
                self.stop()
            } else {
                // Error reading
            }
        }
        readSource?.setCancelHandler { [weak self] in
            if let fd = self?.masterFD, fd != -1 {
                close(fd)
            }
        }
        readSource?.resume()
    }

    // MARK: - Public I/O
    /// Write a string to the PTY (e.g. user keystrokes).
    /// Public method to start reading PTY output with a handler.
    public func startReading(_ handler: @escaping (String) -> Void) {
        // Assign the closure to be called on each output chunk.
        self.onOutput = handler
        // Begin the internal read loop.
        beginReading()
    }
    
    func write(_ string: String) {
        guard masterFD != -1 else {
            return
        }
        if let data = string.data(using: .utf8) {
            _ = data.withUnsafeBytes { ptr in
                Darwin.write(masterFD, ptr.baseAddress!, data.count)
            }
        } else {
        }
    }

    // MARK: - Cleanup
    /// Terminate the child process and close file descriptors.
    func stop() {
        if let src = readSource {
            src.cancel()
            readSource = nil
        }
        if childPID > 0 {
            kill(childPID, SIGTERM)
            _ = waitpid(childPID, nil, 0)
        }
        if masterFD != -1 {
            close(masterFD)
            masterFD = -1
        }
    }

    public init(shellPath: String, command: String, rows: Int, columns: Int, cwd: URL) throws {
        // 1️⃣ Create master PTY
        var master: Int32 = -1
        master = posix_openpt(O_RDWR)
        guard master != -1 else { throw NSError(domain: "PTYWrapper", code: 1, userInfo: [NSLocalizedDescriptionKey: "posix_openpt failed"]) }

        // 2️⃣ Grant and unlock the slave side
        guard grantpt(master) == 0 else { throw NSError(domain: "PTYWrapper", code: 2, userInfo: [NSLocalizedDescriptionKey: "grantpt failed"]) }
        guard unlockpt(master) == 0 else { throw NSError(domain: "PTYWrapper", code: 3, userInfo: [NSLocalizedDescriptionKey: "unlockpt failed"]) }

        // 3️⃣ Obtain slave device name
        guard let slaveNameC = ptsname(master) else { throw NSError(domain: "PTYWrapper", code: 4, userInfo: [NSLocalizedDescriptionKey: "ptsname failed"]) }
        let slavePath = String(cString: slaveNameC)

        // 4️⃣ Open the slave side
        let slave = open(slavePath, O_RDWR)
        guard slave != -1 else { throw NSError(domain: "PTYWrapper", code: 5, userInfo: [NSLocalizedDescriptionKey: "open slave failed"]) }

        // 4.5️⃣ Set window size on slave before spawning
        var ws = winsize()
        ws.ws_row = UInt16(rows)
        ws.ws_col = UInt16(columns)
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0
        _ = ioctl(slave, TIOCSWINSZ, &ws)

        // 5️⃣ Use posix_spawn (fork is unavailable). Duplicate slave to stdio in child.
        var pid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)

        // Build argv for launching a login shell to run the command
        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(shellPath))
        cArgs.append(strdup("-l"))
        cArgs.append(strdup("-c"))
        cArgs.append(strdup(command))
        cArgs.append(nil)

        // Build environment including rows/cols and PWD
        var env = ProcessInfo.processInfo.environment
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["COLUMNS"] = "\(columns)"
        env["LINES"] = "\(rows)"
        env["SHELL"] = shellPath
        env["PWD"] = cwd.path
        if env["HOME"] == nil { env["HOME"] = FileManager.default.homeDirectoryForCurrentUser.path }
        let username = NSUserName()
        if env["USER"] == nil { env["USER"] = username }
        if env["LOGNAME"] == nil { env["LOGNAME"] = username }

        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in env { cEnv.append(strdup("\(k)=\(v)")) }
        cEnv.append(nil)

        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        let spawnResult = posix_spawn(&pid, shellPath, &fileActions, &attr, cArgs, cEnv)
        posix_spawnattr_destroy(&attr)

        for ptr in cArgs where ptr != nil { free(ptr) }
        for ptr in cEnv where ptr != nil { free(ptr) }

        guard spawnResult == 0 else { throw NSError(domain: "PTYWrapper", code: Int(spawnResult), userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed with code \(spawnResult)"]) }

        childPID = pid
        // Close slave in parent
        close(slave)
        masterFD = master

        // Make master non‑blocking
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

        // Do not start reading until startReading is called
    }
    deinit {
        stop()
    }
}