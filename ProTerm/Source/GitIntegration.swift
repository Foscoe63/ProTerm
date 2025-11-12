import Foundation

/// Git integration utilities
struct GitIntegration {
    /// Get git branch name for current directory
    static func getCurrentBranch(in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["rev-parse", "--abbrev-ref", "HEAD"]
        process.currentDirectoryURL = directory
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe() // Suppress errors
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let branch = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines),
                   !branch.isEmpty {
                    return branch
                }
            }
        } catch {
            // Git not available or not a git repo
        }
        
        return nil
    }
    
    /// Check if directory is a git repository
    static func isGitRepository(_ directory: URL) -> Bool {
        let gitDir = directory.appendingPathComponent(".git")
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: gitDir.path, isDirectory: &isDir) && isDir.boolValue
    }
    
    /// Get git status (clean, modified, etc.)
    static func getGitStatus(in directory: URL) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["status", "--porcelain"]
        process.currentDirectoryURL = directory
        
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        
        do {
            try process.run()
            process.waitUntilExit()
            
            if process.terminationStatus == 0 {
                let data = pipe.fileHandleForReading.readDataToEndOfFile()
                if let status = String(data: data, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines) {
                    return status.isEmpty ? "clean" : "modified"
                }
            }
        } catch {
            // Git not available
        }
        
        return nil
    }
}

