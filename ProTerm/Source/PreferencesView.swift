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
                
                Toggle("Set as default key", isOn: $isDefault)
            }
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Cancel", action: onCancel)
                    .keyboardShortcut(.escape)
                Button("Save", action: {
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
        .frame(width: 500, height: 400)
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
