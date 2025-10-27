import SwiftUI
import Foundation
import Combine

/// Productivity tools including bookmarks, quick commands, and session templates
@MainActor
class ProductivityTools: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isEnabled: Bool = true
    
    // MARK: - Initialization
    override init() {
        super.init()
        loadBookmarks()
        loadQuickCommands()
        loadSessionTemplates()
        loadOutputFilters()
        setupDefaultData()
    }
    
    // MARK: - Bookmarks
    @Published var bookmarks: [Bookmark] = []
    private let bookmarksKey = "ProTermBookmarks"
    
    struct Bookmark: Identifiable, Codable {
        let id: UUID
        var name: String
        var path: String
        var description: String?
        var category: BookmarkCategory
        var created: Date
        var lastUsed: Date?
        
        enum BookmarkCategory: String, CaseIterable, Codable {
            case project = "Project"
            case development = "Development"
            case system = "System"
            case personal = "Personal"
            case work = "Work"
            case custom = "Custom"
        }
    }
    
    // MARK: - Quick Commands
    @Published var quickCommands: [QuickCommand] = []
    private let quickCommandsKey = "ProTermQuickCommands"
    
    struct QuickCommand: Identifiable, Codable {
        let id: UUID
        var name: String
        var command: String
        var description: String?
        var category: QuickCommandCategory
        var icon: String
        var created: Date
        var lastUsed: Date?
        var usageCount: Int
        
        enum QuickCommandCategory: String, CaseIterable, Codable {
            case fileSystem = "File System"
            case git = "Git"
            case docker = "Docker"
            case npm = "NPM"
            case system = "System"
            case custom = "Custom"
        }
    }
    
    // MARK: - Session Templates
    @Published var sessionTemplates: [SessionTemplate] = []
    private let sessionTemplatesKey = "ProTermSessionTemplates"
    
    struct SessionTemplate: Identifiable, Codable {
        let id: UUID
        var name: String
        var description: String?
        var initialCommands: [String]
        var workingDirectory: String?
        var environment: [String: String]
        var shell: String
        var created: Date
        var lastUsed: Date?
        var usageCount: Int
        
        enum TemplateCategory: String, CaseIterable, Codable {
            case development = "Development"
            case deployment = "Deployment"
            case maintenance = "Maintenance"
            case testing = "Testing"
            case custom = "Custom"
        }
    }
    
    // MARK: - Output Filtering
    @Published var outputFilters: [OutputFilter] = []
    @Published var activeFilters: Set<UUID> = []
    private let outputFiltersKey = "ProTermOutputFilters"
    
    struct OutputFilter: Identifiable, Codable {
        let id: UUID
        var name: String
        var pattern: String
        var isRegex: Bool
        var action: FilterAction
        var color: String // Hex color
        var isEnabled: Bool
        
        enum FilterAction: String, CaseIterable, Codable {
            case highlight = "Highlight"
            case hide = "Hide"
            case replace = "Replace"
            case extract = "Extract"
        }
    }
    
    enum FilterAction {
        case highlight
        case hide
        case replace
        case extract
    }
    
    // MARK: - Export Options
    @Published var exportFormats: [ExportFormat] = [
        .text, .html, .pdf, .json, .csv
    ]
    
    enum ExportFormat: String, CaseIterable {
        case text = "Text"
        case html = "HTML"
        case pdf = "PDF"
        case json = "JSON"
        case csv = "CSV"
        
        var fileExtension: String {
            switch self {
            case .text: return "txt"
            case .html: return "html"
            case .pdf: return "pdf"
            case .json: return "json"
            case .csv: return "csv"
            }
        }
    }
    
    
    // MARK: - Bookmarks Management
    
    func addBookmark(name: String, path: String, description: String? = nil, category: Bookmark.BookmarkCategory = .custom) {
        let bookmark = Bookmark(
            id: UUID(),
            name: name,
            path: path,
            description: description,
            category: category,
            created: Date()
        )
        bookmarks.append(bookmark)
        saveBookmarks()
    }
    
    func removeBookmark(_ bookmark: Bookmark) {
        bookmarks.removeAll { $0.id == bookmark.id }
        saveBookmarks()
    }
    
    func updateBookmark(_ bookmark: Bookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index] = bookmark
            saveBookmarks()
        }
    }
    
    func useBookmark(_ bookmark: Bookmark) {
        if let index = bookmarks.firstIndex(where: { $0.id == bookmark.id }) {
            bookmarks[index].lastUsed = Date()
            saveBookmarks()
        }
    }
    
    private func loadBookmarks() {
        if let data = UserDefaults.standard.data(forKey: bookmarksKey),
           let loadedBookmarks = try? JSONDecoder().decode([Bookmark].self, from: data) {
            bookmarks = loadedBookmarks
        }
    }
    
    private func saveBookmarks() {
        if let data = try? JSONEncoder().encode(bookmarks) {
            UserDefaults.standard.set(data, forKey: bookmarksKey)
        }
    }
    
    // MARK: - Quick Commands Management
    
    func addQuickCommand(name: String, command: String, description: String? = nil, category: QuickCommand.QuickCommandCategory = .custom, icon: String = "command") {
        let quickCommand = QuickCommand(
            id: UUID(),
            name: name,
            command: command,
            description: description,
            category: category,
            icon: icon,
            created: Date(),
            usageCount: 0
        )
        quickCommands.append(quickCommand)
        saveQuickCommands()
    }
    
    func removeQuickCommand(_ quickCommand: QuickCommand) {
        quickCommands.removeAll { $0.id == quickCommand.id }
        saveQuickCommands()
    }
    
    func updateQuickCommand(_ quickCommand: QuickCommand) {
        if let index = quickCommands.firstIndex(where: { $0.id == quickCommand.id }) {
            quickCommands[index] = quickCommand
            saveQuickCommands()
        }
    }
    
    func useQuickCommand(_ quickCommand: QuickCommand) {
        if let index = quickCommands.firstIndex(where: { $0.id == quickCommand.id }) {
            quickCommands[index].lastUsed = Date()
            quickCommands[index].usageCount += 1
            saveQuickCommands()
        }
    }
    
    private func loadQuickCommands() {
        if let data = UserDefaults.standard.data(forKey: quickCommandsKey),
           let loadedCommands = try? JSONDecoder().decode([QuickCommand].self, from: data) {
            quickCommands = loadedCommands
        }
    }
    
    private func saveQuickCommands() {
        if let data = try? JSONEncoder().encode(quickCommands) {
            UserDefaults.standard.set(data, forKey: quickCommandsKey)
        }
    }
    
    // MARK: - Session Templates Management
    
    func addSessionTemplate(name: String, description: String? = nil, initialCommands: [String] = [], workingDirectory: String? = nil, environment: [String: String] = [:], shell: String = "/bin/zsh") {
        let template = SessionTemplate(
            id: UUID(),
            name: name,
            description: description,
            initialCommands: initialCommands,
            workingDirectory: workingDirectory,
            environment: environment,
            shell: shell,
            created: Date(),
            usageCount: 0
        )
        sessionTemplates.append(template)
        saveSessionTemplates()
    }
    
    func removeSessionTemplate(_ template: SessionTemplate) {
        sessionTemplates.removeAll { $0.id == template.id }
        saveSessionTemplates()
    }
    
    func updateSessionTemplate(_ template: SessionTemplate) {
        if let index = sessionTemplates.firstIndex(where: { $0.id == template.id }) {
            sessionTemplates[index] = template
            saveSessionTemplates()
        }
    }
    
    func useSessionTemplate(_ template: SessionTemplate) {
        if let index = sessionTemplates.firstIndex(where: { $0.id == template.id }) {
            sessionTemplates[index].lastUsed = Date()
            sessionTemplates[index].usageCount += 1
            saveSessionTemplates()
        }
    }
    
    private func loadSessionTemplates() {
        if let data = UserDefaults.standard.data(forKey: sessionTemplatesKey),
           let loadedTemplates = try? JSONDecoder().decode([SessionTemplate].self, from: data) {
            sessionTemplates = loadedTemplates
        }
    }
    
    private func saveSessionTemplates() {
        if let data = try? JSONEncoder().encode(sessionTemplates) {
            UserDefaults.standard.set(data, forKey: sessionTemplatesKey)
        }
    }
    
    // MARK: - Output Filters Management
    
    func addOutputFilter(name: String, pattern: String, isRegex: Bool = false, action: OutputFilter.FilterAction = .highlight, color: String = "#FFD700", isEnabled: Bool = true) {
        let filter = OutputFilter(
            id: UUID(),
            name: name,
            pattern: pattern,
            isRegex: isRegex,
            action: action,
            color: color,
            isEnabled: isEnabled
        )
        outputFilters.append(filter)
        saveOutputFilters()
    }
    
    func removeOutputFilter(_ filter: OutputFilter) {
        outputFilters.removeAll { $0.id == filter.id }
        activeFilters.remove(filter.id)
        saveOutputFilters()
    }
    
    func updateOutputFilter(_ filter: OutputFilter) {
        if let index = outputFilters.firstIndex(where: { $0.id == filter.id }) {
            outputFilters[index] = filter
            saveOutputFilters()
        }
    }
    
    func toggleFilter(_ filter: OutputFilter) {
        if activeFilters.contains(filter.id) {
            activeFilters.remove(filter.id)
        } else {
            activeFilters.insert(filter.id)
        }
    }
    
    func applyFilters(to text: String) -> String {
        var result = text
        
        for filter in outputFilters {
            guard activeFilters.contains(filter.id) && filter.isEnabled else { continue }
            
            switch filter.action {
            case .highlight:
                // Highlight matching text (simplified)
                if filter.isRegex {
                    // Apply regex highlighting
                } else {
                    // Apply simple string highlighting
                }
            case .hide:
                // Hide matching text
                if filter.isRegex {
                    if let regex = try? NSRegularExpression(pattern: filter.pattern) {
                        result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.count), withTemplate: "")
                    }
                } else {
                    result = result.replacingOccurrences(of: filter.pattern, with: "")
                }
            case .replace:
                // Replace matching text
                if filter.isRegex {
                    if let regex = try? NSRegularExpression(pattern: filter.pattern) {
                        result = regex.stringByReplacingMatches(in: result, options: [], range: NSRange(location: 0, length: result.count), withTemplate: "")
                    }
                } else {
                    result = result.replacingOccurrences(of: filter.pattern, with: "")
                }
            case .extract:
                // Extract matching text (simplified)
                if filter.isRegex {
                    if let regex = try? NSRegularExpression(pattern: filter.pattern) {
                        let matches = regex.matches(in: result, options: [], range: NSRange(location: 0, length: result.count))
                        let extracted = matches.compactMap { match in
                            String(result[Range(match.range, in: result)!])
                        }.joined(separator: "\n")
                        result = extracted
                    }
                }
            }
        }
        
        return result
    }
    
    private func loadOutputFilters() {
        if let data = UserDefaults.standard.data(forKey: outputFiltersKey),
           let loadedFilters = try? JSONDecoder().decode([OutputFilter].self, from: data) {
            outputFilters = loadedFilters
        }
    }
    
    private func saveOutputFilters() {
        if let data = try? JSONEncoder().encode(outputFilters) {
            UserDefaults.standard.set(data, forKey: outputFiltersKey)
        }
    }
    
    // MARK: - Export Functions
    
    func exportSession(_ session: TerminalSession, format: ExportFormat) -> Data? {
        switch format {
        case .text:
            return session.output.data(using: .utf8)
        case .html:
            return generateHTMLExport(session)
        case .pdf:
            return generatePDFExport(session)
        case .json:
            return generateJSONExport(session)
        case .csv:
            return generateCSVExport(session)
        }
    }
    
    private func generateHTMLExport(_ session: TerminalSession) -> Data? {
        let html = """
        <!DOCTYPE html>
        <html>
        <head>
            <title>ProTerm Session Export</title>
            <style>
                body { font-family: 'Monaco', 'Menlo', monospace; background: #1e1e1e; color: #d4d4d4; }
                .terminal { background: #000; padding: 20px; border-radius: 5px; }
                .prompt { color: #4CAF50; }
                .command { color: #2196F3; }
                .output { color: #d4d4d4; }
            </style>
        </head>
        <body>
            <div class="terminal">
                <pre>\(session.output)</pre>
            </div>
        </body>
        </html>
        """
        return html.data(using: .utf8)
    }
    
    private func generatePDFExport(_ session: TerminalSession) -> Data? {
        // Simplified PDF generation - in a real implementation, use a PDF library
        return session.output.data(using: .utf8)
    }
    
    private func generateJSONExport(_ session: TerminalSession) -> Data? {
        let exportData = [
            "session": [
                "output": session.output,
                "workingDirectory": session.cwd.path,
                "timestamp": Date().iso8601String
            ]
        ]
        return try? JSONSerialization.data(withJSONObject: exportData, options: .prettyPrinted)
    }
    
    private func generateCSVExport(_ session: TerminalSession) -> Data? {
        let lines = session.output.components(separatedBy: .newlines)
        let csv = lines.enumerated().map { index, line in
            "\(index + 1),\"\(line.replacingOccurrences(of: "\"", with: "\"\""))\""
        }.joined(separator: "\n")
        return csv.data(using: .utf8)
    }
    
    // MARK: - Default Data Setup
    
    private func setupDefaultData() {
        if bookmarks.isEmpty {
            addBookmark(name: "Home", path: NSHomeDirectory(), description: "User home directory", category: .personal)
            addBookmark(name: "Desktop", path: NSHomeDirectory() + "/Desktop", description: "Desktop folder", category: .personal)
            addBookmark(name: "Documents", path: NSHomeDirectory() + "/Documents", description: "Documents folder", category: .personal)
        }
        
        if quickCommands.isEmpty {
            addQuickCommand(name: "List All", command: "ls -la", description: "List all files with details", category: .fileSystem, icon: "list.bullet")
            addQuickCommand(name: "Git Status", command: "git status", description: "Show git status", category: .git, icon: "git.branch")
            addQuickCommand(name: "Docker PS", command: "docker ps", description: "List running containers", category: .docker, icon: "cube")
            addQuickCommand(name: "NPM Install", command: "npm install", description: "Install dependencies", category: .npm, icon: "package")
            addQuickCommand(name: "System Info", command: "uname -a", description: "Show system information", category: .system, icon: "info.circle")
        }
        
        if sessionTemplates.isEmpty {
            addSessionTemplate(
                name: "Development",
                description: "Standard development environment",
                initialCommands: ["pwd", "ls -la"],
                workingDirectory: NSHomeDirectory() + "/Projects",
                environment: ["NODE_ENV": "development"],
                shell: "/bin/zsh"
            )
            addSessionTemplate(
                name: "Docker Development",
                description: "Docker-based development environment",
                initialCommands: ["docker --version", "docker-compose --version"],
                environment: ["DOCKER_BUILDKIT": "1"],
                shell: "/bin/zsh"
            )
        }
        
        if outputFilters.isEmpty {
            addOutputFilter(name: "Errors", pattern: "error|Error|ERROR", isRegex: true, action: .highlight, color: "#FF6B6B")
            addOutputFilter(name: "Warnings", pattern: "warning|Warning|WARNING", isRegex: true, action: .highlight, color: "#FFD93D")
            addOutputFilter(name: "Success", pattern: "success|Success|SUCCESS|completed|Completed", isRegex: true, action: .highlight, color: "#6BCF7F")
        }
    }
}

// MARK: - Date Extension
extension Date {
    var iso8601String: String {
        let formatter = ISO8601DateFormatter()
        return formatter.string(from: self)
    }
}
