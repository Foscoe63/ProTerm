import SwiftUI
import UniformTypeIdentifiers   // needed for UTType
import AppKit

struct ContentView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var lineNumbersManager: LineNumbersManager
    @EnvironmentObject var keyboardShortcutsManager: KeyboardShortcutsManager
    @EnvironmentObject var productivityTools: ProductivityTools

    // The index of the currently‑selected session.
    @State private var selectedTab = 0

    // Optional global search bar (kept from the original scaffold).
    @State private var searchQuery = ""
    
    // Quick commands panel visibility
    @State private var showQuickCommands = false
    
    // Command palette visibility
    @State private var showCommandPalette = false

    private var focusController: CommandInputFocusController { CommandInputFocusController.shared }

    var body: some View {
        ZStack {
            HStack(spacing: 0) {
                // Quick commands panel (left sidebar)
                QuickCommandsPanel(isVisible: $showQuickCommands)
                
                VStack(spacing: 0) {
                // MARK: – Button bar (receives the binding to keep tabs in sync)
                ButtonBarView(selectedTab: $selectedTab, showQuickCommands: $showQuickCommands)
                    .padding(.horizontal, 8)
                    .frame(height: 40)
                    .background(themeManager.current.background.opacity(0.2))
                    .onAppear {
                        // When the view first appears, ensure the window is key and focus is set immediately
                        DispatchQueue.main.async {
                            NSApp.activate(ignoringOtherApps: true)
                            if let window = NSApplication.shared.mainWindow {
                                window.makeKeyAndOrderFront(nil)
                                // Post focus notification immediately
                                if terminalManager.sessions.indices.contains(selectedTab) {
                                    let targetId = terminalManager.sessions[selectedTab].id
                                    NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: targetId)
                                    Task { @MainActor in
                                        focusCurrentSession(reason: .startup)
                                    }
                                }
                            }
                        }
                        // Also try with a short delay as fallback
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            NSApp.activate(ignoringOtherApps: true)
                            if let window = NSApplication.shared.mainWindow {
                                window.makeKeyAndOrderFront(nil)
                                if terminalManager.sessions.indices.contains(selectedTab) {
                                    let targetId = terminalManager.sessions[selectedTab].id
                                    NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: targetId)
                                    Task { @MainActor in
                                        focusCurrentSession(reason: .startup)
                                    }
                                }
                            }
                        }
                    }
                    .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
                        // When window becomes key, ensure focus is set immediately
                        DispatchQueue.main.async {
                            NSApp.activate(ignoringOtherApps: true)
                            if terminalManager.sessions.indices.contains(selectedTab) {
                                let targetId = terminalManager.sessions[selectedTab].id
                                // Post focus notification for the current session
                                NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: targetId)
                                Task { @MainActor in
                                    focusCurrentSession(reason: .windowBecameKey)
                                }
                            }
                        }
                    }

                // MARK: – Tab Bar (one tab per session)
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 6) {
                        ForEach(Array(terminalManager.sessions.enumerated()), id: \.element.id) { index, session in
                            let meta = terminalManager.getTabMetadata(for: session.id)
                            TabButton(
                                session: session,
                                index: index,
                                meta: meta,
                                isSelected: selectedTab == index,
                                terminalManager: terminalManager,
                                onSelect: { selectedTab = index },
                                onMove: { from, to in
                                    terminalManager.moveSession(from: from, to: to)
                                    // Update selectedTab to track the moved session
                                    if selectedTab == from {
                                        selectedTab = to
                                    } else if selectedTab > from && selectedTab <= to {
                                        selectedTab -= 1
                                    } else if selectedTab < from && selectedTab >= to {
                                        selectedTab += 1
                                    }
                                }
                            )
                        }
                    }
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                }
                .background(themeManager.current.background.opacity(0.05))
                .accessibilityElement(children: .contain)
                .accessibilityLabel("Terminal tabs")
                .accessibilityHint("Use arrow keys to navigate between tabs. Press Space to select a tab.")

                // MARK: – Optional global search bar
                if !searchQuery.isEmpty {
                    SearchBarView(query: $searchQuery)
                }

                // MARK: – Terminal View
                if terminalManager.sessions.indices.contains(selectedTab) {
                    let currentSession = terminalManager.sessions[selectedTab]
                    TerminalView(session: currentSession)
                        .id(currentSession.id) // Force SwiftUI to create a new view for each session
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .accessibilityElement(children: .contain)
                        .accessibilityLabel("Terminal session")
                        .accessibilityHint("Terminal output and command input. Use Tab to navigate between elements.")
                        .onChange(of: selectedTab) { _, newIndex in
                            // Restore focus when switching sessions — target the new session explicitly
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                                if terminalManager.sessions.indices.contains(newIndex) {
                                    let targetId = terminalManager.sessions[newIndex].id
                                    NotificationCenter.default.post(name: .focusCommandInput, object: targetId)
                                    Task { @MainActor in
                                        focusCurrentSession(reason: .manual)
                                    }
                                } else {
                                    NotificationCenter.default.post(name: .focusCommandInput, object: nil)
                                    Task { @MainActor in
                                        focusCurrentSession(reason: .manual)
                                    }
                                }
                            }
                        }
                }

                // MARK: – Status bar (bottom)
                StatusBarView(selectedTab: $selectedTab)
                    .frame(height: 28)
                    .background(themeManager.current.background.opacity(0.1))
                }
            }
            
            // Toast notifications overlay
            ToastContainer()
            
            // Command palette overlay
            if showCommandPalette {
                CommandPaletteView(isVisible: $showCommandPalette, selectedTab: $selectedTab)
                    .zIndex(1000)
            }
        }
        .onAppear {
            terminalManager.setShellManager(shellManager)
            setupKeyboardShortcuts()
            
            // CRITICAL: Activate app and ensure window is key on startup
            // This is essential for focus to work when running outside Xcode
            // Do this immediately and aggressively
            NSApp.activate(ignoringOtherApps: true)
            
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let window = NSApplication.shared.mainWindow
                    ?? NSApplication.shared.keyWindow
                    ?? NSApp.windows.first
                
                if let window = window {
                    // CRITICAL: Make window key immediately - this is the key to focus working
                    window.makeKeyAndOrderFront(nil)
                    // Force window to be key - sometimes makeKeyAndOrderFront isn't enough
                    if !window.isKeyWindow {
                        window.makeKey()
                        // Sometimes we need to order front again after makeKey
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                
                // Broadcast a generic focus request so whichever TerminalView is active can claim focus
                NotificationCenter.default.post(name: .focusCommandInput, object: nil)
                Task { @MainActor in
                    focusCurrentSession(reason: .startup)
                }
            }
            
            // Also try after a short delay to ensure window is fully ready
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                NSApp.activate(ignoringOtherApps: true)
                let window = NSApplication.shared.mainWindow
                    ?? NSApplication.shared.keyWindow
                    ?? NSApp.windows.first
                
                if let window = window {
                    window.makeKeyAndOrderFront(nil)
                    if !window.isKeyWindow {
                        window.makeKey()
                        window.makeKeyAndOrderFront(nil)
                    }
                }
                
                // Post another broadcast in case TerminalView mounted after the first one
                NotificationCenter.default.post(name: .focusCommandInput, object: nil)
                Task { @MainActor in
                    focusCurrentSession(reason: .startup)
                }
            }
            
            // Also try after a longer delay
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                NSApp.activate(ignoringOtherApps: true)
                let window = NSApplication.shared.mainWindow
                    ?? NSApplication.shared.keyWindow
                    ?? NSApp.windows.first
                
                if let window = window, !window.isKeyWindow {
                    window.makeKey()
                    window.makeKeyAndOrderFront(nil)
                }
                
                NotificationCenter.default.post(name: .focusCommandInput, object: nil)
                Task { @MainActor in
                    focusCurrentSession(reason: .startup)
                }
            }
        }
        // Listen for when the window becomes key to set initial focus
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { _ in
            // When window becomes key, set focus on command field
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                if terminalManager.sessions.indices.contains(selectedTab) {
                    let targetId = terminalManager.sessions[selectedTab].id
                    NotificationCenter.default.post(name: .focusCommandInput, object: targetId)
                    Task { @MainActor in
                        focusCurrentSession(reason: .windowBecameKey)
                    }
                }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ProTermShowCommandPalette"))) { _ in
            showCommandPalette = true
        }
        .keyboardShortcuts(keyboardShortcutsManager)
        // MARK: – Drag‑and‑drop support (read‑only tabs)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let fileURL = url,
                   let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    DispatchQueue.main.async {
                        let session = TerminalSession(shellManager: shellManager)
                        session.output = content
                        terminalManager.sessions.append(session)
                    }
                }
            }
            return true
        }
    }
    
    @MainActor
    private func focusCurrentSession(reason: CommandInputFocusController.FocusReason) {
        guard terminalManager.sessions.indices.contains(selectedTab) else {
            focusController.clearActiveSession()
            return
        }
        let sessionID = terminalManager.sessions[selectedTab].id
        focusController.setActiveSession(sessionID)
        focusController.requestFocus(for: sessionID, reason: reason)
    }
    
    // MARK: - Keyboard Shortcuts Setup
    private func setupKeyboardShortcuts() {
        keyboardShortcutsManager.onSelectAll = {
            // Select all terminal output
            NotificationCenter.default.post(name: .selectAllTerminal, object: nil)
        }
        
        keyboardShortcutsManager.onQuickSearch = {
            // Open quick search
            NotificationCenter.default.post(name: .quickSearch, object: nil)
        }
        
        keyboardShortcutsManager.onClearScreen = {
            // Clear current terminal
            if terminalManager.sessions.indices.contains(selectedTab) {
                terminalManager.sessions[selectedTab].clearOutput()
            }
        }
        
        keyboardShortcutsManager.onNewTab = {
            // Create new tab
            terminalManager.addSession()
            selectedTab = terminalManager.sessions.count - 1
        }
        
        keyboardShortcutsManager.onCloseTab = {
            // Close current tab
            if terminalManager.sessions.count > 1 {
                terminalManager.closeSession(at: selectedTab)
                selectedTab = min(selectedTab, terminalManager.sessions.count - 1)
            }
        }
        
        keyboardShortcutsManager.onSwitchTab = { index in
            // Switch to specific tab
            if terminalManager.sessions.indices.contains(index) {
                selectedTab = index
            }
        }
        
        keyboardShortcutsManager.onCopy = {
            // Copy terminal output
            if terminalManager.sessions.indices.contains(selectedTab) {
                let session = terminalManager.sessions[selectedTab]
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.output, forType: .string)
            }
        }
        
        keyboardShortcutsManager.onPaste = {
            // Paste to input
            if let pasteboardString = NSPasteboard.general.string(forType: .string) {
                NotificationCenter.default.post(name: .pasteToInput, object: pasteboardString)
            }
        }
        
        keyboardShortcutsManager.onFind = {
            // Open find dialog
            NotificationCenter.default.post(name: .searchInTerminal, object: "")
        }
        
        keyboardShortcutsManager.onReplace = {
            // Open replace dialog
            NotificationCenter.default.post(name: .replaceInTerminal, object: ["find": "", "replace": ""])
        }
        
        keyboardShortcutsManager.onFocusInput = {
            // Focus command input in current terminal
            NotificationCenter.default.post(name: .focusCommandInput, object: nil)
            Task { @MainActor in
                focusCurrentSession(reason: .manual)
            }
        }
        
        keyboardShortcutsManager.onCommandPalette = {
            // Open command palette
            showCommandPalette = true
        }
    }
}

// MARK: - Command Palette View
struct CommandPaletteView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var advancedFeatures: AdvancedFeatures
    @EnvironmentObject var productivityTools: ProductivityTools
    @Binding var isVisible: Bool
    @Binding var selectedTab: Int
    
    @State private var searchText: String = ""
    @State private var selectedIndex: Int = 0
    @FocusState private var isSearchFocused: Bool
    
    struct CommandItem: Identifiable {
        let id = UUID()
        let title: String
        let subtitle: String?
        let icon: String
        let category: String
        let action: () -> Void
    }
    
    var filteredCommands: [CommandItem] {
        let allCommands = buildCommandList()
        if searchText.isEmpty {
            return allCommands
        }
        let lowerSearch = searchText.lowercased()
        return allCommands.filter { command in
            command.title.lowercased().contains(lowerSearch) ||
            (command.subtitle?.lowercased().contains(lowerSearch) ?? false) ||
            command.category.lowercased().contains(lowerSearch)
        }
    }
    
    var body: some View {
        if isVisible {
            ZStack {
                // Semi-transparent background
                Color.black.opacity(0.3)
                    .ignoresSafeArea()
                    .onTapGesture {
                        isVisible = false
                    }
                
                // Command palette window - moveable
                MoveablePanel(title: "Command Palette", onClose: { isVisible = false }) {
                    VStack(spacing: 0) {
                        // Search bar
                        HStack {
                            Image(systemName: "magnifyingglass")
                                .foregroundColor(.secondary)
                            TextField("Type to search commands...", text: $searchText)
                                .focused($isSearchFocused)
                                .textFieldStyle(.plain)
                                .onSubmit {
                                    executeSelectedCommand()
                                }
                                .onKeyPress(.escape) {
                                    isVisible = false
                                    return .handled
                                }
                                .onKeyPress(.upArrow) {
                                    if selectedIndex > 0 {
                                        selectedIndex -= 1
                                    }
                                    return .handled
                                }
                                .onKeyPress(.downArrow) {
                                    if selectedIndex < filteredCommands.count - 1 {
                                        selectedIndex += 1
                                    }
                                    return .handled
                                }
                        }
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        
                        Divider()
                        
                        // Command list
                        ScrollView {
                            LazyVStack(alignment: .leading, spacing: 0) {
                                ForEach(Array(filteredCommands.enumerated()), id: \.element.id) { index, command in
                                    CommandPaletteRow(
                                        command: command,
                                        isSelected: index == selectedIndex
                                    ) {
                                        command.action()
                                        isVisible = false
                                    }
                                }
                            }
                        }
                        .frame(maxHeight: 400)
                        .background(Color(NSColor.windowBackgroundColor))
                    }
                    .frame(width: 600)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .transition(.opacity.combined(with: .scale(scale: 0.95)))
            .onAppear {
                isSearchFocused = true
                selectedIndex = 0
                searchText = ""
            }
            .onChange(of: searchText) {
                selectedIndex = 0
            }
        }
    }
    
    private func buildCommandList() -> [CommandItem] {
        var commands: [CommandItem] = []
        
        // Terminal actions
        commands.append(CommandItem(
            title: "New Tab",
            subtitle: "Create a new terminal tab",
            icon: "plus.square.on.square",
            category: "Terminal"
        ) {
            terminalManager.addSession()
            selectedTab = terminalManager.sessions.count - 1
            ToastManager.shared.show("New tab created", type: .success)
        })
        
        commands.append(CommandItem(
            title: "Close Tab",
            subtitle: "Close current tab",
            icon: "xmark.square",
            category: "Terminal"
        ) {
            if terminalManager.sessions.count > 1 {
                terminalManager.closeSession(at: selectedTab)
                selectedTab = min(selectedTab, terminalManager.sessions.count - 1)
                ToastManager.shared.show("Tab closed", type: .info)
            }
        })
        
        commands.append(CommandItem(
            title: "Clear Screen",
            subtitle: "Clear terminal output",
            icon: "trash",
            category: "Terminal"
        ) {
            if terminalManager.sessions.indices.contains(selectedTab) {
                terminalManager.sessions[selectedTab].clearOutput()
                ToastManager.shared.show("Screen cleared", type: .info)
            }
        })
        
        // Quick commands
        for quickCommand in productivityTools.quickCommands {
            commands.append(CommandItem(
                title: quickCommand.name,
                subtitle: quickCommand.description ?? quickCommand.command,
                icon: quickCommand.icon,
                category: "Quick Commands"
            ) {
                if terminalManager.sessions.indices.contains(selectedTab) {
                    let session = terminalManager.sessions[selectedTab]
                    session.runCommand(quickCommand.command)
                    productivityTools.recordQuickCommandUsage(quickCommand.id)
                }
            })
        }
        
        // Aliases
        for (alias, command) in advancedFeatures.aliases {
            commands.append(CommandItem(
                title: alias,
                subtitle: "Alias: \(command)",
                icon: "link",
                category: "Aliases"
            ) {
                if terminalManager.sessions.indices.contains(selectedTab) {
                    terminalManager.sessions[selectedTab].runCommand(command)
                }
            })
        }
        
        // Preferences
        commands.append(CommandItem(
            title: "Open Preferences",
            subtitle: "Open settings",
            icon: "gearshape",
            category: "Settings"
        ) {
            NotificationCenter.default.post(name: Notification.Name("ProTermShowPreferences"), object: nil)
        })
        
        // Bash/Zsh Commands
        let shellCommands: [(title: String, command: String, icon: String, category: String)] = [
            // File Operations
            ("List Files", "ls", "doc.text", "Shell Commands"),
            ("List All Files", "ls -la", "doc.text.fill", "Shell Commands"),
            ("List Files Detailed", "ls -lh", "list.bullet", "Shell Commands"),
            ("Change Directory", "cd", "folder", "Shell Commands"),
            ("Go Home", "cd ~", "house", "Shell Commands"),
            ("Go Up Directory", "cd ..", "arrow.up", "Shell Commands"),
            ("Print Working Directory", "pwd", "location", "Shell Commands"),
            ("Make Directory", "mkdir", "folder.badge.plus", "Shell Commands"),
            ("Remove File", "rm", "trash", "Shell Commands"),
            ("Remove Directory", "rmdir", "trash.fill", "Shell Commands"),
            ("Copy File", "cp", "doc.on.doc", "Shell Commands"),
            ("Move File", "mv", "arrow.right", "Shell Commands"),
            ("Find Files", "find", "magnifyingglass", "Shell Commands"),
            ("Locate File", "locate", "mappin", "Shell Commands"),
            
            // Text Operations
            ("View File", "cat", "doc.text", "Shell Commands"),
            ("View File Page by Page", "less", "doc.text.fill", "Shell Commands"),
            ("View First Lines", "head", "text.alignleft", "Shell Commands"),
            ("View Last Lines", "tail", "text.alignright", "Shell Commands"),
            ("Word Count", "wc", "textformat.123", "Shell Commands"),
            ("Search in File", "grep", "magnifyingglass", "Shell Commands"),
            ("Search Recursively", "grep -r", "magnifyingglass.circle", "Shell Commands"),
            
            // System Info
            ("System Info", "uname -a", "info.circle", "Shell Commands"),
            ("Disk Usage", "df -h", "internaldrive", "Shell Commands"),
            ("Directory Size", "du -sh", "chart.bar", "Shell Commands"),
            ("Process List", "ps aux", "list.bullet", "Shell Commands"),
            ("Top Processes", "top", "chart.line.uptrend.xyaxis", "Shell Commands"),
            ("Environment Variables", "env", "list.bullet.rectangle", "Shell Commands"),
            ("Current User", "whoami", "person", "Shell Commands"),
            ("System Uptime", "uptime", "clock", "Shell Commands"),
            
            // Network
            ("Network Interfaces", "ifconfig", "network", "Shell Commands"),
            ("Ping Host", "ping", "network", "Shell Commands"),
            ("Show Routes", "netstat -rn", "map", "Shell Commands"),
            ("Open URL", "open", "safari", "Shell Commands"),
            
            // Git (if available)
            ("Git Status", "git status", "vault", "Shell Commands"),
            ("Git Log", "git log", "clock.arrow.circlepath", "Shell Commands"),
            ("Git Diff", "git diff", "doc.text.magnifyingglass", "Shell Commands"),
            ("Git Add All", "git add .", "plus.circle", "Shell Commands"),
            ("Git Commit", "git commit -m", "checkmark.circle", "Shell Commands"),
            ("Git Push", "git push", "arrow.up.circle", "Shell Commands"),
            ("Git Pull", "git pull", "arrow.down.circle", "Shell Commands"),
            ("Git Branch", "git branch", "arrow.triangle.branch", "Shell Commands"),
            
            // Package Management (macOS)
            ("Homebrew Update", "brew update", "arrow.clockwise", "Shell Commands"),
            ("Homebrew Upgrade", "brew upgrade", "arrow.up.circle", "Shell Commands"),
            ("Homebrew List", "brew list", "list.bullet", "Shell Commands"),
            ("Homebrew Search", "brew search", "magnifyingglass", "Shell Commands"),
            
            // Permissions
            ("Change Permissions", "chmod", "lock", "Shell Commands"),
            ("Change Owner", "chown", "person.crop.circle", "Shell Commands"),
            
            // Archives
            ("Extract Tar", "tar -xzf", "archivebox", "Shell Commands"),
            ("Create Tar", "tar -czf", "archivebox.fill", "Shell Commands"),
            ("Extract Zip", "unzip", "archivebox", "Shell Commands"),
            ("Create Zip", "zip -r", "archivebox.fill", "Shell Commands"),
            
            // History & Navigation
            ("Command History", "history", "clock.arrow.circlepath", "Shell Commands"),
            ("Clear History", "history -c", "trash", "Shell Commands"),
            ("Previous Command", "!!", "arrow.left", "Shell Commands"),
            
            // Utilities
            ("Calendar", "cal", "calendar", "Shell Commands"),
            ("Date", "date", "clock", "Shell Commands"),
            ("Clear Screen", "clear", "trash", "Shell Commands"),
            ("Echo", "echo", "speaker.wave.2", "Shell Commands"),
            ("Which Command", "which", "magnifyingglass", "Shell Commands"),
            ("Type Command", "type", "info.circle", "Shell Commands"),
            ("Help", "help", "questionmark.circle", "Shell Commands"),
        ]
        
        for shellCmd in shellCommands {
            commands.append(CommandItem(
                title: shellCmd.title,
                subtitle: shellCmd.command,
                icon: shellCmd.icon,
                category: shellCmd.category
            ) {
                if terminalManager.sessions.indices.contains(selectedTab) {
                    let session = terminalManager.sessions[selectedTab]
                    session.runCommand(shellCmd.command)
                }
            })
        }
        
        return commands
    }
    
    private func executeSelectedCommand() {
        guard selectedIndex < filteredCommands.count else { return }
        let command = filteredCommands[selectedIndex]
        command.action()
        isVisible = false
    }
}

// MARK: - Command Palette Row
struct CommandPaletteRow: View {
    let command: CommandPaletteView.CommandItem
    let isSelected: Bool
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: command.icon)
                    .foregroundColor(.blue)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(command.title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    if let subtitle = command.subtitle {
                        Text(subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                Spacer()
                
                Text(command.category)
                    .font(.caption2)
                    .foregroundColor(.secondary)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 4)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .background(isSelected ? Color.blue.opacity(0.1) : Color.clear)
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Additional Notification Names
extension Notification.Name {
    static let selectAllTerminal = Notification.Name("ProTermSelectAllTerminal")
    static let focusCommandInput = Notification.Name("ProTermFocusCommandInput")
    static let showCommandPalette = Notification.Name("ProTermShowCommandPalette")
}

// MARK: - Reactive Tab Item (observes metadata changes)
struct ReactiveTabItem: View {
    let sessionId: UUID
    @ObservedObject var terminalManager: TerminalManager
    
    var body: some View {
        let metadata = terminalManager.getTabMetadata(for: sessionId)
        HStack {
            Circle()
                .fill(metadata.color.color)
                .frame(width: 8, height: 8)
            Text(metadata.name)
        }
        .id("tab-\(sessionId.uuidString)-\(metadata.color.rawValue)-\(terminalManager.tabMetadataVersion)")
    }
}

// MARK: - Tab Context Menu
struct TabContextMenu: View {
    let tabIndex: Int
    @Binding var selectedTab: Int
    @ObservedObject var terminalManager: TerminalManager
    
    var body: some View {
        Group {
            Button("Close Tab") {
                if terminalManager.sessions.count > 1 {
                    terminalManager.closeSession(at: tabIndex)
                    if selectedTab >= terminalManager.sessions.count {
                        selectedTab = max(0, terminalManager.sessions.count - 1)
                    } else if selectedTab > tabIndex {
                        selectedTab -= 1
                    }
                    ToastManager.shared.show("Tab closed", type: .info)
                } else {
                    ToastManager.shared.show("Cannot close last tab", type: .warning)
                }
            }
            .keyboardShortcut("w", modifiers: .command)
            
            Button("Close Other Tabs") {
                terminalManager.closeOtherSessions(except: tabIndex)
                selectedTab = 0
                ToastManager.shared.show("Other tabs closed", type: .info)
            }
            .disabled(terminalManager.sessions.count <= 1)
            
            Button("Close Tabs to the Right") {
                terminalManager.closeSessionsToRight(of: tabIndex)
                ToastManager.shared.show("Tabs to the right closed", type: .info)
            }
            .disabled(tabIndex >= terminalManager.sessions.count - 1)
            
            Divider()
            
            Button("Duplicate Tab") {
                terminalManager.duplicateSession(at: tabIndex)
                selectedTab = terminalManager.sessions.count - 1
                ToastManager.shared.show("Tab duplicated", type: .success)
            }
            
            Divider()
            
            Button("Rename Tab...") {
                // Show rename dialog
                showRenameDialog(for: tabIndex)
            }
            
            Menu("Tab Color") {
                ForEach(TabColor.allCases, id: \.self) { color in
                    Button(action: {
                        if terminalManager.sessions.indices.contains(tabIndex) {
                            let session = terminalManager.sessions[tabIndex]
                            terminalManager.updateTabColor(for: session.id, color: color)
                            ToastManager.shared.show("Tab color changed to \(color.rawValue)", type: .success)
                        }
                    }) {
                        HStack {
                            Text(color.rawValue)
                            if terminalManager.sessions.indices.contains(tabIndex) {
                                let session = terminalManager.sessions[tabIndex]
                                let currentColor = terminalManager.getTabMetadata(for: session.id).color
                                if currentColor == color {
                                    Image(systemName: "checkmark")
                                }
                            }
                        }
                    }
                }
            }
        }
    }
    
    private func showRenameDialog(for index: Int) {
        guard terminalManager.sessions.indices.contains(index) else { return }
        let session = terminalManager.sessions[index]
        let currentName = terminalManager.getTabMetadata(for: session.id).name
        
        let alert = NSAlert()
        alert.messageText = "Rename Tab"
        alert.informativeText = "Enter a new name for this tab:"
        alert.alertStyle = .informational
        alert.addButton(withTitle: "OK")
        alert.addButton(withTitle: "Cancel")
        
        let input = NSTextField(frame: NSRect(x: 0, y: 0, width: 300, height: 24))
        input.stringValue = currentName
        alert.accessoryView = input
        alert.window.initialFirstResponder = input
        
        let response = alert.runModal()
        if response == .alertFirstButtonReturn {
            let newName = input.stringValue.trimmingCharacters(in: .whitespacesAndNewlines)
            if !newName.isEmpty {
                terminalManager.updateTabName(for: session.id, name: newName)
                ToastManager.shared.show("Tab renamed", type: .success)
            }
        }
    }
}

// MARK: - Session Terminal View Wrapper

// MARK: - Tab Button with Drag Support
struct TabButton: View {
    let session: TerminalSession
    let index: Int
    let meta: TabMetadata
    let isSelected: Bool
    let terminalManager: TerminalManager
    let onSelect: () -> Void
    let onMove: (Int, Int) -> Void
    
    @State private var isDragging = false
    @State private var dragOverIndex: Int? = nil
    
    var body: some View {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    // Colored indicator
                    Circle()
                        .fill(meta.color.color)
                        .frame(width: 6, height: 6)
                    Text(meta.name.isEmpty ? "Session \(index + 1)" : meta.name)
                        .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                        .foregroundColor(isSelected ? .primary : .secondary)
                }
                .padding(.vertical, 6)
                .padding(.horizontal, 10)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isSelected ? Color(NSColor.windowBackgroundColor).opacity(0.6) : Color.clear)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: 6)
                        .stroke(isSelected ? Color.accentColor.opacity(0.6) : (dragOverIndex == index ? Color.accentColor.opacity(0.4) : Color.secondary.opacity(0.2)), lineWidth: dragOverIndex == index ? 2 : 1)
                )
                .opacity(isDragging ? 0.5 : 1.0)
                .scaleEffect(isDragging ? 0.95 : 1.0)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Terminal tab: \(meta.name.isEmpty ? "Session \(index + 1)" : meta.name)")
            .accessibilityHint(isSelected ? "Currently selected tab. Drag to reorder tabs." : "Tab \(index + 1). Double-tap to select. Drag to reorder.")
            .accessibilityAddTraits(isSelected ? .isSelected : [])
        .draggable(session.id.uuidString) {
            Text(meta.name.isEmpty ? "Session \(index + 1)" : meta.name)
                .padding(8)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(4)
        }
        .dropDestination(for: String.self) { items, location in
            guard let draggedUUIDString = items.first,
                  let draggedUUID = UUID(uuidString: draggedUUIDString),
                  let draggedIndex = findSessionIndex(uuid: draggedUUID),
                  draggedIndex != index else {
                return false
            }
            onMove(draggedIndex, index)
            return true
        } isTargeted: { targeted in
            dragOverIndex = targeted ? index : nil
        }
        .onDrag {
            isDragging = true
            return NSItemProvider(object: session.id.uuidString as NSString)
        } preview: {
            Text(meta.name.isEmpty ? "Session \(index + 1)" : meta.name)
                .padding(8)
                .background(Color(NSColor.windowBackgroundColor))
                .cornerRadius(4)
        }
        .onChange(of: terminalManager.sessions) { _, _ in
            isDragging = false
            dragOverIndex = nil
        }
    }
    
    private func findSessionIndex(uuid: UUID) -> Int? {
        return terminalManager.sessions.firstIndex(where: { $0.id == uuid })
    }
}

// MARK: – Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(TerminalManager())
            .environmentObject(ThemeManager())
    }
}
