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
