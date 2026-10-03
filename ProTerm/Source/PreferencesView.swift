import SwiftUI
import AppKit
import Combine
import UniformTypeIdentifiers

struct PreferencesView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var fontManager: FontManager
    @EnvironmentObject var advancedFeatures: AdvancedFeatures
    @EnvironmentObject var productivityTools: ProductivityTools
    @EnvironmentObject var integrationFeatures: IntegrationFeatures
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
        case templates     = "Templates"
        case workspaces    = "Workspaces"
        case plugins       = "Plugins"
        case filters       = "Filters"
        case ssh           = "SSH"
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
                    case .templates:
                        TemplateSettings()
                    case .workspaces:
                        WorkspaceSettings()
                    case .plugins:
                        PluginSettings()
                    case .filters:
                        FilterSettings()
                    case .ssh:
                        SSHConnectionSettings()
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
    var body: some View {
        ScrollView {
            AppearanceProfileSection()
        }
    }
}

// MARK: – Font pane (font name + size)
struct FontSettings: View {
    @EnvironmentObject var fontManager: FontManager
    @EnvironmentObject var themeManager: ThemeManager

    var body: some View {
        // Use a VStack with top alignment so the content stays near the top.
        VStack(alignment: .leading, spacing: 16) {
            // Font picker
            FontPickerView(selectedFontName: $fontManager.fontName)
                .onChange(of: fontManager.fontName) { _, newValue in
                    if themeManager.activeProfile.fontName != newValue {
                        themeManager.updateActiveProfileFontAsync(name: newValue)
                    }
                }

            // Font size slider
            VStack(alignment: .leading, spacing: 8) {
                Text("Font Size: \(Int(fontManager.fontSize))")
                Slider(value: $fontManager.fontSize, in: 10...24, step: 1) {
                    Text("Font Size")
                }
                .onChange(of: fontManager.fontSize) { _, newValue in
                    if themeManager.activeProfile.fontSize != newValue {
                        themeManager.updateActiveProfileFontAsync(size: newValue)
                    }
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
    @EnvironmentObject var keyboardShortcutsManager: KeyboardShortcutsManager
    @StateObject private var customShortcutsManager = CustomShortcutsManager()
    @State private var showingAddShortcut = false
    @State private var newShortcutName = ""
    @State private var newShortcutKey = ""
    @State private var newShortcutModifiers = ModifierFlags()
    @State private var editingAction: KeyboardShortcutsManager.Action?
    @State private var showingEditSheet = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // Section: Keyboard Shortcuts (Editable)
            GroupBox("Keyboard Shortcuts") {
                ScrollView {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(KeyboardShortcutsManager.shortcuts, id: \.description) { shortcut in
                            HStack {
                                Text(shortcut.description)
                                    .frame(maxWidth: .infinity, alignment: .leading)
                                Spacer()
                                
                                // Show current binding (custom or default)
                                let (currentKey, currentModifiers) = keyboardShortcutsManager.getShortcut(for: shortcut.action)
                                let isCustom = keyboardShortcutsManager.hasCustomShortcut(for: shortcut.action)
                                
                                HStack(spacing: 4) {
                                    if isCustom {
                                        Image(systemName: "pencil.circle.fill")
                                            .foregroundColor(.blue)
                                            .font(.caption)
                                    }
                                    Text(formatShortcut(key: currentKey, modifiers: currentModifiers))
                                        .font(.system(.body, design: .monospaced))
                                        .foregroundColor(isCustom ? .blue : .secondary)
                                        .padding(.horizontal, 8)
                                        .padding(.vertical, 4)
                                        .background(Color(NSColor.controlBackgroundColor))
                                        .cornerRadius(4)
                                }
                                
                                Button(action: {
                                    editingAction = shortcut.action
                                    showingEditSheet = true
                                }) {
                                    Text("Edit")
                                }
                                .buttonStyle(.bordered)
                                
                                if isCustom {
                                    Button(action: {
                                        keyboardShortcutsManager.resetShortcut(for: shortcut.action)
                                    }) {
                                        Text("Reset")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                            .padding(.vertical, 2)
                        }
                    }
                    .padding()
                }
                .frame(maxHeight: 300)
                
                HStack {
                    Spacer()
                    Button("Reset All to Defaults") {
                        keyboardShortcutsManager.resetAllShortcuts()
                    }
                    .buttonStyle(.bordered)
                }
                .padding(.horizontal)
                .padding(.bottom, 8)
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
        .sheet(isPresented: $showingEditSheet) {
            if let action = editingAction {
                EditShortcutSheet(
                    action: action,
                    keyboardShortcutsManager: keyboardShortcutsManager,
                    onSave: {
                        showingEditSheet = false
                        editingAction = nil
                    },
                    onCancel: {
                        showingEditSheet = false
                        editingAction = nil
                    }
                )
            }
        }
    }
    
    private func formatShortcut(key: KeyEquivalent, modifiers: EventModifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        parts.append(key.character.uppercased())
        return parts.joined(separator: "")
    }
    
    private func formatShortcut(_ shortcut: KeyboardShortcutsManager.Shortcut) -> String {
        formatShortcut(key: shortcut.key, modifiers: shortcut.modifiers)
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

// MARK: - Edit Shortcut Sheet
struct EditShortcutSheet: View {
    let action: KeyboardShortcutsManager.Action
    @ObservedObject var keyboardShortcutsManager: KeyboardShortcutsManager
    let onSave: () -> Void
    let onCancel: () -> Void
    
    @State private var capturedKey: KeyEquivalent?
    @State private var capturedModifiers: EventModifiers = []
    @State private var isRecording: Bool = false
    @State private var conflictMessage: String?
    @State private var eventMonitor: Any?
    
    private var actionDescription: String {
        if let shortcut = KeyboardShortcutsManager.shortcuts.first(where: { $0.action.identifier == action.identifier }) {
            return shortcut.description
        }
        return "Unknown Action"
    }
    
    private var currentShortcut: (key: KeyEquivalent, modifiers: EventModifiers) {
        keyboardShortcutsManager.getShortcut(for: action)
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Edit Keyboard Shortcut")
                .font(.title2)
                .fontWeight(.bold)
            
            Text(actionDescription)
                .font(.headline)
                .foregroundColor(.secondary)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Current Shortcut")
                    .font(.headline)
                
                let (currentKey, currentMods) = currentShortcut
                Text(formatShortcut(key: currentKey, modifiers: currentMods))
                    .font(.system(.body, design: .monospaced))
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(4)
                
                Divider()
                
                Text("New Shortcut")
                    .font(.headline)
                
                HStack {
                    Text(capturedKey != nil ? formatShortcut(key: capturedKey!, modifiers: capturedModifiers) : "Press Record and type your shortcut")
                        .font(.system(.body, design: .monospaced))
                        .foregroundColor(capturedKey != nil ? .primary : .secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(Color(NSColor.controlBackgroundColor))
                        .cornerRadius(4)
                    
                    Button(action: {
                        if isRecording {
                            stopRecording()
                        } else {
                            startRecording()
                        }
                    }) {
                        Text(isRecording ? "Stop Recording" : "Record")
                    }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                }
                
                if isRecording {
                    Text("Press the key combination you want to use...")
                        .font(.caption)
                        .foregroundColor(.blue)
                }
                
                if let conflict = conflictMessage {
                    Text(conflict)
                        .font(.caption)
                        .foregroundColor(.red)
                }
                
                Text("Modifiers")
                    .font(.headline)
                    .padding(.top, 8)
                
                VStack(alignment: .leading, spacing: 8) {
                    Toggle("Command (⌘)", isOn: Binding(
                        get: { capturedModifiers.contains(.command) },
                        set: { if $0 { capturedModifiers.insert(.command) } else { capturedModifiers.remove(.command) } }
                    ))
                    .disabled(isRecording)
                    
                    Toggle("Shift (⇧)", isOn: Binding(
                        get: { capturedModifiers.contains(.shift) },
                        set: { if $0 { capturedModifiers.insert(.shift) } else { capturedModifiers.remove(.shift) } }
                    ))
                    .disabled(isRecording)
                    
                    Toggle("Option (⌥)", isOn: Binding(
                        get: { capturedModifiers.contains(.option) },
                        set: { if $0 { capturedModifiers.insert(.option) } else { capturedModifiers.remove(.option) } }
                    ))
                    .disabled(isRecording)
                    
                    Toggle("Control (⌃)", isOn: Binding(
                        get: { capturedModifiers.contains(.control) },
                        set: { if $0 { capturedModifiers.insert(.control) } else { capturedModifiers.remove(.control) } }
                    ))
                    .disabled(isRecording)
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel", action: {
                    stopRecording()
                    onCancel()
                })
                    .keyboardShortcut(.escape)
                Button("Save", action: {
                    if let key = capturedKey {
                        checkConflict(key: key, modifiers: capturedModifiers) { hasConflict in
                            if !hasConflict {
                                keyboardShortcutsManager.updateShortcut(for: action, key: key, modifiers: capturedModifiers)
                                stopRecording()
                                onSave()
                            }
                        }
                    } else {
                        onSave()
                    }
                })
                    .buttonStyle(.borderedProminent)
                    .disabled(capturedKey == nil || capturedModifiers.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 500, height: 500)
        .onAppear {
            let (key, mods) = currentShortcut
            capturedKey = key
            capturedModifiers = mods
        }
        .onDisappear {
            stopRecording()
        }
    }
    
    private func startRecording() {
        isRecording = true
        conflictMessage = nil
        capturedKey = nil
        capturedModifiers = []
        
        // Set up event monitor
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { event in
            guard isRecording else { return event }
            
            let modifiers = event.modifierFlags
            var eventModifiers: EventModifiers = []
            if modifiers.contains(.command) { eventModifiers.insert(.command) }
            if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
            if modifiers.contains(.option) { eventModifiers.insert(.option) }
            if modifiers.contains(.control) { eventModifiers.insert(.control) }
            
            // Get the key character
            let keyChar: Character?
            if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
                keyChar = chars.first
            } else {
                switch event.keyCode {
                case 0: keyChar = "a"
                case 1: keyChar = "s"
                case 2: keyChar = "d"
                case 3: keyChar = "f"
                case 4: keyChar = "h"
                case 5: keyChar = "g"
                case 6: keyChar = "z"
                case 7: keyChar = "x"
                case 8: keyChar = "c"
                case 9: keyChar = "v"
                case 11: keyChar = "b"
                case 12: keyChar = "q"
                case 13: keyChar = "w"
                case 14: keyChar = "e"
                case 15: keyChar = "r"
                case 16: keyChar = "y"
                case 17: keyChar = "t"
                case 31: keyChar = "o"
                case 32: keyChar = "u"
                case 34: keyChar = "i"
                case 35: keyChar = "p"
                case 37: keyChar = "l"
                case 38: keyChar = "j"
                case 40: keyChar = "k"
                case 45: keyChar = "n"
                case 46: keyChar = "m"
                case 18: keyChar = "1"
                case 19: keyChar = "2"
                case 20: keyChar = "3"
                case 21: keyChar = "4"
                case 23: keyChar = "5"
                case 22: keyChar = "6"
                case 26: keyChar = "7"
                case 28: keyChar = "8"
                case 25: keyChar = "9"
                default: keyChar = nil
                }
            }
            
            if let char = keyChar, !eventModifiers.isEmpty {
                DispatchQueue.main.async {
                    self.capturedKey = KeyEquivalent(char)
                    self.capturedModifiers = eventModifiers
                    self.stopRecording()
                }
                return nil // Consume the event
            }
            
            return event
        }
    }
    
    private func stopRecording() {
        isRecording = false
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
            eventMonitor = nil
        }
    }
    
    private func checkConflict(key: KeyEquivalent, modifiers: EventModifiers, completion: @escaping (Bool) -> Void) {
        // Check against all shortcuts except the current one
        for shortcut in KeyboardShortcutsManager.shortcuts {
            if shortcut.action.identifier != action.identifier {
                let (otherKey, otherMods) = keyboardShortcutsManager.getShortcut(for: shortcut.action)
                if otherKey == key && otherMods == modifiers {
                    conflictMessage = "This shortcut is already assigned to: \(shortcut.description)"
                    completion(true)
                    return
                }
            }
        }
        conflictMessage = nil
        completion(false)
    }
    
    private func formatShortcut(key: KeyEquivalent, modifiers: EventModifiers) -> String {
        var parts: [String] = []
        if modifiers.contains(.command) { parts.append("⌘") }
        if modifiers.contains(.shift) { parts.append("⇧") }
        if modifiers.contains(.option) { parts.append("⌥") }
        if modifiers.contains(.control) { parts.append("⌃") }
        parts.append(key.character.uppercased())
        return parts.joined(separator: "")
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
                        title: "SSH",
                        description: "SSH connections and key management",
                        icon: "network",
                        color: .teal
                    ) {
                        selectedTab = .ssh
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
    @State private var selectedCategory: String = ProductivityTools.QuickCommand.BuiltInCategory.custom.rawValue
    @State private var commandIcon: String = "terminal"
    @State private var requiresKeyword: Bool = false
    @State private var keywordPlaceholder: String = ""
    @State private var editingCommand: ProductivityTools.QuickCommand? = nil
    @State private var selectedCategoryFilter: String? = nil
    
    // Category management
    @State private var newCategoryName: String = ""
    @State private var showingAddCategory = false
    
    var filteredCommands: [ProductivityTools.QuickCommand] {
        if let filter = selectedCategoryFilter {
            return productivityTools.quickCommands.filter { $0.category == filter }
        }
        return productivityTools.quickCommands
    }
    
    var commandsByCategory: [String: [ProductivityTools.QuickCommand]] {
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
                
                // Category Management
                VStack(alignment: .leading, spacing: 12) {
                    HStack {
                        Text("Categories")
                            .font(.headline)
                        Spacer()
                        Button(action: { showingAddCategory = true }) {
                            Image(systemName: "plus.circle.fill")
                            Text("Add Category")
                        }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
                    }
                    
                    // Built-in categories (read-only)
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Built-in Categories")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                        FlowLayout(spacing: 8) {
                            ForEach(productivityTools.getAllCategories().filter { productivityTools.isBuiltInCategory($0) }, id: \.self) { category in
                                HStack(spacing: 4) {
                                    Text(category)
                                    Image(systemName: "lock.fill")
                                        .font(.caption2)
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal, 8)
                                .padding(.vertical, 4)
                                .background(Color(NSColor.controlBackgroundColor))
                                .cornerRadius(6)
                            }
                        }
                    }
                    
                    // Custom categories (with delete button)
                    if !productivityTools.customCategories.isEmpty {
                        VStack(alignment: .leading, spacing: 4) {
                            Text("Custom Categories")
                                .font(.subheadline)
                                .foregroundColor(.secondary)
                            FlowLayout(spacing: 8) {
                                ForEach(productivityTools.customCategories, id: \.self) { category in
                                    HStack(spacing: 4) {
                                        Text(category)
                                        Button(action: {
                                            if productivityTools.canRemoveCategory(category) {
                                                _ = productivityTools.removeCustomCategory(category)
                                            }
                                        }) {
                                            Image(systemName: "xmark.circle.fill")
                                                .font(.caption2)
                                                .foregroundColor(.red)
                                        }
                                        .buttonStyle(.plain)
                                        .help(productivityTools.canRemoveCategory(category) ? "Remove category" : "Cannot remove: category has commands")
                                        .disabled(!productivityTools.canRemoveCategory(category))
                                    }
                                    .padding(.horizontal, 8)
                                    .padding(.vertical, 4)
                                    .background(Color(NSColor.controlBackgroundColor))
                                    .cornerRadius(6)
                                }
                            }
                        }
                    }
                }
                .padding()
                .background(Color(NSColor.controlBackgroundColor))
                .cornerRadius(8)
                .sheet(isPresented: $showingAddCategory) {
                    VStack(spacing: 16) {
                        Text("Add Custom Category")
                            .font(.headline)
                        TextField("Category name", text: $newCategoryName)
                            .textFieldStyle(.roundedBorder)
                        HStack {
                            Button("Cancel") {
                                showingAddCategory = false
                                newCategoryName = ""
                            }
                            .buttonStyle(.bordered)
                            Button("Add") {
                                productivityTools.addCustomCategory(newCategoryName)
                                showingAddCategory = false
                                newCategoryName = ""
                            }
                            .buttonStyle(.borderedProminent)
                            .disabled(newCategoryName.trimmingCharacters(in: .whitespaces).isEmpty)
                        }
                    }
                    .padding()
                    .frame(width: 300)
                }
                
                Divider()
                
                // Category filter
                VStack(alignment: .leading, spacing: 8) {
                    Text("Filter by Category")
                        .font(.headline)
                    
                    Picker("Category", selection: $selectedCategoryFilter) {
                        Text("All Categories").tag(nil as String?)
                        ForEach(productivityTools.getAllCategories(), id: \.self) { category in
                            Text(category).tag(category as String?)
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
                                ForEach(productivityTools.getAllCategories(), id: \.self) { category in
                                    Text(category).tag(category)
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
                        ForEach(commandsByCategory.keys.sorted(), id: \.self) { category in
                            VStack(alignment: .leading, spacing: 8) {
                                Text(category)
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
        selectedCategory = ProductivityTools.QuickCommand.BuiltInCategory.custom.rawValue
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
    @State private var provider: AIManager.AIType = .builtIn
    @State private var lmURL = ""
    @State private var lmModel = ""
    @State private var anthropicModel = ""
    @State private var openAIURL = ""
    @State private var openAIModel = ""
    @State private var includeContext = false
    @State private var apiKeyInput = ""
    @State private var keyStatus: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("AI Assistant Configuration").font(.title2).fontWeight(.semibold)
                
                VStack(alignment: .leading, spacing: 12) {
                    Text("Provider").font(.headline)
                    Picker("Provider", selection: $provider) {
                        ForEach(AIManager.AIType.allCases) { Text($0.displayName).tag($0) }
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: provider) { _, newValue in
                        aiManager.setAI(newValue)
                        apiKeyInput = ""
                        keyStatus = nil
                    }
                    Text(provider.description).font(.caption).foregroundColor(.secondary)
                }
                .padding().background(Color(NSColor.controlBackgroundColor)).cornerRadius(8)
                
                if provider == .anthropic {
                    card("Claude") {
                        field("Model", "claude-sonnet-5-5", $anthropicModel)
                        keyField()
                    }
                }
                if provider == .openAICompatible {
                    card("OpenAI-compatible server") {
                        field("Base URL", "https://api.openai.com", $openAIURL)
                        field("Model", "e.g. gpt-4o-mini", $openAIModel)
                        keyField()
                    }
                }
                if provider == .lmStudio {
                    card("LM Studio") {
                        field("Server URL", "http://localhost:1234", $lmURL)
                        field("Model (optional)", "Model name", $lmModel)
                    }
                }
                
                if provider != .builtIn {
                    Toggle("Include the last 60 lines of terminal output as context", isOn: $includeContext)
                    Text(provider == .lmStudio
                         ? "Stays on your machine."
                         : "Off by default. When on, terminal output (which may contain secrets) is sent to the provider.")
                        .font(.caption).foregroundColor(.secondary)
                }
                
                Button("Save") { save() }.buttonStyle(.borderedProminent)
            }
            .padding()
        }
        .onAppear {
            provider = aiManager.selectedAI
            lmURL = aiManager.lmStudioURL
            lmModel = aiManager.lmStudioModel
            anthropicModel = aiManager.anthropicModel
            openAIURL = aiManager.openAIBaseURL
            openAIModel = aiManager.openAIModel
            includeContext = aiManager.includeTerminalContext
        }
        .onDisappear { save() }
    }
    
    private func save() {
        aiManager.setLMStudioURL(lmURL)
        aiManager.setLMStudioModel(lmModel)
        aiManager.saveProviderSettings(
            anthropicModel: anthropicModel, openAIBaseURL: openAIURL,
            openAIModel: openAIModel, includeContext: includeContext)
    }
    
    private func card<Content: View>(_ title: String, @ViewBuilder _ content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(title).font(.headline)
            content()
        }
        .padding().background(Color(NSColor.controlBackgroundColor)).cornerRadius(8)
    }
    
    private func field(_ label: String, _ placeholder: String, _ text: Binding<String>) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label)
            TextField(placeholder, text: text).textFieldStyle(.roundedBorder)
        }
    }
    
    private func keyField() -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("API key")
            HStack {
                SecureField(aiManager.hasAPIKey(for: provider) ? "Saved in Keychain (enter a new one to replace)" : "Paste API key",
                            text: $apiKeyInput)
                    .textFieldStyle(.roundedBorder)
                Button("Save Key") {
                    keyStatus = aiManager.setAPIKey(apiKeyInput, for: provider)
                        ? (apiKeyInput.isEmpty ? "Key removed" : "Key saved to Keychain") : "Could not update Keychain"
                    apiKeyInput = ""
                }
                .disabled(apiKeyInput.isEmpty)
                if aiManager.hasAPIKey(for: provider) {
                    Button("Remove") {
                        aiManager.setAPIKey("", for: provider)
                        keyStatus = "Key removed"
                    }
                }
            }
            if let keyStatus { Text(keyStatus).font(.caption).foregroundColor(.secondary) }
        }
    }
}

// MARK: - SSH Connection Settings
struct SSHConnectionSettings: View {
    @EnvironmentObject var integrationFeatures: IntegrationFeatures
    @State private var showingAddConnection = false
    @State private var showingAddKey = false
    @State private var editingConnection: IntegrationFeatures.SSHConnection?
    @State private var showingEditConnection = false
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                // SSH Connections Section
                GroupBox("SSH Connections") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Manage your saved SSH connections")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                editingConnection = nil
                                showingAddConnection = true
                            }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add Connection")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        
                        if integrationFeatures.sshConnections.isEmpty {
                            Text("No SSH connections saved yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.vertical, 8)
                        } else {
                            ForEach(integrationFeatures.sshConnections) { connection in
                                SSHConnectionRow(
                                    connection: connection,
                                    integrationFeatures: integrationFeatures,
                                    onEdit: {
                                        editingConnection = connection
                                        showingEditConnection = true
                                    },
                                    onDelete: {
                                        integrationFeatures.removeSSHConnection(connection)
                                    },
                                    onConnect: {
                                        integrationFeatures.connectSSH(connection)
                                    }
                                )
                            }
                        }
                    }
                    .padding()
                }
                
                Divider()
                
                // SSH Keys Section
                GroupBox("SSH Keys") {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Text("Manage your SSH keys")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                            Button(action: {
                                showingAddKey = true
                            }) {
                                HStack {
                                    Image(systemName: "plus.circle.fill")
                                    Text("Add SSH Key")
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        
                        if integrationFeatures.sshKeys.isEmpty {
                            Text("No SSH keys added yet.")
                                .font(.caption)
                                .foregroundColor(.secondary)
                                .italic()
                                .padding(.vertical, 8)
                        } else {
                            ForEach(integrationFeatures.sshKeys) { key in
                                SSHKeyRow(
                                    key: key,
                                    integrationFeatures: integrationFeatures,
                                    onSetDefault: {
                                        integrationFeatures.setDefaultSSHKey(key)
                                    },
                                    onDelete: {
                                        integrationFeatures.removeSSHKey(key)
                                    }
                                )
                            }
                        }
                    }
                    .padding()
                }
            }
            .padding()
        }
        .sshEditWindow(isPresented: $showingAddConnection, title: "Add SSH Connection") {
            AddEditSSHConnectionSheet(
                connection: nil,
                integrationFeatures: integrationFeatures,
                onSave: {
                    showingAddConnection = false
                },
                onCancel: {
                    showingAddConnection = false
                }
            )
        }
        .sshEditWindow(isPresented: $showingEditConnection, title: "Edit SSH Connection") {
            if let connection = editingConnection {
                AddEditSSHConnectionSheet(
                    connection: connection,
                    integrationFeatures: integrationFeatures,
                    onSave: {
                        showingEditConnection = false
                        editingConnection = nil
                    },
                    onCancel: {
                        showingEditConnection = false
                        editingConnection = nil
                    }
                )
            }
        }
        .sshEditWindow(isPresented: $showingAddKey, title: "Add SSH Key") {
            AddSSHKeySheet(
                integrationFeatures: integrationFeatures,
                onSave: {
                    showingAddKey = false
                },
                onCancel: {
                    showingAddKey = false
                }
            )
        }
    }
}

// MARK: - SSH Connection Row
struct SSHConnectionRow: View {
    let connection: IntegrationFeatures.SSHConnection
    @ObservedObject var integrationFeatures: IntegrationFeatures
    let onEdit: () -> Void
    let onDelete: () -> Void
    let onConnect: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(connection.name)
                        .font(.headline)
                    if integrationFeatures.isConnectionActive(connection) {
                        Circle()
                            .fill(.green)
                            .frame(width: 8, height: 8)
                        Text("Connected")
                            .font(.caption)
                            .foregroundColor(.green)
                    }
                }
                Text("\(connection.username)@\(connection.host):\(connection.port)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                if let lastConnected = connection.lastConnected {
                    Text("Last connected: \(lastConnected, style: .relative)")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
            HStack(spacing: 8) {
                if !integrationFeatures.isConnectionActive(connection) {
                    Button("Connect", action: onConnect)
                        .buttonStyle(.bordered)
                } else {
                    Button("Disconnect") {
                        integrationFeatures.disconnectSSH()
                    }
                    .buttonStyle(.bordered)
                }
                Button("Edit", action: onEdit)
                    .buttonStyle(.bordered)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - SSH Key Row
struct SSHKeyRow: View {
    let key: IntegrationFeatures.SSHKey
    @ObservedObject var integrationFeatures: IntegrationFeatures
    let onSetDefault: () -> Void
    let onDelete: () -> Void
    
    var body: some View {
        HStack {
            VStack(alignment: .leading, spacing: 4) {
                HStack {
                    Text(key.name)
                        .font(.headline)
                    if key.isDefault {
                        Text("Default")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(4)
                    }
                }
                Text("Type: \(key.type.rawValue)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Path: \(key.path)")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Text("Fingerprint: \(key.fingerprint)")
                    .font(.caption2)
                    .foregroundColor(.secondary)
            }
            Spacer()
            HStack(spacing: 8) {
                if !key.isDefault {
                    Button("Set as Default", action: onSetDefault)
                        .buttonStyle(.bordered)
                }
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor).opacity(0.5))
        .cornerRadius(8)
    }
}

// MARK: - Add/Edit SSH Connection Sheet
struct AddEditSSHConnectionSheet: View {
    let connection: IntegrationFeatures.SSHConnection?
    @ObservedObject var integrationFeatures: IntegrationFeatures
    let onSave: () -> Void
    let onCancel: () -> Void
    
    @State private var name: String = ""
    @State private var host: String = ""
    @State private var port: Int = 22
    @State private var username: String = ""
    @State private var selectedKeyPath: String? = nil
    @State private var password: String = ""
    @State private var usePassword: Bool = false
    
    var isEditing: Bool {
        connection != nil
    }
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text(isEditing ? "Edit SSH Connection" : "Add SSH Connection")
                .font(.title2)
                .fontWeight(.bold)
                .padding(.top, 8)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Connection Name")
                    .font(.headline)
                TextField("e.g., Production Server", text: $name)
                    .textFieldStyle(.roundedBorder)
                
                Text("Host")
                    .font(.headline)
                TextField("e.g., example.com", text: $host)
                    .textFieldStyle(.roundedBorder)
                
                Text("Port")
                    .font(.headline)
                TextField("", value: $port, format: .number)
                    .textFieldStyle(.roundedBorder)
                    .frame(width: 100)
                
                Text("Username")
                    .font(.headline)
                TextField("e.g., admin", text: $username)
                    .textFieldStyle(.roundedBorder)
                
                Text("Authentication Method")
                    .font(.headline)
                
                Picker("Authentication", selection: $usePassword) {
                    Text("SSH Key").tag(false)
                    Text("Password").tag(true)
                }
                .pickerStyle(.segmented)
                
                if usePassword {
                    SecureField("Enter password", text: $password)
                        .textFieldStyle(.roundedBorder)
                        .accessibilityLabel("SSH Password")
                        .accessibilityHint("Enter the password for SSH authentication")
                } else {
                    Picker("SSH Key", selection: $selectedKeyPath) {
                        Text("None").tag(nil as String?)
                        ForEach(integrationFeatures.sshKeys) { key in
                            Text(key.name).tag(key.path as String?)
                        }
                    }
                    .pickerStyle(.menu)
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Save", action: {
                    if isEditing, let conn = connection {
                        // Update existing connection - preserve ID and password
                        let passwordToSave = usePassword && !password.isEmpty ? password : nil
                        integrationFeatures.updateSSHConnection(
                            id: conn.id,
                            name: name,
                            host: host,
                            port: port,
                            username: username,
                            keyPath: usePassword ? nil : selectedKeyPath,
                            usesPassword: usePassword,
                            password: passwordToSave
                        )
                    } else {
                        // Add new connection
                        let passwordToSave = usePassword && !password.isEmpty ? password : nil
                        integrationFeatures.addSSHConnection(
                            name: name,
                            host: host,
                            port: port,
                            username: username,
                            keyPath: usePassword ? nil : selectedKeyPath,
                            password: passwordToSave
                        )
                    }
                    password = "" // Clear password from memory
                    onSave()
                })
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || host.isEmpty || username.isEmpty)
                    .keyboardShortcut(.return)
            }
            .padding(.bottom, 8)
        }
        .padding(.horizontal, 24)
        .padding(.vertical, 20)
        .frame(width: 500, height: 500)
        .onAppear {
            if let conn = connection {
                name = conn.name
                host = conn.host
                port = conn.port
                username = conn.username
                selectedKeyPath = conn.keyPath
                usePassword = conn.usesPassword
                // Don't load password from Keychain for security - user must re-enter
                // Password will be loaded when connecting
            }
        }
    }
}

// MARK: - Add SSH Key Sheet
struct AddSSHKeySheet: View {
    @ObservedObject var integrationFeatures: IntegrationFeatures
    let onSave: () -> Void
    let onCancel: () -> Void
    
    @State private var name: String = ""
    @State private var keyPath: String = ""
    @State private var keyType: IntegrationFeatures.SSHKeyType = .ed25519
    @State private var isDefault: Bool = false
    @State private var generateNew: Bool = false
    @State private var passphrase: String = ""
    @State private var errorMessage: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Add SSH Key")
                .font(.title2)
                .fontWeight(.bold)
            
            Divider()
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Key Name")
                    .font(.headline)
                TextField("e.g., My Laptop Key", text: $name)
                    .textFieldStyle(.roundedBorder)
                
                Text("Key Path")
                    .font(.headline)
                HStack {
                    TextField("e.g., ~/.ssh/id_ed25519", text: $keyPath)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse...") {
                        let panel = NSOpenPanel()
                        panel.allowsMultipleSelection = false
                        panel.canChooseDirectories = false
                        panel.canChooseFiles = true
                        panel.allowedContentTypes = [.data]
                        panel.directoryURL = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".ssh")
                        
                        if panel.runModal() == .OK {
                            if let url = panel.url {
                                keyPath = url.path
                            }
                        }
                    }
                    .buttonStyle(.bordered)
                }
                
                Text("Key Type")
                    .font(.headline)
                Picker("Key Type", selection: $keyType) {
                    ForEach(IntegrationFeatures.SSHKeyType.allCases, id: \.self) { type in
                        Text(type.rawValue).tag(type)
                    }
                }
                .pickerStyle(.menu)
                
                Toggle("Generate a new key pair at this path", isOn: $generateNew)
                if generateNew {
                    SecureField("Passphrase (optional)", text: $passphrase)
                        .textFieldStyle(.roundedBorder)
                }
                
                Toggle("Set as default key", isOn: $isDefault)
                
                if let errorMessage {
                    Text(errorMessage)
                        .font(.caption)
                        .foregroundColor(.red)
                }
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button(generateNew ? "Generate" : "Save", action: {
                    if generateNew {
                        if let error = IntegrationFeatures.generateKeyPair(
                            at: keyPath, type: keyType, comment: name, passphrase: passphrase) {
                            errorMessage = error
                            return
                        }
                    }
                    integrationFeatures.addSSHKey(
                        name: name,
                        path: keyPath,
                        type: keyType,
                        isDefault: isDefault
                    )
                    onSave()
                })
                    .buttonStyle(.borderedProminent)
                    .disabled(name.isEmpty || keyPath.isEmpty)
                    .keyboardShortcut(.return)
            }
        }
        .padding()
        .frame(width: 500, height: 460)
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

// MARK: - FlowLayout Helper
struct FlowLayout: Layout {
    var spacing: CGFloat = 8
    
    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let result = FlowResult(
            in: proposal.replacingUnspecifiedDimensions().width,
            subviews: subviews,
            spacing: spacing
        )
        return result.size
    }
    
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = FlowResult(
            in: bounds.width,
            subviews: subviews,
            spacing: spacing
        )
        for (index, subview) in subviews.enumerated() {
            subview.place(at: CGPoint(x: bounds.minX + result.frames[index].minX,
                                     y: bounds.minY + result.frames[index].minY),
                         proposal: .unspecified)
        }
    }
    
    struct FlowResult {
        var size: CGSize = .zero
        var frames: [CGRect] = []
        
        init(in maxWidth: CGFloat, subviews: Subviews, spacing: CGFloat) {
            var currentX: CGFloat = 0
            var currentY: CGFloat = 0
            var lineHeight: CGFloat = 0
            
            for subview in subviews {
                let size = subview.sizeThatFits(.unspecified)
                
                if currentX + size.width > maxWidth && currentX > 0 {
                    // Move to next line
                    currentX = 0
                    currentY += lineHeight + spacing
                    lineHeight = 0
                }
                
                frames.append(CGRect(x: currentX, y: currentY, width: size.width, height: size.height))
                currentX += size.width + spacing
                lineHeight = max(lineHeight, size.height)
            }
            
            self.size = CGSize(width: maxWidth, height: currentY + lineHeight)
        }
    }
}

// MARK: - Session Templates Settings
struct TemplateSettings: View {
    @EnvironmentObject var productivityTools: ProductivityTools
    @EnvironmentObject var terminalManager: TerminalManager
    @State private var editingId: UUID?
    @State private var name = ""
    @State private var directory = ""
    @State private var commands = ""
    @State private var environment = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Session Templates").font(.title2).fontWeight(.bold)
                Text("A template opens a new tab in a folder, sets environment variables, and runs startup commands. Templates also appear in the Command Palette.")
                    .font(.caption).foregroundColor(.secondary)

                if productivityTools.sessionTemplates.isEmpty {
                    Text("No templates yet.").foregroundColor(.secondary)
                }
                ForEach(productivityTools.sessionTemplates) { template in
                    HStack {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(template.name).font(.headline)
                            Text(summary(template)).font(.caption).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Open") {
                            terminalManager.addSession(from: template)
                            productivityTools.useSessionTemplate(template)
                        }
                        Button("Edit") { load(template) }
                        Button("Delete", role: .destructive) {
                            productivityTools.removeSessionTemplate(template)
                            if editingId == template.id { reset() }
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }

                Divider()
                Text(editingId == nil ? "New Template" : "Edit Template").font(.headline)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                HStack {
                    TextField("Working directory (e.g. ~/Projects/app)", text: $directory)
                        .textFieldStyle(.roundedBorder)
                    Button("Browse…") {
                        let panel = NSOpenPanel()
                        panel.canChooseDirectories = true
                        panel.canChooseFiles = false
                        if panel.runModal() == .OK, let url = panel.url { directory = url.path }
                    }
                }
                Text("Startup commands (one per line)").font(.caption)
                TextEditor(text: $commands)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 80)
                    .border(Color.secondary.opacity(0.3))
                Text("Environment variables (KEY=VALUE, one per line)").font(.caption)
                TextEditor(text: $environment)
                    .font(.system(.body, design: .monospaced))
                    .frame(height: 60)
                    .border(Color.secondary.opacity(0.3))
                HStack {
                    Button(editingId == nil ? "Add Template" : "Save Changes", action: save)
                        .buttonStyle(.borderedProminent)
                        .disabled(name.trimmingCharacters(in: .whitespaces).isEmpty)
                    if editingId != nil { Button("Cancel", action: reset) }
                }
            }
        }
    }

    private func summary(_ t: ProductivityTools.SessionTemplate) -> String {
        var parts: [String] = []
        if let dir = t.workingDirectory, !dir.isEmpty { parts.append(dir) }
        if !t.initialCommands.isEmpty { parts.append("\(t.initialCommands.count) command(s)") }
        if !t.environment.isEmpty { parts.append("\(t.environment.count) env var(s)") }
        return parts.isEmpty ? "Plain session" : parts.joined(separator: " · ")
    }

    private func parsedEnvironment() -> [String: String] {
        var result: [String: String] = [:]
        for line in environment.split(separator: "\n") {
            guard let eq = line.firstIndex(of: "=") else { continue }
            let key = line[..<eq].trimmingCharacters(in: .whitespaces)
            let value = line[line.index(after: eq)...].trimmingCharacters(in: .whitespaces)
            if !key.isEmpty { result[key] = value }
        }
        return result
    }

    private func save() {
        let cmds = commands.split(separator: "\n").map(String.init)
        let dir = directory.trimmingCharacters(in: .whitespaces)
        if let id = editingId, var existing = productivityTools.sessionTemplates.first(where: { $0.id == id }) {
            existing.name = name
            existing.workingDirectory = dir.isEmpty ? nil : dir
            existing.initialCommands = cmds
            existing.environment = parsedEnvironment()
            productivityTools.updateSessionTemplate(existing)
        } else {
            productivityTools.addSessionTemplate(
                name: name, initialCommands: cmds,
                workingDirectory: dir.isEmpty ? nil : dir, environment: parsedEnvironment())
        }
        reset()
    }

    private func load(_ t: ProductivityTools.SessionTemplate) {
        editingId = t.id
        name = t.name
        directory = t.workingDirectory ?? ""
        commands = t.initialCommands.joined(separator: "\n")
        environment = t.environment.sorted { $0.key < $1.key }.map { "\($0.key)=\($0.value)" }.joined(separator: "\n")
    }

    private func reset() {
        editingId = nil; name = ""; directory = ""; commands = ""; environment = ""
    }
}

// MARK: - Output Filter Settings
struct FilterSettings: View {
    @EnvironmentObject var productivityTools: ProductivityTools
    @State private var name = ""
    @State private var pattern = ""
    @State private var isRegex = false
    @State private var action: ProductivityTools.OutputFilter.FilterAction = .highlight
    @State private var color = Color.yellow
    @State private var replacement = ""

    private var patternError: String? {
        guard isRegex, !pattern.isEmpty else { return nil }
        return (try? NSRegularExpression(pattern: pattern)) == nil ? "Invalid regular expression" : nil
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Output Filters & Color Coding").font(.title2).fontWeight(.bold)

                Toggle("Collapsible command output (click ▾ before a command to fold its output)",
                       isOn: $productivityTools.collapsibleSections)
                Text("Folding hides output on screen only. Search skips folded text; exports always include everything.")
                    .font(.caption).foregroundColor(.secondary)

                Toggle("Color-code errors, warnings and successes", isOn: $productivityTools.colorCodeOutput)
                Text("Colors keywords like error / warning / passed. Colors set by the program itself are left alone.")
                    .font(.caption).foregroundColor(.secondary)

                Divider()
                Text("Filters apply to display only; the underlying output and exports are unchanged. Hide, Extract and Replace work on whole lines that have finished, never on the live prompt.")
                    .font(.caption).foregroundColor(.secondary)

                ForEach(productivityTools.outputFilters) { filter in
                    HStack {
                        Toggle("", isOn: Binding(
                            get: { filter.isEnabled },
                            set: { _ in productivityTools.toggleFilter(filter) }
                        )).labelsHidden()
                        VStack(alignment: .leading, spacing: 2) {
                            Text(filter.name).font(.headline)
                            Text("\(filter.action.rawValue): \(filter.pattern)\(filter.isRegex ? "  (regex)" : "")")
                                .font(.system(.caption, design: .monospaced)).foregroundColor(.secondary)
                        }
                        Spacer()
                        Button("Delete", role: .destructive) { productivityTools.removeOutputFilter(filter) }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }

                Divider()
                Text("New Filter").font(.headline)
                TextField("Name", text: $name).textFieldStyle(.roundedBorder)
                TextField("Text or pattern to match", text: $pattern).textFieldStyle(.roundedBorder)
                if let patternError { Text(patternError).font(.caption).foregroundColor(.red) }
                Toggle("Regular expression", isOn: $isRegex)
                Picker("Action", selection: $action) {
                    ForEach(ProductivityTools.OutputFilter.FilterAction.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                if action == .highlight { ColorPicker("Highlight color", selection: $color) }
                if action == .replace {
                    TextField(isRegex ? "Replacement (use $1 for groups)" : "Replacement", text: $replacement)
                        .textFieldStyle(.roundedBorder)
                }
                Button("Add Filter") {
                    productivityTools.addOutputFilter(
                        name: name.isEmpty ? pattern : name, pattern: pattern, isRegex: isRegex,
                        action: action, color: hexString(color),
                        replacement: action == .replace ? replacement : nil)
                    name = ""; pattern = ""; replacement = ""
                }
                .buttonStyle(.borderedProminent)
                .disabled(pattern.isEmpty || patternError != nil)
            }
        }
    }

    private func hexString(_ color: Color) -> String {
        let ns = NSColor(color).usingColorSpace(.sRGB) ?? .yellow
        return String(format: "#%02X%02X%02X", Int(ns.redComponent * 255), Int(ns.greenComponent * 255), Int(ns.blueComponent * 255))
    }
}

// MARK: - Workspace Settings
struct WorkspaceSettings: View {
    @EnvironmentObject var productivityTools: ProductivityTools
    @EnvironmentObject var terminalManager: TerminalManager
    @State private var newName = ""
    @State private var renamingId: UUID?
    @State private var renameText = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Workspaces").font(.title2).fontWeight(.bold)
                Text("A workspace remembers your open tabs (name, color and folder) so you can bring the same set back later. SSH tabs are not included. Workspaces also appear in the Command Palette.")
                    .font(.caption).foregroundColor(.secondary)

                if productivityTools.workspaces.isEmpty { Text("No workspaces yet.").foregroundColor(.secondary) }
                ForEach(productivityTools.workspaces) { workspace in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            if renamingId == workspace.id {
                                TextField("Name", text: $renameText).textFieldStyle(.roundedBorder)
                                Button("Save") {
                                    productivityTools.renameWorkspace(workspace.id, to: renameText)
                                    renamingId = nil
                                }
                                Button("Cancel") { renamingId = nil }
                            } else {
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(workspace.name).font(.headline)
                                    Text(workspace.tabs.map(\.title).joined(separator: " · "))
                                        .font(.caption).foregroundColor(.secondary).lineLimit(2)
                                }
                                Spacer()
                                Button("Open") {
                                    terminalManager.openWorkspace(workspace)
                                    productivityTools.markWorkspaceOpened(workspace.id)
                                }
                                Button("Update from current tabs") {
                                    productivityTools.updateWorkspace(workspace.id, tabs: terminalManager.workspaceTabs())
                                }
                                Button("Rename") { renamingId = workspace.id; renameText = workspace.name }
                                Button("Delete", role: .destructive) { productivityTools.deleteWorkspace(workspace.id) }
                            }
                        }
                        ForEach(Array(workspace.tabs.enumerated()), id: \.offset) { _, tab in
                            Text("\(tab.title)  \(tab.cwd ?? "")")
                                .font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                    .padding(8)
                    .background(Color(NSColor.controlBackgroundColor))
                    .cornerRadius(6)
                }

                Divider()
                Text("Save current tabs").font(.headline)
                HStack {
                    TextField("Workspace name", text: $newName).textFieldStyle(.roundedBorder)
                    Button("Save Workspace") {
                        productivityTools.saveWorkspace(name: newName, tabs: terminalManager.workspaceTabs())
                        newName = ""
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(newName.trimmingCharacters(in: .whitespaces).isEmpty || terminalManager.workspaceTabs().isEmpty)
                }
            }
        }
    }
}

// MARK: - Plugin Settings
struct PluginSettings: View {
    @ObservedObject private var manager = PluginManager.shared
    @State private var message: String?
    @State private var pendingEnable: PluginManager.Plugin?
    @State private var pendingRemove: PluginManager.Plugin?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                Text("Plugins").font(.title2).fontWeight(.bold)
                Text("A plugin is a folder with a plugin.json that adds commands to the Command Palette. Plugins contain no app code: each command is a shell line typed into your active terminal, so you see exactly what runs. Only enable plugins you trust.")
                    .font(.caption).foregroundColor(.secondary)

                HStack {
                    Button("Install from Folder…", action: installFromFolder)
                    Button("Create Example Plugin") {
                        do { let folder = try manager.writeExamplePlugin(); message = "Created \(folder.lastPathComponent). Enable it below." }
                        catch { message = error.localizedDescription }
                    }
                    Button("Reload") { manager.reload() }
                    Button("Open Plugins Folder") { NSWorkspace.shared.open(manager.directory) }
                }
                if let message { Text(message).font(.caption).foregroundColor(.secondary) }

                if manager.plugins.isEmpty && manager.failures.isEmpty {
                    Text("No plugins installed.").foregroundColor(.secondary)
                }
                ForEach(manager.plugins) { plugin in
                    VStack(alignment: .leading, spacing: 6) {
                        HStack(alignment: .top) {
                            Toggle("", isOn: Binding(
                                get: { plugin.isEnabled },
                                set: { on in
                                    if on { pendingEnable = plugin } else { manager.setEnabled(false, pluginID: plugin.id) }
                                })).labelsHidden()
                            VStack(alignment: .leading, spacing: 2) {
                                Text("\(plugin.manifest.name)  v\(plugin.manifest.version)").font(.headline)
                                if let author = plugin.manifest.author { Text("by \(author)").font(.caption).foregroundColor(.secondary) }
                                if let description = plugin.manifest.description { Text(description).font(.caption) }
                                if plugin.needsReapproval {
                                    Text("plugin.json changed since you enabled it. Review and enable again.")
                                        .font(.caption).foregroundColor(.orange)
                                }
                            }
                            Spacer()
                            Button("Remove", role: .destructive) { pendingRemove = plugin }
                        }
                        ForEach(plugin.manifest.commands) { command in
                            Text("• \(command.title):  \(command.command)")
                                .font(.system(.caption2, design: .monospaced)).foregroundColor(.secondary)
                        }
                    }
                    .padding(8).background(Color(NSColor.controlBackgroundColor)).cornerRadius(6)
                }
                ForEach(manager.failures) { failure in
                    Text("⚠︎ \(failure.folder): \(failure.reason)").font(.caption).foregroundColor(.red)
                }
            }
        }
        .alert("Enable \(pendingEnable?.manifest.name ?? "plugin")?",
               isPresented: Binding(get: { pendingEnable != nil }, set: { if !$0 { pendingEnable = nil } })) {
            Button("Enable") { if let plugin = pendingEnable { manager.setEnabled(true, pluginID: plugin.id) }; pendingEnable = nil }
            Button("Cancel", role: .cancel) { pendingEnable = nil }
        } message: {
            if let plugin = pendingEnable {
                Text("This plugin adds \(plugin.manifest.commands.count) command(s) that run in your terminal as you:\n\n"
                     + plugin.manifest.commands.prefix(8).map { "• \($0.command)" }.joined(separator: "\n"))
            }
        }
        .alert("Remove \(pendingRemove?.manifest.name ?? "plugin")?",
               isPresented: Binding(get: { pendingRemove != nil }, set: { if !$0 { pendingRemove = nil } })) {
            Button("Remove", role: .destructive) {
                if let plugin = pendingRemove {
                    do { try manager.remove(pluginID: plugin.id) } catch { message = error.localizedDescription }
                }
                pendingRemove = nil
            }
            Button("Cancel", role: .cancel) { pendingRemove = nil }
        } message: {
            Text("This deletes the plugin's folder from the plugins directory.")
        }
    }

    private func installFromFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.message = "Choose a folder that contains plugin.json"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let id = try manager.install(from: url)
            message = "Installed \(id). Enable it below."
        } catch {
            message = error.localizedDescription
        }
    }
}
