import Foundation

/// ProcessRunner encapsulates running non-PTY commands via Foundation.Process
/// and streaming their output incrementally.
final class ProcessRunner {
    struct Run {
        fileprivate let process: Process
        fileprivate let readHandle: FileHandle
        fileprivate let pipe: Pipe

        /// Attempts to terminate the running process gracefully.
        func stop() {
            if process.isRunning { process.terminate() }
        }
    }

    /// Launch a command within the user's selected login shell using `-l -c`.
    /// - Parameters:
    ///   - shellPath: Full path to the shell executable (e.g., "/bin/zsh").
    ///   - command: The command string to pass after `-c`.
    ///   - cwd: Current working directory.
    ///   - columns: Terminal columns to expose via environment (min 80 enforced by caller).
    ///   - rows: Terminal rows to expose via environment (default 24 recommended).
    ///   - onOutput: Called on the main queue for each decoded UTF‑8 chunk.
    ///   - onBell: Called on the main queue if ASCII bell (\u{0007}) detected in any chunk.
    ///   - onComplete: Called on the main queue when the process has fully finished and all buffered data was drained.
    ///   - onError: Called on the main queue if the process failed to start.
    @discardableResult
    func run(
        shellPath: String,
        command: String,
        cwd: URL,
        columns: Int,
        rows: Int = 24,
        onOutput: @escaping @Sendable (String) -> Void,
        onBell: @escaping @Sendable () -> Void,
        onComplete: @escaping @Sendable () -> Void,
        onError: @escaping @Sendable (Error) -> Void
    ) -> Run? {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: shellPath)
        proc.arguments = ["-l", "-c", command]
        proc.currentDirectoryURL = cwd

        var env = ProcessInfo.processInfo.environment
        env["TERM"] = env["TERM"] ?? "xterm-256color"
        env["COLUMNS"] = "\(columns)"
        env["LINES"] = "\(rows)"
        env["CLICOLOR"] = "1"
        env["CLICOLOR_FORCE"] = "1"
        env["LSCOLORS"] = env["LSCOLORS"] ?? "Gxfxcxdxbxegedabagacad"
        env["GIT_PAGER"] = "cat"
        env["GIT_CONFIG_PARAMETERS"] = "'color.ui=always'"
        proc.environment = env

        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        let handle = pipe.fileHandleForReading

        // Stream output incrementally
        handle.readabilityHandler = { fh in
            // Drain availableData until empty
            var accumulated = Data()
            var bell = false
            while true {
                let data = fh.availableData
                if data.isEmpty { break }
                accumulated.append(data)
                if !bell, data.firstIndex(of: 7) != nil { bell = true }
            }
            guard !accumulated.isEmpty else { return }
            if bell {
                DispatchQueue.main.async { onBell() }
            }
            if let chunk = String(data: accumulated, encoding: .utf8), !chunk.isEmpty {
                DispatchQueue.main.async { onOutput(chunk) }
            }
        }

        proc.terminationHandler = { _ in
            // Give the readabilityHandler a moment to finish draining
            Task.detached(priority: .userInitiated) {
                try? await Task.sleep(for: .milliseconds(200))

                // Final drain
                let final = handle.readDataToEndOfFile()
                if !final.isEmpty, let s = String(data: final, encoding: .utf8), !s.isEmpty {
                    await MainActor.run { onOutput(s) }
                }
                await MainActor.run {
                    handle.readabilityHandler = nil
                    onComplete()
                }
            }
        }

        do {
            try proc.run()
        } catch {
            handle.readabilityHandler = nil
            DispatchQueue.main.async { onError(error) }
            return nil
        }

        return Run(process: proc, readHandle: handle, pipe: pipe)
    }
}
