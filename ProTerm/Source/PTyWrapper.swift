import Foundation
import Darwin

/// PTYWrapper encapsulates a pseudo‑terminal for interactive subprocesses.
final class PTYWrapper: @unchecked Sendable {
    // MARK: - Public API

    /// Closure called whenever the PTY produces output.
    var onOutput: ((String) -> Void)?

    /// Closure called when the child process exits.
    var onExit: (() -> Void)?

    /// Indicates whether the child process is still running.
    var isRunning: Bool {
        guard childPID > 0 else { return false }
        return kill(childPID, 0) == 0
    }

    private(set) var masterFD: Int32 = -1
    private(set) var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?
    private var utf8Remainder = Data()

    /// Initialise a PTY and spawn the given command.
    init(command: String, args: [String] = [], env: [String:String]? = nil) {
        var master: Int32 = -1
        master = posix_openpt(O_RDWR)
        guard master != -1 else { fatalError("posix_openpt failed") }

        guard grantpt(master) == 0 else { fatalError("grantpt failed") }
        guard unlockpt(master) == 0 else { fatalError("unlockpt failed") }

        guard let slaveNameC = ptsname(master) else { fatalError("ptsname failed") }
        let slavePath = String(cString: slaveNameC)

        let slave = open(slavePath, O_RDWR)
        guard slave != -1 else { fatalError("open slave failed") }
        
        var tio = termios()
        if tcgetattr(slave, &tio) == 0 {
            cfmakeraw(&tio)
            tio.c_iflag &= ~UInt(ICRNL | INLCR | IGNCR)
            tio.c_oflag &= ~UInt(ONLCR | OCRNL)
            _ = tcsetattr(slave, TCSANOW, &tio)
        }
        
        let defaults = UserDefaults.standard
        let configuredColumns = defaults.object(forKey: "ProTermTerminalColumns") as? Int ?? 80
        let columns = max(40, min(200, configuredColumns))
        
        var ws = winsize()
        ws.ws_row = 24
        ws.ws_col = UInt16(columns)
        ws.ws_xpixel = 0
        ws.ws_ypixel = 0
        _ = ioctl(slave, TIOCSWINSZ, &ws)

        var pid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)

        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(command))
        for a in args {
            cArgs.append(strdup(a))
        }
        cArgs.append(nil)

        let userHome = ProcessContext.homePath
        let opencodePath = "\(userHome)/.opencode/bin"
        var envVars = env ?? ProcessInfo.processInfo.environment
        envVars["TERM"] = envVars["TERM"] ?? "xterm-256color"
        
        if let existingPath = envVars["PATH"] {
            if !existingPath.contains(opencodePath) {
                envVars["PATH"] = "\(opencodePath):/opt/homebrew/bin:/opt/homebrew/sbin:\(existingPath)"
            }
        } else {
            envVars["PATH"] = "\(opencodePath):/opt/homebrew/bin:/opt/homebrew/sbin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        }
        
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in envVars {
            cEnv.append(strdup("\(k)=\(v)"))
        }
        cEnv.append(nil)

        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        
        let spawnResult = posix_spawn(&pid, command, &fileActions, &attr, cArgs, cEnv)
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&fileActions)
        
        if spawnResult == 0 {
            childPID = pid
            masterFD = master
            close(slave)
            let flags = fcntl(masterFD, F_GETFL)
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        }

        for ptr in cArgs where ptr != nil { free(ptr) }
        for ptr in cEnv where ptr != nil { free(ptr) }
        
        if spawnResult != 0 {
            fatalError("posix_spawn failed: \(spawnResult)")
        }
    }

    /// Shell-style init
    public init(shellPath: String, command: String? = nil, rows: Int, columns: Int, cwd: URL, env: [String: String]? = nil) throws {
        var master: Int32 = -1
        master = posix_openpt(O_RDWR)
        guard master != -1 else { throw NSError(domain: "PTYWrapper", code: 1) }
        grantpt(master)
        unlockpt(master)
        
        guard let slaveNameC = ptsname(master) else { throw NSError(domain: "PTYWrapper", code: 4) }
        let slavePath = String(cString: slaveNameC)
        let slave = open(slavePath, O_RDWR)
        
        var ws = winsize()
        ws.ws_row = UInt16(rows)
        ws.ws_col = UInt16(columns)
        _ = ioctl(slave, TIOCSWINSZ, &ws)
        
        var pid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        posix_spawn_file_actions_addclose(&fileActions, master)
        
        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(shellPath))
        if let cmd = command {
            cArgs.append(strdup("-l"))
            cArgs.append(strdup("-c"))
            cArgs.append(strdup(cmd))
        } else {
            cArgs.append(strdup("-l"))
        }
        cArgs.append(nil)
        
        let userHome = ProcessContext.homePath
        let opencodePath = "\(userHome)/.opencode/bin"
        var envVars = env ?? ProcessInfo.processInfo.environment
        envVars["TERM"] = envVars["TERM"] ?? "xterm-256color"
        let existingPath = envVars["PATH"] ?? ""
        if !existingPath.contains(opencodePath) {
            envVars["PATH"] = "\(opencodePath):/opt/homebrew/bin:/opt/homebrew/sbin:\(existingPath)"
        }
        envVars["PWD"] = cwd.path
        
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        for (k, v) in envVars {
            cEnv.append(strdup("\(k)=\(v)"))
        }
        cEnv.append(nil)
        
        var attr: posix_spawnattr_t? = nil
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))
        
        let spawnResult = posix_spawn(&pid, shellPath, &fileActions, &attr, cArgs, cEnv)
        posix_spawnattr_destroy(&attr)
        posix_spawn_file_actions_destroy(&fileActions)
        
        for ptr in cArgs where ptr != nil { free(ptr) }
        for ptr in cEnv where ptr != nil { free(ptr) }

        if spawnResult == 0 {
            childPID = pid
            masterFD = master
            close(slave)
            let flags = fcntl(masterFD, F_GETFL)
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        } else {
            throw NSError(domain: "PTYWrapper", code: Int(spawnResult))
        }
    }

    /// Read/Write
    func startReading(_ handler: @escaping (String) -> Void) {
        self.onOutput = handler
        guard masterFD != -1 else { return }
        let queue = DispatchQueue(label: "com.proterm.pty.read")
        readSource = DispatchSource.makeReadSource(fileDescriptor: masterFD, queue: queue)
        readSource?.setEventHandler { [weak self] in
            guard let self = self else { return }
            var buffer = [UInt8](repeating: 0, count: 8192)
            let bytes = read(self.masterFD, &buffer, buffer.count)
            if bytes > 0 {
                let chunkData = Data(buffer[0..<bytes])
                var combined = self.utf8Remainder
                combined.append(chunkData)
                if let str = String(data: combined, encoding: .utf8) {
                    self.onOutput?(str)
                    self.utf8Remainder = Data()
                } else {
                    self.utf8Remainder = combined
                }
            } else if bytes == 0 {
                self.onExit?()
                self.stop()
            }
        }
        readSource?.resume()
    }
    
    func write(_ string: String) {
        guard masterFD != -1, let data = string.data(using: .utf8) else { return }
        _ = data.withUnsafeBytes { ptr in
            Darwin.write(masterFD, ptr.baseAddress!, data.count)
        }
    }

    func setWindowSize(rows: Int, columns: Int) {
        guard masterFD != -1 else { return }
        var ws = winsize()
        ws.ws_row = UInt16(rows)
        ws.ws_col = UInt16(columns)
        _ = ioctl(masterFD, TIOCSWINSZ, &ws)
        if childPID > 0 { kill(childPID, SIGWINCH) }
    }

    func sendSignal(_ signal: Int32) {
        if childPID > 0 { kill(childPID, signal) }
    }

    func stop() {
        readSource?.cancel()
        readSource = nil
        if childPID > 0 {
            kill(childPID, SIGTERM)
            _ = waitpid(childPID, nil, 0)
            childPID = 0
        }
        if masterFD != -1 {
            close(masterFD)
            masterFD = -1
        }
    }

    deinit { stop() }
}

struct ProcessContext {
    static var homePath: String { NSHomeDirectory() }
}