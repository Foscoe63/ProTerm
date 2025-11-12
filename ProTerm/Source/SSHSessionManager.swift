// SSHSessionManager.swift
import Foundation
import SwiftUI

/// Minimal wrapper that spawns an `ssh` process and pipes its I/O into a TerminalSession.
final class SSHSessionManager {
    static let shared = SSHSessionManager()

    func startSSH(to host: String, user: String? = nil, shellManager: ShellManager) -> TerminalSession {
        let session = TerminalSession(shellManager: shellManager)
        let process = Process()
        var arguments = ["ssh", host]
        if let u = user { arguments.insert(u, at: 1) }
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = arguments
        let pipeIn = Pipe()
        let pipeOut = Pipe()
        process.standardInput = pipeIn
        process.standardOutput = pipeOut
        process.standardError = pipeOut
        do {
            try process.run()
        } catch {
            session.output = "Failed to start SSH: \(error)"
            return session
        }
        // Read output asynchronously and append to the session's published string.
        pipeOut.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            if !data.isEmpty, let str = String(data: data, encoding: .utf8) {
                DispatchQueue.main.async { session.output.append(str) }
            }
        }
        // Store the process so it isn’t deallocated.
        session.process = process
        return session
    }
}

// The `process` property is defined inside the real TerminalSession type
// (see TerminalManager.swift). No extension needed here.
