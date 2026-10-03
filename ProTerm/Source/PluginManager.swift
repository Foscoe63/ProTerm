import AppKit
import Combine
import CryptoKit
import Foundation

// MARK: - Manifest

/// A declarative plugin: a `plugin.json` that contributes shell commands to the Command Palette.
/// Plugins contain no executable ProTerm code. Each command is a shell line that is typed into the
/// active terminal, so you always see exactly what runs.
///
/// ```json
/// {
///   "id": "com.example.git-helpers",
///   "name": "Git Helpers",
///   "version": "1.0.0",
///   "description": "Handy git commands",
///   "author": "You",
///   "commands": [
///     { "title": "Status", "command": "git status -sb" },
///     { "title": "Checkout branch", "command": "git checkout {{branch}}",
///       "inputs": [{ "name": "branch", "prompt": "Branch name" }], "confirm": true }
///   ]
/// }
/// ```
/// `{{name}}` is replaced with the user's (shell-quoted) input; `{{pluginDir}}` with the plugin's folder.
struct PluginManifest: Codable, Equatable {
    struct Input: Codable, Equatable {
        var name: String
        var prompt: String?
        var defaultValue: String?
    }

    struct Command: Codable, Equatable, Identifiable {
        var title: String
        var command: String
        var description: String?
        var icon: String?
        var inputs: [Input]?
        /// Ask before running (recommended for anything destructive).
        var confirm: Bool?
        var id: String { title }
    }

    var id: String
    var name: String
    var version: String
    var description: String?
    var author: String?
    var commands: [Command]

    static let maxCommands = 100
    static let maxCommandLength = 2000

    enum ValidationError: LocalizedError, Equatable {
        case invalid(String)
        var errorDescription: String? {
            if case .invalid(let message) = self { return message }
            return nil
        }
    }

    static func decode(_ data: Data) throws -> PluginManifest {
        let manifest: PluginManifest
        do {
            manifest = try JSONDecoder().decode(PluginManifest.self, from: data)
        } catch {
            throw ValidationError.invalid("plugin.json is not valid: \(error.localizedDescription)")
        }
        try manifest.validate()
        return manifest
    }

    func validate() throws {
        let idPattern = "^[A-Za-z0-9][A-Za-z0-9._-]{0,99}$"
        guard id.range(of: idPattern, options: .regularExpression) != nil else {
            throw ValidationError.invalid("id must be letters, digits, '.', '_' or '-' (max 100 characters)")
        }
        guard !name.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.invalid("name is empty") }
        guard !version.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.invalid("version is empty") }
        guard !commands.isEmpty else { throw ValidationError.invalid("a plugin needs at least one command") }
        guard commands.count <= Self.maxCommands else { throw ValidationError.invalid("too many commands (max \(Self.maxCommands))") }
        var titles = Set<String>()
        for command in commands {
            guard !command.title.trimmingCharacters(in: .whitespaces).isEmpty else { throw ValidationError.invalid("a command has no title") }
            guard titles.insert(command.title).inserted else { throw ValidationError.invalid("duplicate command title '\(command.title)'") }
            guard !command.command.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                throw ValidationError.invalid("command '\(command.title)' is empty")
            }
            guard command.command.count <= Self.maxCommandLength else {
                throw ValidationError.invalid("command '\(command.title)' is too long")
            }
            for input in command.inputs ?? [] {
                guard input.name.range(of: "^[A-Za-z][A-Za-z0-9_]*$", options: .regularExpression) != nil, input.name != "pluginDir" else {
                    throw ValidationError.invalid("input name '\(input.name)' in '\(command.title)' is not allowed")
                }
            }
        }
    }
}

// MARK: - Command expansion

enum PluginCommandBuilder {
    /// Quotes a value so the shell treats it as one literal word.
    static func shellQuote(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// Replaces `{{name}}` tokens. Values are always shell-quoted, so user input can't inject extra commands.
    /// Returns nil if a token has no value (an undeclared input).
    static func expand(_ template: String, values: [String: String]) -> String? {
        var result = ""
        var rest = Substring(template)
        while let open = rest.range(of: "{{") {
            result += rest[..<open.lowerBound]
            guard let close = rest[open.upperBound...].range(of: "}}") else {
                result += rest[open.lowerBound...]
                return result
            }
            let key = rest[open.upperBound..<close.lowerBound].trimmingCharacters(in: .whitespaces)
            guard let value = values[key] else { return nil }
            result += shellQuote(value)
            rest = rest[close.upperBound...]
        }
        result += rest
        return result
    }
}

// MARK: - Manager

@MainActor
final class PluginManager: ObservableObject {
    static let shared = PluginManager()

    struct Plugin: Identifiable {
        let id: String
        let directory: URL
        let manifest: PluginManifest
        let manifestHash: String
        var isEnabled: Bool
        /// Enabled before, but plugin.json changed since the user approved it.
        var needsReapproval: Bool
    }

    struct LoadFailure: Identifiable {
        let id = UUID()
        let folder: String
        let reason: String
    }

    @Published private(set) var plugins: [Plugin] = []
    @Published private(set) var failures: [LoadFailure] = []

    let directory: URL
    private let defaults: UserDefaults
    private let approvedKey = "ProTermApprovedPlugins"  // [pluginID: manifest sha256]

    static var defaultDirectory: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask).first!
        return base.appendingPathComponent("ProTerm/Plugins", isDirectory: true)
    }

    init(directory: URL = PluginManager.defaultDirectory, defaults: UserDefaults = .standard) {
        self.directory = directory
        self.defaults = defaults
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        reload()
    }

    // MARK: Loading

    func reload() {
        var loaded: [Plugin] = []
        var failed: [LoadFailure] = []
        let approved = approvedHashes()
        let folders = (try? FileManager.default.contentsOfDirectory(
            at: directory, includingPropertiesForKeys: [.isDirectoryKey])) ?? []
        for folder in folders.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) {
            guard (try? folder.resourceValues(forKeys: [.isDirectoryKey]).isDirectory) == true else { continue }
            let manifestURL = folder.appendingPathComponent("plugin.json")
            guard let data = try? Data(contentsOf: manifestURL) else {
                failed.append(LoadFailure(folder: folder.lastPathComponent, reason: "no plugin.json"))
                continue
            }
            do {
                let manifest = try PluginManifest.decode(data)
                if loaded.contains(where: { $0.id == manifest.id }) {
                    failed.append(LoadFailure(folder: folder.lastPathComponent, reason: "duplicate plugin id \(manifest.id)"))
                    continue
                }
                let hash = Self.sha256(data)
                let approvedHash = approved[manifest.id]
                loaded.append(Plugin(
                    id: manifest.id, directory: folder, manifest: manifest, manifestHash: hash,
                    isEnabled: approvedHash == hash, needsReapproval: approvedHash != nil && approvedHash != hash))
            } catch {
                failed.append(LoadFailure(folder: folder.lastPathComponent, reason: error.localizedDescription))
            }
        }
        plugins = loaded
        failures = failed
    }

    // MARK: Trust

    /// Enabling records a hash of plugin.json; editing the file later disables the plugin until re-approved.
    func setEnabled(_ enabled: Bool, pluginID: String) {
        guard let index = plugins.firstIndex(where: { $0.id == pluginID }) else { return }
        var approved = approvedHashes()
        if enabled {
            approved[pluginID] = plugins[index].manifestHash
        } else {
            approved.removeValue(forKey: pluginID)
        }
        defaults.set(approved, forKey: approvedKey)
        plugins[index].isEnabled = enabled
        plugins[index].needsReapproval = false
    }

    private func approvedHashes() -> [String: String] {
        defaults.dictionary(forKey: approvedKey) as? [String: String] ?? [:]
    }

    private static func sha256(_ data: Data) -> String {
        SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
    }

    // MARK: Install / remove

    /// Copies a plugin folder into the plugins directory after validating its manifest.
    @discardableResult
    func install(from folder: URL) throws -> String {
        let data = try Data(contentsOf: folder.appendingPathComponent("plugin.json"))
        let manifest = try PluginManifest.decode(data)
        guard !plugins.contains(where: { $0.id == manifest.id }) else {
            throw PluginManifest.ValidationError.invalid("A plugin with id \(manifest.id) is already installed. Remove it first.")
        }
        let target = directory.appendingPathComponent(manifest.id, isDirectory: true)
        guard !FileManager.default.fileExists(atPath: target.path) else {
            throw PluginManifest.ValidationError.invalid("\(target.lastPathComponent) already exists in the plugins folder.")
        }
        try FileManager.default.copyItem(at: folder, to: target)
        reload()
        return manifest.id
    }

    func remove(pluginID: String) throws {
        guard let plugin = plugins.first(where: { $0.id == pluginID }) else { return }
        // Only ever delete inside our plugins directory.
        guard plugin.directory.standardizedFileURL.deletingLastPathComponent() == directory.standardizedFileURL else { return }
        try FileManager.default.removeItem(at: plugin.directory)
        setEnabled(false, pluginID: pluginID)
        reload()
    }

    /// Writes an example plugin authors can copy. Returns its folder.
    @discardableResult
    func writeExamplePlugin() throws -> URL {
        let manifest = PluginManifest(
            id: "proterm.example", name: "Example Helpers", version: "1.0.0",
            description: "Sample commands showing inputs and confirmation. Edit or copy this folder to make your own.",
            author: "ProTerm",
            commands: [
                .init(title: "Git status", command: "git status -sb", description: "Short git status", icon: "arrow.triangle.branch"),
                .init(title: "Disk usage", command: "df -h", description: "Free space per volume", icon: "internaldrive"),
                .init(title: "Find files by name", command: "find . -iname {{pattern}}", description: "Search the current folder",
                      icon: "magnifyingglass", inputs: [.init(name: "pattern", prompt: "File name pattern (e.g. *.log)", defaultValue: nil)]),
                .init(title: "Kill process on port", command: "lsof -ti tcp:{{port}} | xargs kill", description: "Stops whatever listens on a port",
                      icon: "xmark.octagon", inputs: [.init(name: "port", prompt: "Port number", defaultValue: nil)], confirm: true)
            ])
        let folder = directory.appendingPathComponent(manifest.id, isDirectory: true)
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        try encoder.encode(manifest).write(to: folder.appendingPathComponent("plugin.json"), options: .atomic)
        reload()
        return folder
    }

    // MARK: Running

    /// Commands of enabled plugins, for the palette.
    var enabledCommands: [(plugin: Plugin, command: PluginManifest.Command)] {
        plugins.filter(\.isEnabled).flatMap { plugin in plugin.manifest.commands.map { (plugin, $0) } }
    }

    /// Asks for inputs/confirmation if needed, then types the command into the session.
    func run(_ command: PluginManifest.Command, of plugin: Plugin, in session: TerminalSession) {
        var values: [String: String] = ["pluginDir": plugin.directory.path]
        for input in command.inputs ?? [] {
            guard let value = Self.promptForValue(
                title: "\(plugin.manifest.name): \(command.title)",
                message: input.prompt ?? input.name, defaultValue: input.defaultValue ?? "") else { return }
            values[input.name] = value
        }
        guard let line = PluginCommandBuilder.expand(command.command, values: values) else {
            Self.alert("Cannot run \(command.title)", "The command uses a {{value}} that the plugin does not declare as an input.")
            return
        }
        if command.confirm == true {
            let alert = NSAlert()
            alert.messageText = "Run \(command.title)?"
            alert.informativeText = line
            alert.addButton(withTitle: "Run")
            alert.addButton(withTitle: "Cancel")
            guard alert.runModal() == .alertFirstButtonReturn else { return }
        }
        session.runCommand(line)
    }

    private static func promptForValue(title: String, message: String, defaultValue: String) -> String? {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        let field = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        field.stringValue = defaultValue
        alert.accessoryView = field
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        alert.window.initialFirstResponder = field
        return alert.runModal() == .alertFirstButtonReturn ? field.stringValue : nil
    }

    static func alert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        alert.runModal()
    }
}
