import Foundation

/// PTYProcess is a thin wrapper around PTYWrapper that exposes a clearer API
/// for interactive processes. For now it delegates to PTYWrapper without
/// adding new behavior. This is a first step to untangle TerminalSession.
final class PTYProcess: @unchecked Sendable {
    private var handler: PTYWrapper?

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
    func start(command: String, args: [String], env: [String: String]? = nil, onOutput: @escaping (String) -> Void) {
        let h = PTYWrapper(command: command, args: args, env: env)
        handler = h
        h.startReading(onOutput)
    }

    /// Start a shell command inside a PTY using `posix_spawn` (login shell `-l -c`).
    func startShell(shellPath: String, command: String, rows: Int, cols: Int, cwd: URL, onOutput: @escaping (String) -> Void) throws {
        let h = try PTYWrapper(shellPath: shellPath, command: command, rows: rows, columns: cols, cwd: cwd)
        handler = h
        h.startReading(onOutput)
    }

    func write(_ string: String) {
        handler?.write(string)
    }

    func stop() {
        handler?.stop()
        handler = nil
    }
}
