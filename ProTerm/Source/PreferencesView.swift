import SwiftUI
import AppKit
import Combine

struct PreferencesView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var lineNumbersManager: LineNumbersManager
    @EnvironmentObject var fontManager: FontManager
    @EnvironmentObject var advancedFeatures: AdvancedFeatures
    @EnvironmentObject var productivityTools: ProductivityTools
    @EnvironmentObject var aiManager: AIManager

    // Simple enum to drive the segmented picker.
    enum Tab: String, CaseIterable {
        case overview      = "Overview"
        case terminal      = "Terminal"
        case appearance    = "Appearance"
        case font          = "Font"
        case shortcuts     = "Shortcuts"
        case aliases       = "Aliases"
        case prompt        = "Prompt"
        case quickCommands = "Quick Commands"
        case ai            = "AI"
    }

    @State private var selectedTab: Tab = .overview
    // `dismiss` works for sheets; we also provide an explicit close action for the Settings window.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // MARK: – Header with a close button (draggable)
            HStack(spacing: 12) {
                Text("Preferences")
                    .font(.title2)
                    .fontWeight(.bold)
                    .fixedSize() // Prevent text from being squashed
                Spacer()
                Button(action: closeWindow) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
                .fixedSize() // Prevent button from being squashed
            }
            .padding([.top, .horizontal])
            .frame(minHeight: 44) // Ensure header has minimum height
            .contentShape(Rectangle())
            .background(Color(NSColor.controlBackgroundColor).opacity(0.1))

            // MARK: – Segmented picker to switch tabs (no split view)
            VStack(spacing: 8) {
                Picker("Preferences", selection: $selectedTab) {
                    ForEach(Tab.allCases, id: \.self) { tab in
                        Text(tab.rawValue).tag(tab)
                    }
                }
                .pickerStyle(.segmented)
                
                Text("Select a category above to configure different aspects of ProTerm")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal)

            Divider()

            // MARK: – Content for the selected tab
            VStack(alignment: .leading, spacing: 0) {
                // Breadcrumb navigation (only show when not on overview)
                if selectedTab != .overview {
                    HStack {
                        Button("Preferences") {
                            selectedTab = .overview
                        }
                        .font(.caption)
                        .foregroundColor(.blue)
                        .buttonStyle(.plain)
                        
                        Image(systemName: "chevron.right")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                        
                        Text(selectedTab.rawValue)
                            .font(.caption)
                            .foregroundColor(.primary)
                        
                        Spacer()
                    }
                    .padding(.horizontal)
                    .padding(.bottom, 8)
                }
                
                Group {
                    switch selectedTab {
                    case .overview:
                        OverviewSettings(selectedTab: $selectedTab)
                    case .terminal:
                        TerminalPreferencesView()
                    case .appearance:
                        AppearanceSettings()
                    case .font:
                        FontSettings()
                    case .shortcuts:
                        ShortcutSettings()
                    case .aliases:
                        AliasSettings()
                    case .prompt:
                        PromptSettings()
                    case .quickCommands:
                        QuickCommandsSettings()
                    case .ai:
                        AISettings()
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 700, idealWidth: 800, maxWidth: .infinity, 
               minHeight: 500, idealHeight: 600, maxHeight: .infinity)
        .toolbar {
            // Provide a standard macOS "Close" toolbar item – works for Settings windows.
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: closeWindow)
            }
        }
    }

    // Close the Preferences window. Works for both a sheet (`dismiss`) and a Settings window.
    private func closeWindow() {
        // Ask presenter (ButtonBarView) to close the window
        NotificationCenter.default.post(name: .closePreferences, object: nil)
        // Close via window controller if it's a custom window
        if let controller = PreferencesWindowController.shared {
            controller.window?.close()
        }
        dismiss()
    }
}

// MARK: – Appearance pane (theme colours)
struct AppearanceSettings: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var lineNumbersManager: LineNumbersManager
    @State private var useDark = true

    // Store the name of the currently selected preset.
    @State private var selectedPresetName = "Dark"

    // Define a few preset themes (you can expand this list).
    private let presets: [(name: String, theme: Theme)] = [
        ("Dark", Theme(background: .black,
                       foreground: .green,
                       cursor: .white)),
        ("Light", Theme(background: .white,
                        foreground: .black,
                        cursor: .orange)),
        ("Solarized",
         Theme(background: Color(red: 0.0, green: 0.17, blue: 0.21),
               foreground: Color(red: 0.51, green: 0.58, blue: 0.47),
               cursor: .red))
    ]

    var body: some View {
        ScrollView {
            Form {
                // Line numbers toggle
                Toggle("Show Line Numbers", isOn: $lineNumbersManager.showLineNumbers)
                    .onChange(of: lineNumbersManager.showLineNumbers) { _, newValue in
                        lineNumbersManager.setLineNumbers(newValue)
                    }
                
                Divider()
                
                // Dark‑mode toggle (kept for backward compatibility)
                Toggle("Dark Theme", isOn: $useDark)
                    .onChange(of: useDark) { _, newValue in
                        themeManager.current = Theme(
                            background: newValue ? .black : .white,
                            foreground: newValue ? .green : .black,
                            cursor: .orange
                        )
                    }

                // Preset theme picker – uses the preset name (String) which is Hashable.
                Picker("Preset Theme", selection: $selectedPresetName) {
                    ForEach(presets, id: \.name) { entry in
                        Text(entry.name).tag(entry.name)
                    }
                }
                .onChange(of: selectedPresetName) { _, newValue in
                    if let preset = presets.first(where: { $0.name == newValue }) {
                        themeManager.current = preset.theme
                    }
                }
            }
        }
        .onAppear {
            // Initialise the picker to match the current theme if possible.
            if let matching = presets.first(where: {
                $0.theme.background == themeManager.current.background &&
                $0.theme.foreground == themeManager.current.foreground &&
                $0.theme.cursor == themeManager.current.cursor
            }) {
                selectedPresetName = matching.name
            }
        }
    }
}

// MARK: – Font pane (font name + size)
struct FontSettings: View {
    @EnvironmentObject var fontManager: FontManager

    var body: some View {
        // Use a VStack with top alignment so the content stays near the top.
        VStack(alignment: .leading, spacing: 16) {
            // Font picker
            FontPickerView(selectedFontName: $fontManager.fontName)

            // Font size slider
            VStack(alignment: .leading, spacing: 8) {
                Text("Font Size: \(Int(fontManager.fontSize))")
                Slider(value: $fontManager.fontSize, in: 10...24, step: 1) {
                    Text("Font Size")
                }
            }
            .padding(.top, -20) // Move font size controls UP by 20 pixels
        }
        .padding(.top, -20) // Move entire content UP by 20 pixels
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)   // flexible sizing
    }
}

// MARK: – Shortcut pane
struct ShortcutSettings: View {
    @StateObject private var customShortcutsManager = CustomShortcutsManager()
    @State private var showingAddShortcut = false
    @State private var newShortcutName = ""
    @State private var newShortcutKey = ""
    @State private var newShortcutModifiers = ModifierFlags()
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section: Existing Keyboard Shortcuts (Read-only reference)
            GroupBox("Existing Keyboard Shortcuts (Reference)") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(KeyboardShortcutsManager.shortcuts, id: \.description) { shortcut in
                            HStack {
                                Text(shortcut.description)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer()
                                Text(formatShortcut(shortcut))
                                    .font(.system(.body, design: .monospaced))
                                    .foregroundColor(.secondary)
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(4)
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 300)
            }
            
            Divider()
            
            // Section: Custom Shortcuts (for future use)
            GroupBox("Custom Shortcuts") {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Add custom keyboard shortcuts for future features.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if customShortcutsManager.customShortcuts.isEmpty {
                        Text("No custom shortcuts added yet.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .italic()
                    } else {
                        ScrollView {
                            VStack(alignment: .leading, spacing: 8) {
                                ForEach(Array(customShortcutsManager.customShortcuts.enumerated()), id: \.element.id) { index, shortcut in
                                    HStack {
                                        Text(shortcut.name)
                                            .frame(maxWidth: .infinity, alignment: .leading)
                                        Spacer()
                                        Text(formatCustomShortcut(shortcut))
                                            .font(.system(.body, design: .monospaced))
                                            .foregroundColor(.secondary)
                                            .padding(.horizontal, 8)
                                            .padding(.vertical, 4)
                                            .background(Color(NSColor.controlBackgroundColor))
                                            .cornerRadius(4)
                                        Button(action: {
                                            customShortcutsManager.removeShortcut(shortcut)
                                        }) {
                                            Image(systemName: "trash")
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.plain)
                                    }
                                    .padding(.vertical, 2)
                                }
                            }
                            .padding()
                        }
                        .frame(maxHeight: 200)
                    }
                    
                    Button(action: {
                        showingAddShortcut = true
                    }) {
                        HStack {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Custom Shortcut")
                        }
                    }
                    .buttonStyle(.borderedProminent)
                }
                .padding()
            }
        }
        .padding()
        .sheet(isPresented: $showingAddShortcut) {
            AddShortcutSheet(
                name: $newShortcutName,
                key: $newShortcutKey,
                modifiers: $newShortcutModifiers,
                onSave: {
                    customShortcutsManager.addShortcut(
                        name: newShortcutName,
                        key: newShortcutKey,
                        modifiers: newShortcutModifiers.toEventModifiers()
                    )
                    newShortcutName = ""
                    newShortcutKey = ""
                    newShortcutModifiers = ModifierFlags()
                    newShortcutModifiers.command = true
                    showingAddShortcut = false
                },
                onCancel: {
                    newShortcutName = ""
                    newShortcutKey = ""
                    newShortcutModifiers = ModifierFlags()
                    newShortcutModifiers.command = true
                    showingAddShortcut = false
                }
            )
        }
    }
    
    private func formatShortcut(_ shortcut: KeyboardShortcutsManager.Shortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.contains(.command) { parts.append("⌘") }
        if shortcut.modifiers.contains(.shift) { parts.append("⇧") }
        if shortcut.modifiers.contains(.option) { parts.append("⌥") }
        if shortcut.modifiers.contains(.control) { parts.append("⌃") }
        parts.append(shortcut.key.character.uppercased())
        return parts.joined(separator: "")
    }
    
    private func formatCustomShortcut(_ shortcut: CustomShortcutsManager.CustomShortcut) -> String {
        var parts: [String] = []
        if shortcut.modifiers.command { parts.append("⌘") }
        if shortcut.modifiers.shift { parts.append("⇧") }
        if shortcut.modifiers.option { parts.append("⌥") }
        if shortcut.modifiers.control { parts.append("⌃") }
        parts.append(shortcut.key.uppercased())
        return parts.joined(separator: "")
    }
}

// MARK: - Modifier Flags (Codable wrapper for EventModifiers)
struct ModifierFlags: Codable {
    var command: Bool = false
    var shift: Bool = false
    var option: Bool = false
    var control: Bool = false
    
    func toEventModifiers() -> EventModifiers {
        var modifiers: EventModifiers = []
        if command { modifiers.insert(.command) }
        if shift { modifiers.insert(.shift) }
        if option { modifiers.insert(.option) }
        if control { modifiers.insert(.control) }
        return modifiers
    }
    
    static func fromEventModifiers(_ modifiers: EventModifiers) -> ModifierFlags {
        var flags = ModifierFlags()
        flags.command = modifiers.contains(.command)
        flags.shift = modifiers.contains(.shift)
        flags.option = modifiers.contains(.option)
        flags.control = modifiers.contains(.control)
        return flags
    }
}

// MARK: - Custom Shortcuts Manager
class CustomShortcutsManager: ObservableObject {
    @Published var customShortcuts: [CustomShortcut] = []
    
    struct CustomShortcut: Identifiable, Codable {
        let id: UUID
        var name: String
        var key: String
        var modifiers: ModifierFlags
        
        init(id: UUID = UUID(), name: String, key: String, modifiers: EventModifiers) {
            self.id = id
            self.name = name
            self.key = key
            self.modifiers = ModifierFlags.fromEventModifiers(modifiers)
        }
    }
    
    private let defaultsKey = "ProTermCustomShortcuts"
    
    init() {
        loadShortcuts()
    }
    
    func addShortcut(name: String, key: String, modifiers: EventModifiers) {
        guard !name.isEmpty, !key.isEmpty else { return }
        let shortcut = CustomShortcut(name: name, key: key, modifiers: modifiers)
        customShortcuts.append(shortcut)
        saveShortcuts()
    }
    
    func removeShortcut(_ shortcut: CustomShortcut) {
        customShortcuts.removeAll { $0.id == shortcut.id }
        saveShortcuts()
    }
    
    private func saveShortcuts() {
        if let encoded = try? JSONEncoder().encode(customShortcuts) {
            UserDefaults.standard.set(encoded, forKey: defaultsKey)
        }
    }
    
    private func loadShortcuts() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode([CustomShortcut].self, from: data) {
            customShortcuts = decoded
        }
    }
}

// MARK: - Add Shortcut Sheet
struct AddShortcutSheet: View {
    @Binding var name: String
    @Binding var key: String
    @Binding var modifiers: ModifierFlags
    let onSave: () -> Void
    let onCancel: () -> Void
    @FocusState private var nameFocused: Bool
    @FocusState private var keyFocused: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add Custom Shortcut")
                .font(.title2)
                .fontWeight(.bold)
            
            Text("Note: Custom shortcuts are stored for reference only and will be implemented in future updates.")
                .font(.caption)
                    .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Shortcut Name")
                    .font(.headline)
                TextField("e.g., Open Settings", text: $name)
                    .focused($nameFocused)
                    .textFieldStyle(.roundedBorder)
                
                Text("Key")
                    .font(.headline)
                TextField("e.g., s", text: $key)
                    .focused($keyFocused)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: key) { oldValue, newValue in
                        // Limit to single character
                        if newValue.count > 1 {
                            key = String(newValue.last ?? Character(""))
                        }
                    }
                
                Text("Modifiers")
                    .font(.headline)
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Command (⌘)", isOn: $modifiers.command)
                    Toggle("Shift (⇧)", isOn: $modifiers.shift)
                    Toggle("Option (⌥)", isOn: $modifiers.option)
                    Toggle("Control (⌃)", isOn: $modifiers.control)
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Save", action: onSave)
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || key.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 400, height: 400)
        .onAppear {
            nameFocused = true
        }
    }
}

// MARK: – Overview Settings
struct OverviewSettings: View {
    @Binding var selectedTab: PreferencesView.Tab
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("ProTerm Preferences")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Configure different aspects of your terminal experience.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            ScrollView {
                VStack(spacing: 12) {
                    PreferenceCard(
                        title: "Terminal",
                        description: "Shell selection and terminal behavior",
                        icon: "terminal.fill",
                        color: .blue
                    ) {
                        selectedTab = .terminal
                    }
                    
                    PreferenceCard(
                        title: "Appearance",
                        description: "Themes, colors, and visual settings",
                        icon: "paintbrush.fill",
                        color: .purple
                    ) {
                        selectedTab = .appearance
                    }
                    
                    PreferenceCard(
                        title: "Font",
                        description: "Text size, family, and formatting",
                        icon: "textformat",
                        color: .green
                    ) {
                        selectedTab = .font
                    }
                    
                    PreferenceCard(
                        title: "Shortcuts",
                        description: "Keyboard shortcuts and hotkeys",
                        icon: "command",
                        color: .orange
                    ) {
                        selectedTab = .shortcuts
                    }
                    
                    PreferenceCard(
                        title: "Aliases",
                        description: "Command aliases and shortcuts",
                        icon: "link",
                        color: .cyan
                    ) {
                        selectedTab = .aliases
                    }
                    
                    PreferenceCard(
                        title: "Prompt",
                        description: "Customize terminal prompt",
                        icon: "text.cursor",
                        color: .indigo
                    ) {
                        selectedTab = .prompt
                    }
                    
                    PreferenceCard(
                        title: "Quick Commands",
                        description: "Manage quick commands by category",
                        icon: "bolt.fill",
                        color: .yellow
                    ) {
                        selectedTab = .quickCommands
                    }
                    
                    PreferenceCard(
                        title: "AI",
                        description: "Configure AI assistant (Siri or LM Studio)",
                        icon: "sparkles",
                        color: .pink
                    ) {
                        selectedTab = .ai
                    }
                }
                .padding(.vertical, 4) // Add some padding for better scrolling
            }
            .frame(maxHeight: .infinity)
        }
    }
}

// MARK: – Preference Card
struct PreferenceCard: View {
    let title: String
    let description: String
    let icon: String
    let color: Color
    let action: () -> Void
    
    var body: some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon)
                    .font(.title2)
                    .foregroundColor(color)
                    .frame(width: 24)
                
                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.headline)
                        .foregroundColor(.primary)
                    
                    Text(description)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                
                Spacer()
                
                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }
}

// MARK: – Alias Settings
struct AliasSettings: View {
    @EnvironmentObject var advancedFeatures: AdvancedFeatures
    @State private var aliasName: String = ""
    @State private var aliasCommand: String = ""
    @State private var editingAlias: String? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Command Aliases")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Create shortcuts for frequently used commands. For example, 'll' can expand to 'ls -la'.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider()
            
            // Add/Edit alias form
            VStack(alignment: .leading, spacing: 12) {
                Text(editingAlias == nil ? "Add New Alias" : "Edit Alias")
                    .font(.headline)
                
                HStack {
                    TextField("Alias name (e.g., ll)", text: $aliasName)
                        .textFieldStyle(.roundedBorder)
                        .disabled(editingAlias != nil)
                    
                    TextField("Command (e.g., ls -la)", text: $aliasCommand)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    if editingAlias != nil {
                        Button("Cancel") {
                            editingAlias = nil
                            aliasName = ""
                            aliasCommand = ""
                        }
                        .buttonStyle(.bordered)
                    }
                    
                    Button(editingAlias == nil ? "Add" : "Update") {
                        if !aliasName.isEmpty && !aliasCommand.isEmpty {
                            if let oldName = editingAlias, oldName != aliasName {
                                // Name changed, remove old and add new
                                advancedFeatures.removeAlias(name: oldName)
                            }
                            advancedFeatures.addAlias(name: aliasName, command: aliasCommand)
                            aliasName = ""
                            aliasCommand = ""
                            editingAlias = nil
                        }
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(aliasName.isEmpty || aliasCommand.isEmpty)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            Divider()
            
            // List of aliases
            VStack(alignment: .leading, spacing: 8) {
                Text("Current Aliases")
                    .font(.headline)
                
                if advancedFeatures.aliases.isEmpty {
                    Text("No aliases defined")
                        .foregroundColor(.secondary)
                        .padding()
                } else {
                    ScrollView {
                        VStack(spacing: 8) {
                            ForEach(Array(advancedFeatures.aliases.keys.sorted()), id: \.self) { key in
                                HStack {
                                    VStack(alignment: .leading, spacing: 4) {
                                        Text(key)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Text(advancedFeatures.aliases[key] ?? "")
                                            .font(.caption)
                                            .foregroundColor(.secondary)
                                    }
                                    
                                    Spacer()
                                    
                                    Button("Edit") {
                                        editingAlias = key
                                        aliasName = key
                                        aliasCommand = advancedFeatures.aliases[key] ?? ""
                                    }
                                    .buttonStyle(.bordered)
                                    
                                    Button("Delete") {
                                        advancedFeatures.removeAlias(name: key)
                                    }
                                    .buttonStyle(.bordered)
                                    .foregroundColor(.red)
                                }
                                .padding()
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(8)
                            }
                        }
                    }
                }
            }
        }
        .padding()
    }
}

// MARK: – Prompt Settings
struct PromptSettings: View {
    @AppStorage("ProTermCustomPrompt") private var customPrompt: String = ""
    @AppStorage("ProTermUseCustomPrompt") private var useCustomPrompt: Bool = false
    @State private var previewPrompt: String = ""
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Custom Prompt")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Customize your terminal prompt. Use %u for username, %h for hostname, %d for directory, %b for git branch.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider()
            
            Toggle("Use Custom Prompt", isOn: $useCustomPrompt)
            
            if useCustomPrompt {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Prompt Format:")
                        .font(.headline)
                    
                    TextField("Enter prompt format", text: $customPrompt)
                        .textFieldStyle(.roundedBorder)
                        .onChange(of: customPrompt) { _, _ in
                            updatePreview()
                        }
                    
                    Text("Available variables:")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    VStack(alignment: .leading, spacing: 4) {
                        Text("• %u - Username")
                        Text("• %h - Hostname")
                        Text("• %d - Current directory")
                        Text("• %b - Git branch (if in git repo)")
                    }
                    .font(.caption)
                    .foregroundColor(.secondary)
                    
                    Divider()
                    
                    Text("Preview:")
                        .font(.headline)
                    
                    Text(previewPrompt.isEmpty ? "No preview" : previewPrompt)
                        .font(.system(.body, design: .monospaced))
                        .padding()
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(6)
                }
            }
        }
        .padding()
        .onAppear {
            updatePreview()
        }
    }
    
    private func updatePreview() {
        if useCustomPrompt && !customPrompt.isEmpty {
            let user = NSUserName()
            let host = Host.current().localizedName ?? ProcessInfo.processInfo.hostName
            let homePath = FileManager.default.homeDirectoryForCurrentUser.path
            var displayPath = homePath.replacingOccurrences(of: homePath, with: "~")
            if displayPath.isEmpty { displayPath = "~" }
            
            previewPrompt = customPrompt
                .replacingOccurrences(of: "%u", with: user)
                .replacingOccurrences(of: "%h", with: host)
                .replacingOccurrences(of: "%d", with: displayPath)
                .replacingOccurrences(of: "%b", with: "[main]")
        } else {
            previewPrompt = ""
        }
    }
}

// MARK: – Quick Commands Settings
struct QuickCommandsSettings: View {
    @EnvironmentObject var productivityTools: ProductivityTools
    @State private var commandName: String = ""
    @State private var commandText: String = ""
    @State private var commandDescription: String = ""
    @State private var selectedCategory: ProductivityTools.QuickCommand.QuickCommandCategory = .custom
    @State private var commandIcon: String = "terminal"
    @State private var requiresKeyword: Bool = false
    @State private var keywordPlaceholder: String = ""
    @State private var editingCommand: ProductivityTools.QuickCommand? = nil
    @State private var selectedCategoryFilter: ProductivityTools.QuickCommand.QuickCommandCategory? = nil
    
    var filteredCommands: [ProductivityTools.QuickCommand] {
        if let filter = selectedCategoryFilter {
            return productivityTools.quickCommands.filter { $0.category == filter }
        }
        return productivityTools.quickCommands
    }
    
    var commandsByCategory: [ProductivityTools.QuickCommand.QuickCommandCategory: [ProductivityTools.QuickCommand]] {
        Dictionary(grouping: filteredCommands) { $0.category }
    }
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Quick Commands")
                    .font(.title2)
                    .fontWeight(.semibold)
                
                Text("Create and manage quick commands organized by category. These commands appear in the Quick Commands panel.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                
                Divider()
                
                // Category filter
                VStack(alignment: .leading, spacing: 8) {
                    Text("Filter by Category")
                        .font(.headline)
                    
                    Picker("Category", selection: $selectedCategoryFilter) {
                        Text("All Categories").tag(nil as ProductivityTools.QuickCommand.QuickCommandCategory?)
                        ForEach(ProductivityTools.QuickCommand.QuickCommandCategory.allCases, id: \.self) { category in
                            Text(category.rawValue).tag(category as ProductivityTools.QuickCommand.QuickCommandCategory?)
                        }
                    }
                    .pickerStyle(.menu)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                Divider()
                
                // Add/Edit form
                VStack(alignment: .leading, spacing: 12) {
                    Text(editingCommand == nil ? "Add New Quick Command" : "Edit Quick Command")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Name:")
                        TextField("Command name (e.g., List All)", text: $commandName)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Command:")
                        TextField("Command to execute (e.g., ls -la)", text: $commandText)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Description (optional):")
                        TextField("Description", text: $commandDescription)
                            .textFieldStyle(.roundedBorder)
                    }
                    
                    HStack(spacing: 12) {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Category:")
                            Picker("Category", selection: $selectedCategory) {
                                ForEach(ProductivityTools.QuickCommand.QuickCommandCategory.allCases, id: \.self) { category in
                                    Text(category.rawValue).tag(category)
                                }
                            }
                            .pickerStyle(.menu)
                            .frame(maxWidth: 200)
                        }
                        
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Icon:")
                            HStack(spacing: 8) {
                                TextField("SF Symbol name", text: $commandIcon)
                                    .textFieldStyle(.roundedBorder)
                                    .frame(maxWidth: 200)
                                
                                // Icon preview
                                if !commandIcon.isEmpty {
                                    Image(systemName: commandIcon)
                                        .foregroundColor(.blue)
                                        .frame(width: 24, height: 24)
                                } else {
                                    Image(systemName: "questionmark.circle")
                                        .foregroundColor(.gray)
                                        .frame(width: 24, height: 24)
                                }
                            }
                            
                            // Common icon suggestions
                            Text("Common icons: terminal, command, bolt, gear, folder, document, list.bullet, arrow.triangle.branch, cube.box, shippingbox")
                                .font(.caption2)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    // Keyword requirement option
                    VStack(alignment: .leading, spacing: 8) {
                        Toggle("Requires additional input (e.g., cd needs directory name)", isOn: $requiresKeyword)
                        
                        if requiresKeyword {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("Input placeholder:")
                                TextField("e.g., directory name, file name, branch name", text: $keywordPlaceholder)
                                    .textFieldStyle(.roundedBorder)
                                
                                Text("When enabled, clicking this command will prompt for input before executing.")
                                    .font(.caption2)
                                    .foregroundColor(.secondary)
                            }
                            .padding(.leading, 20)
                        }
                    }
                    
                    HStack {
                        if editingCommand != nil {
                            Button("Cancel") {
                                resetForm()
                            }
                            .buttonStyle(.bordered)
                        }
                        
                        Button(editingCommand == nil ? "Add" : "Update") {
                            saveCommand()
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(commandName.isEmpty || commandText.isEmpty)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                
                Divider()
                
                // Commands list grouped by category
                VStack(alignment: .leading, spacing: 16) {
                    Text("Quick Commands")
                        .font(.headline)
                    
                    if filteredCommands.isEmpty {
                        Text("No quick commands defined")
                            .foregroundColor(.secondary)
                            .padding()
                    } else {
                        ForEach(Array(commandsByCategory.keys.sorted(by: { $0.rawValue < $1.rawValue })), id: \.self) { category in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(category.rawValue)
                                    .font(.headline)
                                    .foregroundColor(.primary)
                                    .padding(.top, 8)
                                
                                ForEach(commandsByCategory[category] ?? []) { command in
                                    HStack {
                                        Image(systemName: command.icon)
                                            .foregroundColor(.blue)
                                            .frame(width: 20)
                                        
                                        VStack(alignment: .leading, spacing: 4) {
                                            Text(command.name)
                                                .font(.subheadline)
                                                .foregroundColor(.primary)
                                            
                                            if let desc = command.description, !desc.isEmpty {
                                                Text(desc)
                                                    .font(.caption)
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            Text(command.command)
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                                .fontDesign(.monospaced)
                                        }
                                        
                                        Spacer()
                                        
                                        HStack(spacing: 4) {
                                            if command.requiresKeyword {
                                                Image(systemName: "text.cursor")
                                                    .font(.caption2)
                                                    .foregroundColor(.orange)
                                                    .help("Requires input")
                                            }
                                            
                                            if let lastUsed = command.lastUsed {
                                                Text("Used: \(formatDate(lastUsed))")
                                                    .font(.caption2)
                                                    .foregroundColor(.secondary)
                                            }
                                            
                                            Text("(\(command.usageCount))")
                                                .font(.caption2)
                                                .foregroundColor(.secondary)
                                        }
                                        
                                        Button("Edit") {
                                            editCommand(command)
                                        }
                                        .buttonStyle(.bordered)
                                        
                                        Button("Delete") {
                                            productivityTools.removeQuickCommand(command)
                                        }
                                        .buttonStyle(.bordered)
                                        .foregroundColor(.red)
                                    }
                                    .padding()
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(8)
                                }
                            }
                        }
                    }
                }
            }
            .padding()
        }
    }
    
    private func saveCommand() {
        if let editing = editingCommand {
            var updated = editing
            updated.name = commandName
            updated.command = commandText
            updated.description = commandDescription.isEmpty ? nil : commandDescription
            updated.category = selectedCategory
            updated.icon = commandIcon
            updated.requiresKeyword = requiresKeyword
            updated.keywordPlaceholder = requiresKeyword && !keywordPlaceholder.isEmpty ? keywordPlaceholder : nil
            productivityTools.updateQuickCommand(updated)
        } else {
            productivityTools.addQuickCommand(
                name: commandName,
                command: commandText,
                description: commandDescription.isEmpty ? nil : commandDescription,
                category: selectedCategory,
                icon: commandIcon,
                requiresKeyword: requiresKeyword,
                keywordPlaceholder: requiresKeyword && !keywordPlaceholder.isEmpty ? keywordPlaceholder : nil
            )
        }
        resetForm()
    }
    
    private func editCommand(_ command: ProductivityTools.QuickCommand) {
        editingCommand = command
        commandName = command.name
        commandText = command.command
        commandDescription = command.description ?? ""
        selectedCategory = command.category
        commandIcon = command.icon
        requiresKeyword = command.requiresKeyword
        keywordPlaceholder = command.keywordPlaceholder ?? ""
    }
    
    private func resetForm() {
        editingCommand = nil
        commandName = ""
        commandText = ""
        commandDescription = ""
        selectedCategory = .custom
        commandIcon = "terminal"
        requiresKeyword = false
        keywordPlaceholder = ""
    }
    
    private func formatDate(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateStyle = .short
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}

// MARK: – AI Settings
struct AISettings: View {
    @EnvironmentObject var aiManager: AIManager
    @State private var localSelectedAI: AIManager.AIType = .siri
    @State private var editingURL: String = ""
    @State private var editingModel: String = ""
    @State private var modelDebounceWorkItem: DispatchWorkItem? = nil
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("AI Assistant Configuration")
                .font(.title2)
                .fontWeight(.semibold)
            
            Text("Choose your AI assistant and configure connection settings.")
                .font(.subheadline)
                .foregroundColor(.secondary)
            
            Divider()
            
            // AI Type Selection
            VStack(alignment: .leading, spacing: 12) {
                Text("AI Provider")
                    .font(.headline)
                
                Picker("AI Provider", selection: $localSelectedAI) {
                    Text("Siri").tag(AIManager.AIType.siri)
                    Text("LM Studio").tag(AIManager.AIType.lmStudio)
                }
                .pickerStyle(.segmented)
                .onChange(of: localSelectedAI) { oldValue, newValue in
                    if oldValue != newValue {
                        aiManager.selectedAI = newValue
                        UserDefaults.standard.set(newValue.rawValue, forKey: "selectedAI")
                    }
                }
                
                Text(localSelectedAI.description)
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .cornerRadius(8)
            
            // LM Studio Configuration
            if localSelectedAI == .lmStudio {
                VStack(alignment: .leading, spacing: 12) {
                    Text("LM Studio Configuration")
                        .font(.headline)
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Server URL:")
                        TextField("http://localhost:1234", text: $editingURL)
                            .textFieldStyle(.roundedBorder)
                        Text("The URL where LM Studio is running (default: http://localhost:1234)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Model Name (optional):")
                        TextField("Model name", text: $editingModel)
                            .textFieldStyle(.roundedBorder)
                            // Debounce model name changes:
                            .onChange(of: editingModel) {
                                modelDebounceWorkItem?.cancel()
                                let workItem = DispatchWorkItem {
                                    if editingModel != aiManager.lmStudioModel {
                                        aiManager.lmStudioModel = editingModel
                                        UserDefaults.standard.set(editingModel, forKey: "lmStudioModel")
                                    }
                                }
                                modelDebounceWorkItem = workItem
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.3, execute: workItem)
                            }
                        Text("Specify a model name if you want to use a specific model")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            // Siri Information
            if localSelectedAI == .siri {
                VStack(alignment: .leading, spacing: 8) {
                    HStack {
                        Image(systemName: "info.circle")
                            .foregroundColor(.blue)
                        Text("Siri Integration")
                            .font(.headline)
                    }
                    
                    Text("Siri uses Apple's built-in voice assistant. Make sure Siri is enabled in System Settings.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
            }
            
            Spacer()
        }
        .padding()
        .onAppear {
            localSelectedAI = aiManager.selectedAI
            editingURL = aiManager.lmStudioURL
            editingModel = aiManager.lmStudioModel
        }
        .onDisappear {
            // Cancel pending debounce and immediately save model if changed
            if let workItem = modelDebounceWorkItem {
                workItem.cancel()
                if editingModel != aiManager.lmStudioModel {
                    aiManager.lmStudioModel = editingModel
                    UserDefaults.standard.set(editingModel, forKey: "lmStudioModel")
                }
                modelDebounceWorkItem = nil
            }
            saveURL()
        }
    }
    
    private func saveURL() {
        guard editingURL != aiManager.lmStudioURL else { return }
        aiManager.lmStudioURL = editingURL
        UserDefaults.standard.set(editingURL, forKey: "lmStudioURL")
    }
}

// MARK: – Previews
struct PreferencesView_Previews: PreviewProvider {
    static var previews: some View {
        PreferencesView()
            .environmentObject(TerminalManager())
            .environmentObject(ThemeManager())
    }
}
