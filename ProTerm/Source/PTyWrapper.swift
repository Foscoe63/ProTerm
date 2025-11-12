import Foundation
import Darwin

/// PTYWrapper encapsulates a pseudo‑terminal for interactive subprocesses.
final class PTYWrapper {
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
        guard master != -1 else { fatalError("posix_openpt failed") }

        // 2️⃣ Grant and unlock the slave side
        guard grantpt(master) == 0 else { fatalError("grantpt failed") }
        guard unlockpt(master) == 0 else { fatalError("unlockpt failed") }

        // 3️⃣ Obtain slave device name
        guard let slaveNameC = ptsname(master) else { fatalError("ptsname failed") }
        let slavePath = String(cString: slaveNameC)

        // 4️⃣ Open the slave side
        let slave = open(slavePath, O_RDWR)
        guard slave != -1 else { fatalError("open slave failed") }

        // 5️⃣ Spawn the process using posix_spawn
        var pid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        // Duplicate slave to stdio
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        // Close master in child
        posix_spawn_file_actions_addclose(&fileActions, master)

        // Build C‑style argv array
        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(command))
        for a in args {
            cArgs.append(strdup(a))
        }
        cArgs.append(nil)

        // Build environment if supplied
        var cEnv: [UnsafeMutablePointer<CChar>?] = []
        if let envDict = env {
            for (k, v) in envDict {
                let pair = "\(k)=\(v)"
                cEnv.append(strdup(pair))
            }
        }
        cEnv.append(nil)

        // Spawn
        let spawnResult = posix_spawn(&pid, command, &fileActions, nil, cArgs, env != nil ? cEnv : nil)
        if spawnResult != 0 {
            fatalError("posix_spawn failed: \\(spawnResult)")
        }
        childPID = pid
        // Close descriptors not needed in parent
        close(slave)
            // ---------- Parent process ----------
            masterFD = master

            // Make master non‑blocking
            let flags = fcntl(masterFD, F_GETFL)
            _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)

            // Start asynchronous reading
            beginReading()
            // Free duplicated C strings allocated with strdup
            for ptr in cArgs where ptr != nil {
                free(ptr)
            }
            if env != nil {
                for ptr in cEnv where ptr != nil {
                    free(ptr)
                }
            }
    
    }

    // MARK: - Private state
    internal var masterFD: Int32 = -1
    internal var childPID: pid_t = 0
    private var readSource: DispatchSourceRead?

    // MARK: - Reading
    private func beginReading() {
        guard masterFD != -1 else { return }
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
                }
            } else if bytes == 0 {
                // EOF – child exited
                self.stop()
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
        guard masterFD != -1 else { return }
        if let data = string.data(using: .utf8) {
            _ = data.withUnsafeBytes { ptr in
                Darwin.write(masterFD, ptr.baseAddress!, data.count)
            }
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
        
        // 5️⃣ Spawn the process using posix_spawn
        var pid: pid_t = 0
        var fileActions: posix_spawn_file_actions_t? = nil
        posix_spawn_file_actions_init(&fileActions)
        // Duplicate slave to stdio
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDIN_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDOUT_FILENO)
        posix_spawn_file_actions_adddup2(&fileActions, slave, STDERR_FILENO)
        // Close master in child
        posix_spawn_file_actions_addclose(&fileActions, master)
        
        // Build C‑style argv array for the shell
        var cArgs: [UnsafeMutablePointer<CChar>?] = []
        cArgs.append(strdup(shellPath))
        cArgs.append(strdup("-l"))
        cArgs.append(strdup("-c"))
        cArgs.append(strdup(command))
        cArgs.append(nil)
        
        // Spawn
        let spawnResult = posix_spawn(&pid, shellPath, &fileActions, nil, cArgs, nil)
        if spawnResult != 0 {
            throw NSError(domain: "PTYWrapper", code: Int(spawnResult), userInfo: [NSLocalizedDescriptionKey: "posix_spawn failed"])
        }
        
        // Clean up C strings
        for ptr in cArgs where ptr != nil {
            free(ptr)
        }
        
        childPID = pid
        // Close descriptors not needed in parent
        close(slave)
        masterFD = master
        
        // Make master non‑blocking
        let flags = fcntl(masterFD, F_GETFL)
        _ = fcntl(masterFD, F_SETFL, flags | O_NONBLOCK)
        
        // Start asynchronous reading
        beginReading()
    }
    deinit {
        stop()
    }
}