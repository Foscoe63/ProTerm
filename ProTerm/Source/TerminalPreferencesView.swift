import SwiftUI
import Combine

struct TerminalPreferencesView: View {
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var themeManager: ThemeManager
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
            // MARK: – Terminal Settings Section
            GroupBox("Terminal Settings") {
                VStack(alignment: .leading, spacing: 16) {
                    // Shell Selection
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Default Shell")
                            .font(.headline)
                        
                        Picker("Shell", selection: $shellManager.selectedShell) {
                            ForEach(ShellManager.ShellType.allCases) { shell in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(shell.displayName)
                                        .font(.body)
                                    Text(shell.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .tag(shell)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        .onChange(of: shellManager.selectedShell) { _, newShell in
                            shellManager.setShell(newShell)
                        }
                    }
                    
                    Divider()
                    
                    // Future terminal settings can be added here
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Additional Settings")
                            .font(.headline)
                        
                        Text("More terminal preferences will be added here in future updates.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            
            // MARK: – Theme Settings Section (existing)
            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 16) {
                    // Dark‑mode toggle (kept for backward compatibility)
                    Toggle("Dark Theme", isOn: Binding(
                        get: { themeManager.current.background == .black },
                        set: { isDark in
                            themeManager.current = Theme(
                                background: isDark ? .black : .white,
                                foreground: isDark ? .green : .black,
                                cursor: .orange
                            )
                        }
                    ))
                    
                    // Preset theme picker
                    Picker("Preset Theme", selection: Binding(
                        get: { 
                            let presets = [
                                ("Default", Theme(background: .white, foreground: .black, cursor: .orange)),
                                ("Dark", Theme(background: .black, foreground: .green, cursor: .orange)),
                                ("Solarized Light", Theme(background: Color(red: 0.99, green: 0.96, blue: 0.89), foreground: .black, cursor: .orange)),
                                ("Solarized Dark", Theme(background: Color(red: 0.0, green: 0.17, blue: 0.21), foreground: Color(red: 0.51, green: 0.58, blue: 0.59), cursor: .orange))
                            ]
                            return presets.first { $0.1.background == themeManager.current.background && $0.1.foreground == themeManager.current.foreground }?.0 ?? "Default"
                        },
                        set: { selectedName in
                            let presets = [
                                ("Default", Theme(background: .white, foreground: .black, cursor: .orange)),
                                ("Dark", Theme(background: .black, foreground: .green, cursor: .orange)),
                                ("Solarized Light", Theme(background: Color(red: 0.99, green: 0.96, blue: 0.89), foreground: .black, cursor: .orange)),
                                ("Solarized Dark", Theme(background: Color(red: 0.0, green: 0.17, blue: 0.21), foreground: Color(red: 0.51, green: 0.58, blue: 0.59), cursor: .orange))
                            ]
                            if let preset = presets.first(where: { $0.0 == selectedName }) {
                                themeManager.current = preset.1
                            }
                        }
                    )) {
                        Text("Default").tag("Default")
                        Text("Dark").tag("Dark")
                        Text("Solarized Light").tag("Solarized Light")
                        Text("Solarized Dark").tag("Solarized Dark")
                    }
                }
                .padding()
            }
            }
            .padding()
        }
    }
}
