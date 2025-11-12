// StatusBarView.swift (updated)
import SwiftUI
import Combine
import AppKit

struct StatusBarView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var shellManager: ShellManager
    @Binding var selectedTab: Int
    
    @State private var currentDirectory = "~"
    @State private var gitBranch: String? = nil
    @State private var isProcessRunning = false
    @State private var executionTime: TimeInterval? = nil
    
    var currentSession: TerminalSession? {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return nil }
        return terminalManager.sessions[selectedTab]
    }

    var body: some View {
        HStack(spacing: 16) {
            // Shell type
            HStack(spacing: 4) {
                Image(systemName: "terminal")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text(shellManager.selectedShell.displayName)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            
            Divider()
                .frame(height: 14)
            
            // Directory (clickable)
            Button(action: openDirectoryInFinder) {
                HStack(spacing: 4) {
                    Image(systemName: "folder")
                        .font(.caption2)
                    Text(currentDirectory)
                        .font(.caption)
                }
                .foregroundColor(.blue)
            }
            .buttonStyle(.plain)
            .help("Click to open in Finder")
            
            // Git branch (if available)
            if let branch = gitBranch {
                Divider()
                    .frame(height: 14)
                
                HStack(spacing: 4) {
                    Image(systemName: "git.branch")
                        .font(.caption2)
                        .foregroundColor(.green)
                    Text(branch)
                        .font(.caption)
                        .foregroundColor(.green)
                }
            }
            
            // Process indicator
            if isProcessRunning {
                Divider()
                    .frame(height: 14)
                
                HStack(spacing: 4) {
                    ProgressView()
                        .scaleEffect(0.6)
                        .frame(width: 12, height: 12)
                    Text("Running")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            } else if let execTime = executionTime, execTime > 0 {
                Divider()
                    .frame(height: 14)
                
                HStack(spacing: 4) {
                    Image(systemName: "clock")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                    Text(formatExecutionTime(execTime))
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            
            Spacer()
            
            // Session count
            HStack(spacing: 4) {
                Image(systemName: "square.stack.3d.up")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                Text("\(terminalManager.sessions.count)")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 4)
        .onReceive(NotificationCenter.default.publisher(for: .directoryChanged)) { notification in
            if let newDirectory = notification.object as? String {
                currentDirectory = newDirectory
                updateGitBranch()
            }
        }
        .onChange(of: selectedTab) { _, _ in
            updateStatus()
        }
        .onChange(of: currentSession?.cwd) { _, _ in
            updateStatus()
        }
        .onChange(of: currentSession?.isProcessRunning) { _, newValue in
            isProcessRunning = newValue ?? false
            if !(newValue ?? false) {
                // Process finished, update execution time
                executionTime = currentSession?.lastCommandExecutionTime
            }
        }
        .onChange(of: currentSession?.lastCommandExecutionTime) { _, newValue in
            executionTime = newValue
        }
        .onAppear {
            updateStatus()
        }
    }
    
    private func updateStatus() {
        guard let session = currentSession else {
            currentDirectory = "~"
            gitBranch = nil
            isProcessRunning = false
            return
        }
        
        let homePath = FileManager.default.homeDirectoryForCurrentUser.path
        var displayPath = session.cwd.path.replacingOccurrences(of: homePath, with: "~")
        if displayPath.isEmpty { displayPath = "~" }
        currentDirectory = displayPath
        
        isProcessRunning = session.isProcessRunning
        updateGitBranch()
    }
    
    private func updateGitBranch() {
        guard let session = currentSession else {
            gitBranch = nil
            return
        }
        
        if GitIntegration.isGitRepository(session.cwd),
           let branch = GitIntegration.getCurrentBranch(in: session.cwd) {
            gitBranch = branch
        } else {
            gitBranch = nil
        }
    }
    
    private func openDirectoryInFinder() {
        guard let session = currentSession else { return }
        NSWorkspace.shared.open(session.cwd)
    }
    
    private func formatExecutionTime(_ time: TimeInterval) -> String {
        if time < 1.0 {
            return String(format: "%.0fms", time * 1000)
        } else if time < 60.0 {
            return String(format: "%.2fs", time)
        } else {
            let minutes = Int(time / 60)
            let seconds = Int(time.truncatingRemainder(dividingBy: 60))
            return "\(minutes)m \(seconds)s"
        }
    }
}
