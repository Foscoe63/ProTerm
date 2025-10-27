import SwiftUI

struct PreferencesView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var lineNumbersManager: LineNumbersManager

    // Simple enum to drive the segmented picker.
    enum Tab: String, CaseIterable {
        case overview   = "Overview"
        case terminal   = "Terminal"
        case appearance = "Appearance"
        case font       = "Font"
        case shortcuts  = "Shortcuts"
    }

    @State private var selectedTab: Tab = .overview
    // `dismiss` works for sheets; we also provide an explicit close action for the Settings window.
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            // MARK: – Header with a close button
            HStack {
                Text("Preferences")
                    .font(.title2).bold()
                Spacer()
                Button(action: closeWindow) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
            .padding([.top, .horizontal])

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
                    }
                }
            }
            .padding()
        }
        .frame(minWidth: 440, minHeight: 360)   // minimum size, but resizable
        .toolbar {
            // Provide a standard macOS “Close” toolbar item – works for Settings windows.
            ToolbarItem(placement: .cancellationAction) {
                Button("Close", action: closeWindow)
            }
        }
    }

    // Close the Preferences window. Works for both a sheet (`dismiss`) and a Settings window.
    private func closeWindow() {
        dismiss()
        NSApp.keyWindow?.close()
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
    @State private var selectedFont = "Menlo"
    @State private var fontSize: Double = 14   // default size

    // Persist the chosen font & size across launches.
    private let fontNameKey = "ProTermFontName"
    private let fontSizeKey = "ProTermFontSize"

    var body: some View {
        // Use a VStack with top alignment so the content stays near the top.
        VStack(alignment: .leading, spacing: 16) {
            // Font picker (unchanged)
            FontPickerView(selectedFontName: $selectedFont)

            // New font‑size slider
            VStack(alignment: .leading, spacing: 8) {
                Text("Font Size: \(Int(fontSize))")
                Slider(value: $fontSize, in: 10...24, step: 1) {
                    Text("Font Size")
                } onEditingChanged: { _ in
                    // Save whenever the user stops dragging.
                    UserDefaults.standard.set(selectedFont, forKey: fontNameKey)
                    UserDefaults.standard.set(Int(fontSize), forKey: fontSizeKey)
                }
            }
            .padding(.top, -20) // Move font size controls UP by 20 pixels
        }
        .padding(.top, -20) // Move entire content UP by 20 pixels
        .padding()
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)   // flexible sizing
        .onAppear {
            // Load any previously saved values.
            if let name = UserDefaults.standard.string(forKey: fontNameKey) {
                selectedFont = name
            }
            let savedSize = UserDefaults.standard.integer(forKey: fontSizeKey)
            if savedSize != 0 { fontSize = Double(savedSize) }
        }
    }
}

// MARK: – Shortcut pane (placeholder)
struct ShortcutSettings: View {
    var body: some View {
        ScrollView {
            Form {
                Text("Shortcut customization UI will be added here.")
                    .foregroundColor(.secondary)
            }
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

// MARK: – Previews
struct PreferencesView_Previews: PreviewProvider {
    static var previews: some View {
        PreferencesView()
            .environmentObject(TerminalManager())
            .environmentObject(ThemeManager())
    }
}
