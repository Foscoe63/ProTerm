import SwiftUI
import Foundation
import Combine

/// Integration features including git, Docker, and SSH
@MainActor
class IntegrationFeatures: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isEnabled: Bool = true
    
    // MARK: - Initialization
    override init() {
        super.init()
        loadSSHKeys()
        loadSSHConnections()
        
        // Listen for SSH session close events
        NotificationCenter.default.addObserver(
            forName: Notification.Name("ProTermSSHSessionClosed"),
            object: nil,
            queue: .main
        ) { [weak self] notification in
            guard let self = self else { return }
            // Extract the session ID before entering the Task to avoid data race
            let sessionId = notification.object as? UUID
            // Ensure we're on the main actor to access MainActor-isolated properties
            Task { @MainActor [weak self] in
                guard let self = self, let sessionId = sessionId else { return }
                // Check if the closed session is the active SSH session
                if let activeSession = self.activeSSHSession,
                   activeSession.id == sessionId {
                    // Disconnect the SSH connection
                    self.disconnectSSH()
                }
            }
        }
    }
    
    deinit {
        NotificationCenter.default.removeObserver(self)
    }
    
    // MARK: - Git Integration
    @Published var gitStatus: GitStatus?
    @Published var gitBranches: [GitBranch] = []
    @Published var gitCommits: [GitCommit] = []
    @Published var showGitInfo: Bool = true
    
    struct GitStatus: Codable {
        let branch: String
        let isClean: Bool
        let stagedFiles: [String]
        let unstagedFiles: [String]
        let untrackedFiles: [String]
        let ahead: Int
        let behind: Int
        let lastCommit: String?
    }
    
    struct GitBranch: Identifiable, Codable {
        let id: UUID
        let name: String
        let isCurrent: Bool
        let lastCommit: String
        let author: String
        let date: Date
    }
    
    struct GitCommit: Identifiable, Codable {
        let id: UUID
        let hash: String
        let message: String
        let author: String
        let date: Date
        let isCurrent: Bool
    }
    
    // MARK: - Docker Integration
    @Published var dockerContainers: [DockerContainer] = []
    @Published var dockerImages: [DockerImage] = []
    @Published var dockerNetworks: [DockerNetwork] = []
    @Published var showDockerInfo: Bool = true
    
    struct DockerContainer: Identifiable, Codable {
        let id: UUID
        let containerId: String
        let name: String
        let image: String
        let status: String
        let ports: [String]
        let created: Date
    }
    
    struct DockerImage: Identifiable, Codable {
        let id: UUID
        let imageId: String
        let repository: String
        let tag: String
        let size: String
        let created: Date
    }
    
    struct DockerNetwork: Identifiable, Codable {
        let id: UUID
        let networkId: String
        let name: String
        let driver: String
        let scope: String
    }
    
    // MARK: - SSH Key Management
    @Published var sshKeys: [SSHKey] = []
    @Published var sshConnections: [SSHConnection] = []
    @Published var activeSSHConnection: SSHConnection?
    // Holds the TerminalSession that represents the live SSH connection.
    @Published var activeSSHSession: TerminalSession?
    
    struct SSHKey: Identifiable, Codable {
        let id: UUID
        let name: String
        let path: String
        let type: SSHKeyType
        let fingerprint: String
        var isDefault: Bool
        let created: Date
        var lastUsed: Date?
    }
    
    enum SSHKeyType: String, CaseIterable, Codable {
        case rsa = "RSA"
        case ed25519 = "Ed25519"
        case ecdsa = "ECDSA"
        case dsa = "DSA"
    }
    
    struct SSHConnection: Identifiable, Codable {
        let id: UUID
        var name: String
        var host: String
        var port: Int
        var username: String
        var keyPath: String?
        var usesPassword: Bool // Indicates if password authentication is used
        var lastConnected: Date?
        
        // isActive is now computed based on activeSSHConnection
        // Note: This requires access to IntegrationFeatures, so we'll handle it in the view
    }
    
    // MARK: - Cloud Sync
    @Published var cloudSyncEnabled: Bool = false
    @Published var syncProvider: CloudProvider = .iCloud
    @Published var lastSyncDate: Date?
    @Published var syncStatus: SyncStatus = .idle
    
    enum CloudProvider: String, CaseIterable, Codable {
        case iCloud = "iCloud"
        case dropbox = "Dropbox"
        case googleDrive = "Google Drive"
        case oneDrive = "OneDrive"
        case custom = "Custom"
    }
    
    enum SyncStatus: String, CaseIterable, Codable {
        case idle = "Idle"
        case syncing = "Syncing"
        case error = "Error"
        case success = "Success"
    }
    
    // MARK: - Git Integration Methods
    
    func updateGitStatus(in directory: URL) {
        // This would typically run git commands to get status
        // For now, we'll simulate the data
        gitStatus = GitStatus(
            branch: "main",
            isClean: true,
            stagedFiles: [],
            unstagedFiles: [],
            untrackedFiles: [],
            ahead: 0,
            behind: 0,
            lastCommit: "abc1234"
        )
    }
    
    func fetchGitBranches() {
        // Simulate fetching branches
        gitBranches = [
            GitBranch(id: UUID(), name: "main", isCurrent: true, lastCommit: "abc1234", author: "User", date: Date()),
            GitBranch(id: UUID(), name: "develop", isCurrent: false, lastCommit: "def5678", author: "User", date: Date().addingTimeInterval(-3600))
        ]
    }
    
    func fetchGitCommits(limit: Int = 10) {
        // Simulate fetching commits
        gitCommits = (0..<limit).map { i in
            GitCommit(
                id: UUID(),
                hash: "abc\(i)234",
                message: "Commit message \(i)",
                author: "User",
                date: Date().addingTimeInterval(-Double(i) * 3600),
                isCurrent: i == 0
            )
        }
    }
    
    // MARK: - Docker Integration Methods
    
    func updateDockerContainers() {
        // This would run `docker ps` and parse the output
        // For now, we'll simulate the data
        dockerContainers = [
            DockerContainer(
                id: UUID(),
                containerId: "abc123",
                name: "web-server",
                image: "nginx:latest",
                status: "Running",
                ports: ["80:80", "443:443"],
                created: Date().addingTimeInterval(-86400)
            )
        ]
    }
    
    func updateDockerImages() {
        // This would run `docker images` and parse the output
        dockerImages = [
            DockerImage(
                id: UUID(),
                imageId: "def456",
                repository: "nginx",
                tag: "latest",
                size: "133MB",
                created: Date().addingTimeInterval(-172800)
            )
        ]
    }
    
    func updateDockerNetworks() {
        // This would run `docker network ls` and parse the output
        dockerNetworks = [
            DockerNetwork(
                id: UUID(),
                networkId: "ghi789",
                name: "bridge",
                driver: "bridge",
                scope: "local"
            )
        ]
    }
    
    // MARK: - SSH Key Management
    
    func addSSHKey(name: String, path: String, type: SSHKeyType, isDefault: Bool = false) {
        let key = SSHKey(
            id: UUID(),
            name: name,
            path: path,
            type: type,
            fingerprint: Self.fingerprint(ofKeyAt: path),
            isDefault: isDefault,
            created: Date(),
            lastUsed: nil
        )
        sshKeys.append(key)
        saveSSHKeys()
    }
    
    func removeSSHKey(_ key: SSHKey) {
        sshKeys.removeAll { $0.id == key.id }
        saveSSHKeys()
    }
    
    func setDefaultSSHKey(_ key: SSHKey) {
        for i in sshKeys.indices {
            sshKeys[i].isDefault = (sshKeys[i].id == key.id)
        }
        saveSSHKeys()
    }
    
    /// Runs `ssh-keygen -lf` on the key (or its .pub) and returns the SHA256 fingerprint, or "unknown".
    nonisolated static func fingerprint(ofKeyAt path: String) -> String {
        let expanded = (path as NSString).expandingTildeInPath
        let pub = expanded.hasSuffix(".pub") ? expanded : expanded + ".pub"
        let target = FileManager.default.fileExists(atPath: pub) ? pub : expanded
        guard let output = runSSHKeygen(["-lf", target]) else { return "unknown" }
        // Format: "256 SHA256:abc... comment (ED25519)"
        let parts = output.split(separator: " ")
        return parts.count > 1 ? String(parts[1]) : "unknown"
    }

    /// Generates a new key pair with `ssh-keygen`. Returns an error message on failure, nil on success.
    nonisolated static func generateKeyPair(at path: String, type: SSHKeyType, comment: String, passphrase: String) -> String? {
        let expanded = (path as NSString).expandingTildeInPath
        guard !FileManager.default.fileExists(atPath: expanded) else {
            return "A file already exists at \(expanded). Choose a different path."
        }
        let dir = (expanded as NSString).deletingLastPathComponent
        do {
            try FileManager.default.createDirectory(
                atPath: dir, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        } catch {
            return error.localizedDescription
        }
        let algorithm: String
        switch type {
        case .rsa: algorithm = "rsa"
        case .ed25519: algorithm = "ed25519"
        case .ecdsa: algorithm = "ecdsa"
        case .dsa: algorithm = "dsa"
        }
        var args = ["-q", "-t", algorithm, "-f", expanded, "-N", passphrase, "-C", comment]
        if type == .rsa { args += ["-b", "4096"] }
        return runSSHKeygen(args) == nil ? "ssh-keygen failed." : nil
    }

    private nonisolated static func runSSHKeygen(_ arguments: [String]) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh-keygen")
        process.arguments = arguments
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return nil
        }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
    }
    
    private func loadSSHKeys() {
        if let data = UserDefaults.standard.data(forKey: "ProTermSSHKeys"),
           let loadedKeys = try? JSONDecoder().decode([SSHKey].self, from: data) {
            sshKeys = loadedKeys
        }
    }
    
    private func saveSSHKeys() {
        if let data = try? JSONEncoder().encode(sshKeys) {
            UserDefaults.standard.set(data, forKey: "ProTermSSHKeys")
        }
    }
    
    // MARK: - SSH Connection Management
    
    func addSSHConnection(name: String, host: String, port: Int = 22, username: String, keyPath: String? = nil, password: String? = nil) {
        let connection = SSHConnection(
            id: UUID(),
            name: name,
            host: host,
            port: port,
            username: username,
            keyPath: keyPath,
            usesPassword: password != nil,
            lastConnected: nil
        )
        sshConnections.append(connection)
        
        // Store password in Keychain if provided
        if let password = password, !password.isEmpty {
            _ = KeychainHelper.shared.savePassword(password, for: connection.id)
        }
        
        saveSSHConnections()
    }
    
    func updateSSHConnection(id: UUID, name: String, host: String, port: Int, username: String, keyPath: String?, usesPassword: Bool, password: String?) {
        if let index = sshConnections.firstIndex(where: { $0.id == id }) {
            sshConnections[index].name = name
            sshConnections[index].host = host
            sshConnections[index].port = port
            sshConnections[index].username = username
            sshConnections[index].keyPath = keyPath
            sshConnections[index].usesPassword = usesPassword
            
            // Handle password update
            if usesPassword {
                if let password = password, !password.isEmpty {
                    // Update password if a new one is provided
                    _ = KeychainHelper.shared.savePassword(password, for: id)
                }
                // If password is empty/nil, we keep the existing one in Keychain
            } else {
                // If switched to SSH Key, remove existing password
                _ = KeychainHelper.shared.deletePassword(for: id)
            }
            
            saveSSHConnections()
        }
    }
    
    func removeSSHConnection(_ connection: SSHConnection) {
        // Remove password from Keychain
        _ = KeychainHelper.shared.deletePassword(for: connection.id)
        
        sshConnections.removeAll { $0.id == connection.id }
        saveSSHConnections()
    }
    
    /// Get password for a connection from Keychain
    func getPassword(for connection: SSHConnection) -> String? {
        return KeychainHelper.shared.getPassword(for: connection.id)
    }
    
    func connectSSH(_ connection: SSHConnection) {
        // Mark the connection as active and persist state.
        activeSSHConnection = connection
        if let index = sshConnections.firstIndex(where: { $0.id == connection.id }) {
            sshConnections[index].lastConnected = Date()
        }
        saveSSHConnections()
    }
    
    func disconnectSSH() {
        // Stop any active SSH session first.
        if let session = activeSSHSession {
            // Gracefully interrupt the process; TerminalSession will clear flags.
            session.interruptCurrentProcess()
            // Remove the session from the manager if desired.
            // The UI can keep the tab; we just clear the running flag.
            activeSSHSession = nil
        }

        // Clear connection state.
        activeSSHConnection = nil
        saveSSHConnections()
    }
    
    // Helper to check if a connection is active
    func isConnectionActive(_ connection: SSHConnection) -> Bool {
        return activeSSHConnection?.id == connection.id
    }
    
    private func loadSSHConnections() {
        if let data = UserDefaults.standard.data(forKey: "ProTermSSHConnections"),
           let loadedConnections = try? JSONDecoder().decode([SSHConnection].self, from: data) {
            sshConnections = loadedConnections
        }
    }
    
    private func saveSSHConnections() {
        if let data = try? JSONEncoder().encode(sshConnections) {
            UserDefaults.standard.set(data, forKey: "ProTermSSHConnections")
        }
    }
    
    // MARK: - Cloud Sync Methods
    
    func enableCloudSync(provider: CloudProvider) {
        guard FeatureFlags.iCloudSyncEnabled else { return }
        cloudSyncEnabled = true
        syncProvider = provider
        syncStatus = .syncing
        
        // Simulate sync process
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.syncStatus = .success
            self.lastSyncDate = Date()
        }
    }
    
    func disableCloudSync() {
        cloudSyncEnabled = false
        syncStatus = .idle
    }
    
    func syncNow() {
        guard FeatureFlags.iCloudSyncEnabled, cloudSyncEnabled else { return }
        syncStatus = .syncing
        
        // Simulate sync process
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
            self.syncStatus = .success
            self.lastSyncDate = Date()
        }
    }
}
