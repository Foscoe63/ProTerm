import SwiftUI
import Combine

struct TerminalPreferencesView: View {
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var visualSettings: TerminalVisualSettings
    @State private var isTestingBell = false
    
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
                    
                    // MARK: - Cursor Settings
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Cursor Style")
                            .font(.headline)
                        
                        Picker("Cursor Style", selection: $visualSettings.cursorStyle) {
                            ForEach(TerminalVisualSettings.CursorStyle.allCases) { style in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(style.rawValue)
                                        .font(.body)
                                    Text(style.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .tag(style)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        
                        Toggle("Cursor Blinking", isOn: $visualSettings.cursorBlinking)
                    }
                    
                    Divider()
                    
                    // MARK: - Bell Settings
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Terminal Bell")
                            .font(.headline)
                        
                        Picker("Bell Action", selection: $visualSettings.bellAction) {
                            ForEach(TerminalVisualSettings.BellAction.allCases) { action in
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(action.rawValue)
                                        .font(.body)
                                    Text(action.description)
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                                .tag(action)
                            }
                        }
                        .pickerStyle(.radioGroup)
                        
                        if visualSettings.shouldPlayBellSound() {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Bell Volume: \(Int(visualSettings.bellSoundVolume * 100))%")
                                    .font(.caption)
                                Slider(value: $visualSettings.bellSoundVolume, in: 0.0...1.0)
                            }
                        }
                        
                        if visualSettings.shouldFlashVisual() {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Flash Duration: \(String(format: "%.2f", visualSettings.bellVisualFlashDuration))s")
                                    .font(.caption)
                                Slider(value: $visualSettings.bellVisualFlashDuration, in: 0.05...0.5)
                            }
                        }
                        
                        Button {
                            isTestingBell = true
                            BellFeedbackManager.shared.previewBell(using: visualSettings)
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) {
                                isTestingBell = false
                            }
                        } label: {
                            Label("Test Bell", systemImage: "speaker.wave.2.fill")
                        }
                        .buttonStyle(.borderedProminent)
                        .disabled(isTestingBell)
                    }
                    
                    Divider()
                    
                    // MARK: - Scrollback Settings
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Scrollback")
                            .font(.headline)
                        
                        Toggle("Enable Scrollback", isOn: $visualSettings.scrollbackEnabled)
                        
                        if visualSettings.scrollbackEnabled {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Scrollback Limit: \(visualSettings.scrollbackLimit) lines")
                                    .font(.caption)
                                HStack {
                                    Slider(value: Binding(
                                        get: { Double(visualSettings.scrollbackLimit) },
                                        set: { visualSettings.scrollbackLimit = Int($0) }
                                    ), in: 1000...100000, step: 1000)
                                    TextField("", value: Binding(
                                        get: { visualSettings.scrollbackLimit },
                                        set: { visualSettings.scrollbackLimit = max(1000, min(100000, $0)) }
                                    ), format: .number)
                                        .frame(width: 80)
                                }
                            }
                        }
                        
                        Toggle("Auto-scroll to bottom", isOn: $visualSettings.autoScroll)
                    }
                }
                .padding()
            }
            
            // MARK: – Appearance (macOS Terminal Profiles)
            GroupBox("Appearance") {
                VStack(alignment: .leading, spacing: 16) {
                    Text("Profile")
                        .font(.headline)
                    Picker("Profile", selection: $themeManager.selectedProfile) {
                        ForEach(TerminalProfile.allCases) { profile in
                            Text(profile.rawValue).tag(profile)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    .onChange(of: themeManager.selectedProfile) { _, newProfile in
                        // ThemeManager applies the theme automatically
                        _ = newProfile
                    }

                    // Simple color preview of the selected profile
                    HStack(spacing: 12) {
                        RoundedRectangle(cornerRadius: 4)
                            .fill(themeManager.current.background)
                            .frame(width: 60, height: 30)
                            .overlay(
                                RoundedRectangle(cornerRadius: 4)
                                    .stroke(Color.secondary.opacity(0.3), lineWidth: 1)
                            )
                        Text("Background")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Circle()
                            .fill(themeManager.current.foreground)
                            .frame(width: 14, height: 14)
                        Text("Foreground")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding()
            }
            }
            .padding()
        }
    }
}
