import SwiftUI
import Foundation
import Combine

/// Advanced features including split panes, command aliases, and auto-completion
@MainActor
class AdvancedFeatures: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isEnabled: Bool = true
    
    // MARK: - Split Panes
    @Published var splitPanes: [SplitPane] = []
    @Published var activePane: UUID?
    @Published var splitDirection: SplitDirection = .horizontal
    
    enum SplitDirection {
        case horizontal, vertical
    }
    
    struct SplitPane: Identifiable {
        let id = UUID()
        var session: TerminalSession
        var isActive: Bool = false
        var frame: CGRect = .zero
    }
    
    // MARK: - Command Aliases
    @Published var aliases: [String: String] = [:]
    private let aliasesKey = "ProTermCommandAliases"
    
    // MARK: - Auto-completion
    @Published var completions: [String] = []
    @Published var currentCompletionIndex: Int = 0
    @Published var isCompleting: Bool = false
    
    // MARK: - Command Suggestions
    @Published var suggestions: [CommandSuggestion] = []
    @Published var showSuggestions: Bool = false
    
    struct CommandSuggestion: Identifiable {
        let id = UUID()
        let command: String
        let description: String
        let category: SuggestionCategory
        let usage: String?
    }
    
    enum SuggestionCategory {
        case fileSystem
        case git
        case docker
        case npm
        case system
        case custom
    }
    
    // MARK: - Session Sync
    @Published var syncSessions: Bool = false
    @Published var syncedCommands: [String] = []
    
    // MARK: - Initialization
    override init() {
        super.init()
        loadAliases()
        setupDefaultAliases()
        setupCommandSuggestions()
    }
    
    // MARK: - Split Pane Management
    
    func createSplitPane(from session: TerminalSession) -> SplitPane {
        let newPane = SplitPane(session: session, isActive: true)
        splitPanes.append(newPane)
        activePane = newPane.id
        return newPane
    }
    
    func removeSplitPane(_ paneId: UUID) {
        splitPanes.removeAll { $0.id == paneId }
        if activePane == paneId {
            activePane = splitPanes.first?.id
        }
    }
    
    func switchToPane(_ paneId: UUID) {
        activePane = paneId
        for i in splitPanes.indices {
            splitPanes[i].isActive = (splitPanes[i].id == paneId)
        }
    }
    
    func toggleSplitDirection() {
        splitDirection = splitDirection == .horizontal ? .vertical : .horizontal
    }
    
    // MARK: - Command Aliases
    
    func addAlias(name: String, command: String) {
        aliases[name] = command
        saveAliases()
    }
    
    func removeAlias(name: String) {
        aliases.removeValue(forKey: name)
        saveAliases()
    }
    
    func expandAlias(_ input: String) -> String {
        let components = input.components(separatedBy: .whitespaces)
        guard let firstWord = components.first else { return input }
        
        if let alias = aliases[firstWord] {
            let remainingInput = components.dropFirst().joined(separator: " ")
            return "\(alias) \(remainingInput)".trimmingCharacters(in: .whitespaces)
        }
        
        return input
    }
    
    private func setupDefaultAliases() {
        if aliases.isEmpty {
            aliases = [
                "ll": "ls -la",
                "la": "ls -la",
                "l": "ls -la",
                "..": "cd ..",
                "...": "cd ../..",
                "g": "git",
                "gs": "git status",
                "ga": "git add",
                "gc": "git commit",
                "gp": "git push",
                "gl": "git pull",
                "d": "docker",
                "dc": "docker-compose",
                "n": "npm",
                "ni": "npm install",
                "nr": "npm run",
                "ns": "npm start",
                "nb": "npm run build",
                "nt": "npm test",
                "y": "yarn",
                "yi": "yarn install",
                "yr": "yarn run",
                "ys": "yarn start",
                "yb": "yarn build",
                "yt": "yarn test"
            ]
            saveAliases()
        }
    }
    
    private func loadAliases() {
        if let data = UserDefaults.standard.data(forKey: aliasesKey),
           let loadedAliases = try? JSONDecoder().decode([String: String].self, from: data) {
            aliases = loadedAliases
        }
    }
    
    private func saveAliases() {
        if let data = try? JSONEncoder().encode(aliases) {
            UserDefaults.standard.set(data, forKey: aliasesKey)
        }
    }
    
    // MARK: - Auto-completion
    
    func getCompletions(for input: String, in session: TerminalSession) -> [String] {
        let trimmedInput = input.trimmingCharacters(in: .whitespaces)
        guard !trimmedInput.isEmpty else { return [] }
        
        var completions: [String] = []
        
        // Command completions
        let commands = ["ls", "cd", "pwd", "mkdir", "rmdir", "rm", "cp", "mv", "cat", "grep", "find", "chmod", "chown", "sudo", "npm", "git", "docker", "kubectl", "aws", "terraform", "make", "cmake", "gcc", "clang", "python", "node", "java", "go", "rust", "cargo", "yarn", "brew", "apt", "yum", "dnf", "pacman", "zypper", "port", "fink", "macports"]
        
        for command in commands {
            if command.hasPrefix(trimmedInput) {
                completions.append(command)
            }
        }
        
        // File and directory completions
        let fileManager = FileManager.default
        let currentPath = session.cwd.path
        
        do {
            let contents = try fileManager.contentsOfDirectory(atPath: currentPath)
            for item in contents {
                if item.hasPrefix(trimmedInput) {
                    let fullPath = "\(currentPath)/\(item)"
                    var isDirectory: ObjCBool = false
                    if fileManager.fileExists(atPath: fullPath, isDirectory: &isDirectory) {
                        if isDirectory.boolValue {
                            completions.append("\(item)/")
                        } else {
                            completions.append(item)
                        }
                    }
                }
            }
        } catch {
            // Handle error silently
        }
        
        // Alias completions
        for (alias, _) in aliases {
            if alias.hasPrefix(trimmedInput) {
                completions.append(alias)
            }
        }
        
        return completions.sorted()
    }
    
    func nextCompletion() -> String? {
        guard !completions.isEmpty else { return nil }
        currentCompletionIndex = (currentCompletionIndex + 1) % completions.count
        return completions[currentCompletionIndex]
    }
    
    func previousCompletion() -> String? {
        guard !completions.isEmpty else { return nil }
        currentCompletionIndex = currentCompletionIndex > 0 ? currentCompletionIndex - 1 : completions.count - 1
        return completions[currentCompletionIndex]
    }
    
    // MARK: - Command Suggestions
    
    private func setupCommandSuggestions() {
        suggestions = [
            CommandSuggestion(command: "ls", description: "List directory contents", category: .fileSystem, usage: "ls [options] [path]"),
            CommandSuggestion(command: "cd", description: "Change directory", category: .fileSystem, usage: "cd [directory]"),
            CommandSuggestion(command: "pwd", description: "Print working directory", category: .fileSystem, usage: "pwd"),
            CommandSuggestion(command: "mkdir", description: "Create directory", category: .fileSystem, usage: "mkdir [options] directory"),
            CommandSuggestion(command: "rm", description: "Remove files", category: .fileSystem, usage: "rm [options] file"),
            CommandSuggestion(command: "cp", description: "Copy files", category: .fileSystem, usage: "cp [options] source destination"),
            CommandSuggestion(command: "mv", description: "Move/rename files", category: .fileSystem, usage: "mv [options] source destination"),
            CommandSuggestion(command: "cat", description: "Display file contents", category: .fileSystem, usage: "cat [options] file"),
            CommandSuggestion(command: "grep", description: "Search text in files", category: .fileSystem, usage: "grep [options] pattern file"),
            CommandSuggestion(command: "find", description: "Find files", category: .fileSystem, usage: "find [path] [options]"),
            CommandSuggestion(command: "git", description: "Git version control", category: .git, usage: "git [command] [options]"),
            CommandSuggestion(command: "git status", description: "Show git status", category: .git, usage: "git status"),
            CommandSuggestion(command: "git add", description: "Add files to staging", category: .git, usage: "git add [files]"),
            CommandSuggestion(command: "git commit", description: "Commit changes", category: .git, usage: "git commit -m \"message\""),
            CommandSuggestion(command: "git push", description: "Push to remote", category: .git, usage: "git push [remote] [branch]"),
            CommandSuggestion(command: "git pull", description: "Pull from remote", category: .git, usage: "git pull [remote] [branch]"),
            CommandSuggestion(command: "docker", description: "Docker container platform", category: .docker, usage: "docker [command] [options]"),
            CommandSuggestion(command: "docker ps", description: "List containers", category: .docker, usage: "docker ps [options]"),
            CommandSuggestion(command: "docker images", description: "List images", category: .docker, usage: "docker images [options]"),
            CommandSuggestion(command: "docker run", description: "Run container", category: .docker, usage: "docker run [options] image"),
            CommandSuggestion(command: "npm", description: "Node package manager", category: .npm, usage: "npm [command] [options]"),
            CommandSuggestion(command: "npm install", description: "Install packages", category: .npm, usage: "npm install [package]"),
            CommandSuggestion(command: "npm run", description: "Run script", category: .npm, usage: "npm run [script]"),
            CommandSuggestion(command: "npm start", description: "Start application", category: .npm, usage: "npm start"),
            CommandSuggestion(command: "npm test", description: "Run tests", category: .npm, usage: "npm test"),
            CommandSuggestion(command: "sudo", description: "Execute as superuser", category: .system, usage: "sudo [command]"),
            CommandSuggestion(command: "chmod", description: "Change file permissions", category: .system, usage: "chmod [permissions] file"),
            CommandSuggestion(command: "chown", description: "Change file ownership", category: .system, usage: "chown [owner] file")
        ]
    }
    
    func getSuggestions(for input: String) -> [CommandSuggestion] {
        let trimmedInput = input.trimmingCharacters(in: .whitespaces).lowercased()
        guard !trimmedInput.isEmpty else { return [] }
        
        return suggestions.filter { suggestion in
            suggestion.command.lowercased().contains(trimmedInput) ||
            suggestion.description.lowercased().contains(trimmedInput)
        }
    }
    
    // MARK: - Session Sync
    
    func syncCommand(_ command: String) {
        guard syncSessions else { return }
        syncedCommands.append(command)
        
        // Keep only last 100 commands
        if syncedCommands.count > 100 {
            syncedCommands.removeFirst()
        }
    }
    
    func getSyncedCommands() -> [String] {
        return syncedCommands
    }
}
