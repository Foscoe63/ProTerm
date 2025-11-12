import Foundation
import SwiftUI
import Combine

/// Centralized error handling and logging
@MainActor
class ErrorHandler: ObservableObject {
    static let shared = ErrorHandler()
    
    @Published var recentErrors: [TerminalError] = []
    private let maxStoredErrors = 100
    private let errorLogPath: URL
    
    private init() {
        let cacheDir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
        errorLogPath = cacheDir.appendingPathComponent("ProTermErrors.log")
        loadRecentErrors()
    }
    
    struct TerminalError: Identifiable, Codable {
        let id: UUID
        let timestamp: Date
        let command: String?
        let message: String
        let errorType: ErrorType
        let sessionId: UUID?
        
        enum ErrorType: String, Codable {
            case commandExecution = "Command Execution"
            case fileSystem = "File System"
            case network = "Network"
            case permission = "Permission"
            case other = "Other"
        }
    }
    
    func logError(_ error: Error, command: String? = nil, sessionId: UUID? = nil) {
        let terminalError = TerminalError(
            id: UUID(),
            timestamp: Date(),
            command: command,
            message: error.localizedDescription,
            errorType: .other,
            sessionId: sessionId
        )
        recordError(terminalError)
    }
    
    func logError(message: String, type: TerminalError.ErrorType = .other, command: String? = nil, sessionId: UUID? = nil) {
        let terminalError = TerminalError(
            id: UUID(),
            timestamp: Date(),
            command: command,
            message: message,
            errorType: type,
            sessionId: sessionId
        )
        recordError(terminalError)
    }
    
    private func recordError(_ error: TerminalError) {
        recentErrors.append(error)
        if recentErrors.count > maxStoredErrors {
            recentErrors.removeFirst()
        }
        
        // Write to log file
        let logEntry = "[\(error.timestamp)] [\(error.errorType.rawValue)] \(error.message)\n"
        if let data = logEntry.data(using: .utf8) {
            if let fileHandle = try? FileHandle(forWritingTo: errorLogPath) {
                fileHandle.seekToEndOfFile()
                fileHandle.write(data)
                try? fileHandle.close()
            } else {
                try? data.write(to: errorLogPath, options: .atomic)
            }
        }
    }
    
    private func loadRecentErrors() {
        // Load from log file if needed
        // For now, just initialize empty
    }
    
    func clearErrors() {
        recentErrors.removeAll()
    }
    
    func getErrors(for sessionId: UUID) -> [TerminalError] {
        return recentErrors.filter { $0.sessionId == sessionId }
    }
}

