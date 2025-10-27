// CrashReporter.swift
import Foundation

final class CrashReporter {
    static let shared = CrashReporter()
    private init() {
        // Register a handler for uncaught exceptions.
        NSSetUncaughtExceptionHandler { exception in
            let log = "Crash: \(exception.name) – \(exception.reason ?? "unknown")\nStack Trace:\n\(exception.callStackSymbols.joined(separator: "\n"))"
            let dir = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask).first!
            let file = dir.appendingPathComponent("ProTermCrash.log")
            try? log.write(to: file, atomically: true, encoding: .utf8)
        }
    }
}
