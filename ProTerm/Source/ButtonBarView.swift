import SwiftUI
import AppKit

struct ButtonBarView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var lineNumbersManager: LineNumbersManager
    @EnvironmentObject var productivityTools: ProductivityTools
    @EnvironmentObject var advancedFeatures: AdvancedFeatures
    @EnvironmentObject var fontManager: FontManager
    @EnvironmentObject var terminalVisualSettings: TerminalVisualSettings
    @EnvironmentObject var aiManager: AIManager
    @Binding var selectedTab: Int                // from ContentView
    @Binding var showQuickCommands: Bool         // from ContentView

    @State private var showingPreferences = false
    @State private var showingSearchReplace = false
    @State private var showingQuickSearch = false
    @State private var showingChatbot = false
    @State private var searchQuery = ""
    @State private var findText = ""
    @State private var replaceText = ""
    @Environment(\.dismiss) private var dismiss   // not used here, kept for completeness

    var body: some View {
        HStack(spacing: 8) {
            // MARK: - Session Management
            ButtonGroup {
                ToolbarButton(icon: "plus.square.on.square", help: "New Session", iconColor: .green, action: newSession)
                ToolbarButton(icon: "xmark.square", help: "Close Current Session", iconColor: .red, action: closeCurrentSession)
            }
            
            Divider()
                .frame(height: 20)
            
            // MARK: - Quick Commands Toggle
            ToolbarButton(
                icon: showQuickCommands ? "sidebar.right" : "sidebar.left",
                help: "Toggle Quick Commands",
                isActive: showQuickCommands,
                iconColor: showQuickCommands ? .blue : .orange,
                action: { showQuickCommands.toggle() }
            )

            Divider()
                .frame(height: 20)

            // MARK: - Copy/Paste
            ButtonGroup {
                ToolbarButton(icon: "doc.on.doc", help: "Copy Output", iconColor: .blue, action: copyOutput)
                ToolbarButton(icon: "doc.on.clipboard", help: "Paste to Input", iconColor: .purple, action: pasteToInput)
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - Search & Replace
            ButtonGroup {
                ToolbarButton(icon: "magnifyingglass", help: "Quick Search", iconColor: .cyan, action: quickSearch)
                ToolbarButton(icon: "textformat.abc", help: "Search & Replace", iconColor: .indigo, action: { showingSearchReplace.toggle() })
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - Clear Screen
            ToolbarButton(icon: "trash", help: "Clear Screen", iconColor: .red.opacity(0.8), action: clearScreen)
            
            Divider()
                .frame(height: 20)

            // MARK: - History & Commands
            ButtonGroup {
                ToolbarButton(icon: "clock.arrow.circlepath", help: "Command History", iconColor: .yellow, action: showHistory)
                ToolbarButton(icon: "arrow.clockwise", help: "Copy Last Command", iconColor: .mint, action: copyLastCommand)
            }
            
            Divider()
                .frame(height: 20)
            
            // MARK: - Command Palette
            ToolbarButton(icon: "command", help: "Command Palette (Cmd+P)", iconColor: .pink, action: showCommandPalette)
            
            Divider()
                .frame(height: 20)
            
            // MARK: - System Info
            ToolbarButton(icon: "info.circle", help: "System Information", iconColor: .teal, action: showSystemInfo)
            
            Divider()
                .frame(height: 20)

            // MARK: - AI Chatbot
            ToolbarButton(icon: "sparkles", help: "AI Chatbot", iconColor: .pink, action: { showingChatbot.toggle() })
            
            Divider()
                .frame(height: 20)
            
            // MARK: - Preferences
            ToolbarButton(icon: "gearshape", help: "Preferences…", iconColor: .gray, action: { showingPreferences.toggle() })
            
            Spacer()
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 4)
        .preferencesWindow(isPresented: $showingPreferences) {
            PreferencesView()
                .environmentObject(terminalManager)
                .environmentObject(themeManager)
                .environmentObject(shellManager)
                .environmentObject(lineNumbersManager)
                .environmentObject(productivityTools)
                .environmentObject(advancedFeatures)
                .environmentObject(fontManager)
                .environmentObject(terminalVisualSettings)
                .environmentObject(aiManager)
        }
        .sheet(isPresented: $showingSearchReplace) {
            SearchReplaceSheet(findText: $findText, replaceText: $replaceText)
        }
        .sheet(isPresented: $showingQuickSearch) {
            QuickSearchSheet(searchQuery: $searchQuery)
        }
        .sheet(isPresented: $showingChatbot) {
            ChatbotView()
        }
        // Listen for the menu‑command notification
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ProTermShowPreferences"))) { _ in
            showingPreferences = true
        }
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ProTermClosePreferences"))) { _ in
            showingPreferences = false
        }
    }

    // MARK: – Actions

    private func newSession() {
        terminalManager.addSession()
        selectedTab = terminalManager.sessions.count - 1
        ToastManager.shared.show("New session created", type: .success)
    }

    private func closeCurrentSession() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        if terminalManager.sessions.count > 1 {
            terminalManager.closeSession(at: selectedTab)
            selectedTab = min(selectedTab, terminalManager.sessions.count - 1)
            ToastManager.shared.show("Session closed", type: .info)
        } else {
            ToastManager.shared.show("Cannot close last session", type: .warning)
        }
    }
    
    private func copyOutput() {
        // Post notification to copy selected text from terminal
        // The terminal view will handle the actual copying
        NotificationCenter.default.post(name: .copySelectedText, object: nil)
        ToastManager.shared.show("Copied to clipboard", type: .success)
    }
    
    private func copyAsHTML() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        let html = convertToHTML(session.output)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(html, forType: .html)
        ToastManager.shared.show("Copied as HTML", type: .success)
    }
    
    private func copyAsRTF() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        let font = Font.system(size: 12, weight: .regular, design: .monospaced)
        let attributedString = ANSIParser.parse(session.output, baseFont: font)
        let nsAttributedString = NSAttributedString(attributedString)
        let range = NSRange(location: 0, length: nsAttributedString.length)
        let documentAttributes: [NSAttributedString.DocumentAttributeKey: Any] = [
            .documentType: NSAttributedString.DocumentType.rtf
        ]
        let rtfData = try? nsAttributedString.data(from: range, documentAttributes: documentAttributes)
        if let rtfData = rtfData {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setData(rtfData, forType: .rtf)
            ToastManager.shared.show("Copied as RTF", type: .success)
        }
    }
    
    private func convertToHTML(_ text: String) -> String {
        let escaped = text
            .replacingOccurrences(of: "&", with: "&amp;")
            .replacingOccurrences(of: "<", with: "&lt;")
            .replacingOccurrences(of: ">", with: "&gt;")
        let lines = escaped.components(separatedBy: .newlines)
        let htmlLines = lines.map { "<div>\($0)</div>" }
        return """
        <!DOCTYPE html>
        <html>
        <head>
            <meta charset="UTF-8">
            <style>
                body { font-family: 'Menlo', 'Monaco', monospace; font-size: 12px; background: #1e1e1e; color: #d4d4d4; padding: 10px; }
                div { white-space: pre-wrap; }
            </style>
        </head>
        <body>
        \(htmlLines.joined(separator: "\n"))
        </body>
        </html>
        """
    }
    
    private func pasteToInput() {
        // Delegate to the standard AppKit paste action so behavior matches right‑click Paste
        // and avoids moving potentially huge strings through notifications/state.
        NSApp.sendAction(#selector(NSText.paste(_:)), to: nil, from: nil)
        ToastManager.shared.show("Pasted to input", type: .info)
    }
    
    private func clearScreen() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        session.clearOutput()
        ToastManager.shared.show("Screen cleared", type: .info)
    }
    
    private func showHistory() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        NotificationCenter.default.post(name: .showHistory, object: session)
    }
    
    private func copyLastCommand() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        NotificationCenter.default.post(name: .copyLastCommand, object: session)
        ToastManager.shared.show("Last command copied", type: .success)
    }
    
    private func showSystemInfo() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        NotificationCenter.default.post(name: .showSystemInfo, object: session)
    }
    
    private func showCommandPalette() {
        NotificationCenter.default.post(name: Notification.Name("ProTermShowCommandPalette"), object: nil)
    }
    
    private func quickSearch() {
        showingQuickSearch = true
    }
}

// MARK: - Search & Replace Sheet
struct SearchReplaceSheet: View {
    @Binding var findText: String
    @Binding var replaceText: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 20) {
            Text("Find & Replace")
                .font(.title2)
                .fontWeight(.semibold)
            
            VStack(spacing: 16) {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Find:")
                    TextField("Enter text to find...", text: $findText)
                        .textFieldStyle(.roundedBorder)
                }
                
                VStack(alignment: .leading, spacing: 8) {
                    Text("Replace with:")
                    TextField("Enter replacement text...", text: $replaceText)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Button("Find") {
                        NotificationCenter.default.post(name: .findInTerminal, object: findText)
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                    
                    Button("Replace All") {
                        NotificationCenter.default.post(name: .replaceInTerminal, object: ["find": findText, "replace": replaceText])
                        dismiss()
                    }
                    .buttonStyle(.borderedProminent)
                    
                    Button("Cancel") {
                        dismiss()
                    }
                    .buttonStyle(.bordered)
                }
            }
        }
        .padding()
        .frame(width: 500, height: 300)
    }
}

// MARK: - Quick Search Sheet
struct QuickSearchSheet: View {
    @Binding var searchQuery: String
    @Environment(\.dismiss) private var dismiss
    
    var body: some View {
        VStack(spacing: 16) {
            Text("Quick Search")
                .font(.title2)
                .fontWeight(.semibold)
            
            TextField("Enter search term...", text: $searchQuery)
                .textFieldStyle(.roundedBorder)
                .onSubmit {
                    let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !q.isEmpty else { return }
                    NotificationCenter.default.post(name: .searchInTerminal, object: q)
                    dismiss()
                }
            
            HStack {
                Button("Search") {
                    let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
                    guard !q.isEmpty else { return }
                    NotificationCenter.default.post(name: .searchInTerminal, object: q)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                .disabled(searchQuery.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                
                Button("Cancel") {
                    dismiss()
                }
                .buttonStyle(.bordered)
            }
        }
        .padding()
        .frame(width: 400, height: 200)
    }
}

// MARK: - Enhanced Toolbar Button Component
struct ToolbarButton: View {
    let icon: String
    let help: String
    var isActive: Bool = false
    var iconColor: Color? = nil  // Optional custom color
    let action: () -> Void
    
    @State private var isHovered = false
    
    // Determine the color to use
    private var effectiveColor: Color {
        if let iconColor = iconColor {
            return iconColor
        } else if isActive {
            return .blue
        } else if isHovered {
            return .primary
        } else {
            return .secondary
        }
    }
    
    var body: some View {
        Button(action: action) {
            Image(systemName: icon)
                .font(.system(size: 14, weight: .medium))
                .foregroundColor(effectiveColor)
                .frame(width: 28, height: 28)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(isActive ? effectiveColor.opacity(0.15) : (isHovered ? effectiveColor.opacity(0.1) : Color.clear))
                )
        }
        .buttonStyle(.plain)
        .help(help)
        .onHover { hovering in
            withAnimation(.easeInOut(duration: 0.15)) {
                isHovered = hovering
            }
        }
    }
}

// MARK: - Button Group Component
struct ButtonGroup<Content: View>: View {
    @ViewBuilder let content: Content
    
    var body: some View {
        HStack(spacing: 4) {
            content
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 2)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(NSColor.controlBackgroundColor).opacity(0.5))
        )
    }
}

// MARK: - Notification Names
extension Notification.Name {
    static let pasteToInput = Notification.Name("ProTermPasteToInput")
    static let searchInTerminal = Notification.Name("ProTermSearchInTerminal")
    static let findInTerminal = Notification.Name("ProTermFindInTerminal")
    static let replaceInTerminal = Notification.Name("ProTermReplaceInTerminal")
    static let showHistory = Notification.Name("ProTermShowHistory")
    static let copyLastCommand = Notification.Name("ProTermCopyLastCommand")
    static let findInHistory = Notification.Name("ProTermFindInHistory")
    static let resumeProcess = Notification.Name("ProTermResumeProcess")
    static let showSystemInfo = Notification.Name("ProTermShowSystemInfo")
    static let quickSearch = Notification.Name("ProTermQuickSearch")
    static let copySelectedText = Notification.Name("ProTermCopySelectedText")
}
