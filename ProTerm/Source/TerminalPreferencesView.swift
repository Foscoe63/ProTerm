import SwiftUI
import UniformTypeIdentifiers
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
                    
                    Divider()
                    
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Interactive IO")
                            .font(.headline)
                        Toggle("Protect pasted commands", isOn: $visualSettings.enableBracketedPaste)
                            .help("Wraps pasted text with OSC 200 sequences when sending to interactive shells.")
                        Toggle("Advertise mouse reporting", isOn: $visualSettings.enableMouseReporting)
                            .help("Enables xterm mouse tracking modes for full-screen TUI apps.")
                    }
                    
                    Divider()
                    
                    // MARK: - Command Box Outline Settings
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Command Box")
                            .font(.headline)
                        
                        Toggle("Show outline", isOn: $visualSettings.showCommandBoxOutline)
                            .help("Display an outline around the command input field")
                        
                        if visualSettings.showCommandBoxOutline {
                            ColorPicker("Outline color", selection: $visualSettings.commandBoxOutlineColor)
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Line width: \(String(format: "%.1f", visualSettings.commandBoxOutlineWidth)) pt")
                                    .font(.caption)
                                Slider(value: $visualSettings.commandBoxOutlineWidth, in: 1.0...5.0, step: 0.5)
                            }
                            
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Corner radius: \(String(format: "%.1f", visualSettings.commandBoxOutlineCornerRadius)) pt")
                                    .font(.caption)
                                Slider(value: $visualSettings.commandBoxOutlineCornerRadius, in: 0.0...8.0, step: 0.5)
                            }
                        }
                    }
                }
                .padding()
            }
            }
            .padding()
        }
    }
}

// MARK: – Appearance Profiles Section
struct AppearanceProfileSection: View {
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var fontManager: FontManager
    @State private var showingFontPicker = false
    @State private var profileErrorMessage: String?
    
    private var activeProfile: AppearanceProfile { themeManager.activeProfile }
    
    var body: some View {
        GroupBox("Appearance & Profiles") {
            VStack(alignment: .leading, spacing: 24) {
                Text("Profiles")
                    .font(.headline)
                
                profileCarousel
                profileActions
                Divider()
                customizationForm
            }
            .padding()
        }
        .sheet(isPresented: $showingFontPicker) {
            FontPickerView(selectedFontName: Binding(
                get: { fontManager.fontName },
                set: { newName in
                    fontManager.fontName = newName
                    themeManager.updateActiveProfileFontAsync(name: newName)
                })
            )
            .frame(minWidth: 260, minHeight: 320)
            .padding()
        }
        .alert("Profile Operation Failed", isPresented: Binding(
            get: { profileErrorMessage != nil },
            set: { if !$0 { profileErrorMessage = nil } }
        )) {
            Button("OK", role: .cancel) { profileErrorMessage = nil }
        } message: {
            if let message = profileErrorMessage {
                Text(message)
            }
        }
    }
    
    private var profileCarousel: some View {
        ScrollView(.horizontal, showsIndicators: true) {
            HStack(spacing: 16) {
                ForEach(themeManager.profiles) { profile in
                    ProfilePreviewCard(profile: profile,
                                       isSelected: profile.id == themeManager.activeProfileID)
                    .onTapGesture {
                        themeManager.selectProfile(profile)
                    }
                    .contextMenu {
                        Button("Duplicate") {
                            themeManager.duplicateProfile(profile)
                        }
                        if profile.isCustom {
                            Button("Delete", role: .destructive) {
                                themeManager.deleteProfile(profile)
                            }
                        }
                    }
                }
            }
            .padding(.vertical, 4)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
    
    private var profileActions: some View {
        HStack {
            Button {
                themeManager.duplicateProfile()
            } label: {
                Label("Duplicate Profile", systemImage: "square.on.square")
            }
            
            Button {
                themeManager.createCustomProfile()
            } label: {
                Label("New Blank Profile", systemImage: "sparkles")
            }
            
            Spacer()
            
            Menu {
                Button("Export Profiles…") {
                    exportProfiles()
                }
                Button("Import Profiles…") {
                    importProfiles()
                }
                Divider()
                Button("Reset to Built-in Profiles", role: .destructive) {
                    themeManager.resetProfilesToDefaults()
                }
            } label: {
                Label("Manage Profiles", systemImage: "slider.horizontal.3")
            }
        }
    }
    
    private var customizationForm: some View {
        VStack(alignment: .leading, spacing: 18) {
            TextField("Profile Name", text: Binding(
                get: { activeProfile.name },
                set: { themeManager.renameActiveProfileAsync(to: $0) }
            ))
            .font(.title3.bold())
            
            colorControls
            backgroundControls
            typographyControls
            layoutControls
            
            Toggle("Sync profiles via iCloud", isOn: $themeManager.syncProfilesToICloud)
                .toggleStyle(.switch)
        }
    }
    
    private var colorControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Colors")
                .font(.headline)
            ColorPicker("Background", selection: Binding(
                get: { activeProfile.theme.background },
                set: { color in
                    themeManager.updateActiveProfileAsync { $0.theme.background = color }
                })
            )
            ColorPicker("Foreground", selection: Binding(
                get: { activeProfile.theme.foreground },
                set: { color in
                    themeManager.updateActiveProfileAsync { $0.theme.foreground = color }
                })
            )
            ColorPicker("Cursor", selection: Binding(
                get: { activeProfile.theme.cursor },
                set: { color in
                    themeManager.updateActiveProfileAsync { $0.theme.cursor = color }
                })
            )
        }
    }
    
    private var backgroundControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Window Treatment")
                .font(.headline)
            
            Picker("Material", selection: Binding(
                get: { activeProfile.backgroundMaterial },
                set: { material in
                    themeManager.updateActiveProfileAsync { $0.backgroundMaterial = material }
                })
            ) {
                ForEach(AppearanceProfile.BackgroundMaterial.allCases) { material in
                    Text(material.displayName).tag(material)
                }
            }
            .pickerStyle(.segmented)
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Opacity: \(Int(activeProfile.backgroundOpacity * 100))%")
                    .font(.caption)
                Slider(value: Binding(
                    get: { activeProfile.backgroundOpacity },
                    set: { opacity in
                        themeManager.updateActiveProfileAsync { $0.backgroundOpacity = opacity }
                    }),
                       in: 0.3...1.0)
            }
            
            VStack(alignment: .leading, spacing: 4) {
                Text("Corner Radius: \(Int(activeProfile.cornerRadius)) pt")
                    .font(.caption)
                Slider(value: Binding(
                    get: { activeProfile.cornerRadius },
                    set: { radius in
                        themeManager.updateActiveProfileAsync { $0.cornerRadius = radius }
                    }),
                       in: 4...28)
            }
        }
    }
    
    private var typographyControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Typography")
                .font(.headline)
            
            HStack {
                VStack(alignment: .leading) {
                    Text(fontManager.fontName)
                        .font(.callout)
                        .fontWeight(.medium)
                    Text("\(Int(fontManager.fontSize)) pt")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button {
                    showingFontPicker = true
                } label: {
                    Label("Choose Font…", systemImage: "textformat.size")
                }
            }
            
            Slider(value: Binding(
                get: { fontManager.fontSize },
                set: { size in
                    fontManager.fontSize = size
                    themeManager.updateActiveProfileFontAsync(size: size)
                }),
                   in: 10...24,
                   step: 1)
        }
    }
    
    private var layoutControls: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Layout")
                .font(.headline)
            VStack(alignment: .leading, spacing: 4) {
                Text("Horizontal Padding: \(Int(activeProfile.horizontalPadding)) pt")
                    .font(.caption)
                Slider(value: Binding(
                    get: { activeProfile.horizontalPadding },
                    set: { padding in
                        themeManager.updateActiveProfileAsync { $0.horizontalPadding = padding }
                    }),
                       in: 8...40)
            }
            VStack(alignment: .leading, spacing: 4) {
                Text("Vertical Padding: \(Int(activeProfile.verticalPadding)) pt")
                    .font(.caption)
                Slider(value: Binding(
                    get: { activeProfile.verticalPadding },
                    set: { padding in
                        themeManager.updateActiveProfileAsync { $0.verticalPadding = padding }
                    }),
                       in: 6...32)
            }
        }
    }
    
    private func exportProfiles() {
        let panel = NSSavePanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.nameFieldStringValue = "ProTerm-Profiles.json"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try themeManager.exportProfiles(to: url)
            } catch {
                profileErrorMessage = "Failed to export profiles: \(error.localizedDescription)"
            }
        }
    }
    
    private func importProfiles() {
        let panel = NSOpenPanel()
        if #available(macOS 12.0, *) {
            panel.allowedContentTypes = [.json]
        } else {
            panel.allowedFileTypes = ["json"]
        }
        panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url {
            do {
                try themeManager.importProfiles(from: url)
            } catch {
                profileErrorMessage = "Failed to import profiles: \(error.localizedDescription)"
            }
        }
    }
}

struct ProfilePreviewCard: View {
    let profile: AppearanceProfile
    let isSelected: Bool
    
    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(profile.name)
                .font(.headline)
                .lineLimit(1)
            
            ZStack {
                RoundedRectangle(cornerRadius: profile.cornerRadius, style: .continuous)
                    .fill(profile.theme.background.opacity(profile.backgroundOpacity))
                    .overlay(
                        RoundedRectangle(cornerRadius: profile.cornerRadius, style: .continuous)
                            .stroke(.white.opacity(0.08), lineWidth: 1)
                    )
                
                VStack(alignment: .leading, spacing: 4) {
                    Text("$ ls -la")
                    Text("Desktop  Documents  Downloads")
                    Text("$ git status")
                }
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundColor(profile.theme.foreground)
                .padding(12)
            }
            .frame(width: 180, height: 110)
            
            HStack(spacing: 6) {
                Circle()
                    .fill(profile.theme.cursor)
                    .frame(width: 8, height: 8)
                Rectangle()
                    .fill(profile.theme.foreground.opacity(0.3))
                    .frame(height: 6)
                    .cornerRadius(3)
            }
            .padding(.horizontal, 4)
        }
        .padding(12)
        .background(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .fill(Color.black.opacity(0.05))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 2)
        )
        .frame(width: 200)
    }
}
