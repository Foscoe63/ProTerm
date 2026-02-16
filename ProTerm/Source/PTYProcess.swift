import Foundation

/// PTYProcess is a thin wrapper around PTYWrapper that exposes a clearer API
/// for interactive processes.
final class PTYProcess: @unchecked Sendable {
    private var handler: PTYWrapper?
    
    /// Closure called when the child process produces output.
    var onOutput: ((String) -> Void)? {
        didSet {
            handler?.onOutput = onOutput
        }
    }
    
    /// Closure called when the child process exits.
    var onExit: (() -> Void)? {
        didSet {
            handler?.onExit = onExit
        }
    }

    var isRunning: Bool {
        handler?.isRunning ?? false
    }

    var childPID: pid_t {
        handler?.childPID ?? 0
    }

    var masterFD: Int32 {
        handler?.masterFD ?? -1
    }

    /// Start an interactive process using an executable and arguments.
    func start(command: String, args: [String], env: [String: String]? = nil, onOutput: ((String) -> Void)? = nil) {
        let h = PTYWrapper(command: command, args: args, env: env)
        handler = h
        h.onExit = onExit
        if let out = onOutput {
            h.startReading(out)
        } else if let out = self.onOutput {
            h.startReading(out)
        }
    }

    /// Start a shell command inside a PTY using `posix_spawn` (login shell `-l -c`).
    func startShellCommand(shellPath: String, command: String, rows: Int, cols: Int, cwd: URL, onOutput: ((String) -> Void)? = nil) throws {
        let h = try PTYWrapper(shellPath: shellPath, command: command, rows: rows, columns: cols, cwd: cwd)
        handler = h
        h.onExit = onExit
        if let out = onOutput {
            h.startReading(out)
        } else if let out = self.onOutput {
            h.startReading(out)
        }
    }
    
    /// Start a persistent interactive shell inside a PTY.
    func startPersistentShell(shellPath: String, rows: Int, cols: Int, cwd: URL, env: [String: String]? = nil, onOutput: ((String) -> Void)? = nil) throws {
        let h = try PTYWrapper(shellPath: shellPath, rows: rows, columns: cols, cwd: cwd, env: env)
        handler = h
        h.onExit = onExit
        if let out = onOutput {
            h.startReading(out)
        } else if let out = self.onOutput {
            h.startReading(out)
        }
    }

    func write(_ string: String) {
        handler?.write(string)
    }
    
    func setWindowSize(rows: Int, cols: Int) {
        handler?.setWindowSize(rows: rows, columns: cols)
    }
    
    func sendSignal(_ signal: Int32) {
        handler?.sendSignal(signal)
    }

    func stop() {
        handler?.stop()
        handler = nil
    }
}
