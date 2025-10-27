import SwiftUI

struct ButtonBarView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var lineNumbersManager: LineNumbersManager
    @Binding var selectedTab: Int                // from ContentView

    @State private var showingPreferences = false
    @State private var showingSearchReplace = false
    @State private var showingQuickSearch = false
    @State private var searchQuery = ""
    @State private var findText = ""
    @State private var replaceText = ""
    @Environment(\.dismiss) private var dismiss   // not used here, kept for completeness

    var body: some View {
        HStack(spacing: 12) {
            // MARK: - Tab Management
            Button(action: newTab) {
                Image(systemName: "plus.square.on.square")
                    .help("New Tab")
            }

            Button(action: closeCurrentTab) {
                Image(systemName: "xmark.square")
                    .help("Close Current Tab")
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - Copy/Paste
            Button(action: copyOutput) {
                Image(systemName: "doc.on.doc")
                    .help("Copy Output")
            }
            
            Button(action: pasteToInput) {
                Image(systemName: "doc.on.clipboard")
                    .help("Paste to Input")
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - Search & Replace
            HStack(spacing: 4) {
                // Quick search button (just the icon)
                Button(action: quickSearch) {
                    Image(systemName: "magnifyingglass")
                        .help("Quick Search")
                }
                
                // Full search & replace button
                Button(action: { showingSearchReplace.toggle() }) {
                    Image(systemName: "textformat.abc")
                        .help("Search & Replace")
                }
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - Clear Screen
            Button(action: clearScreen) {
                Image(systemName: "trash")
                    .help("Clear Screen")
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - History & Commands
            Button(action: showHistory) {
                Image(systemName: "clock.arrow.circlepath")
                    .help("Command History")
            }
            
            Button(action: copyLastCommand) {
                Image(systemName: "arrow.clockwise")
                    .help("Copy Last Command")
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - Process Management
            Button(action: pauseProcess) {
                Image(systemName: "pause.circle")
                    .help("Pause Process")
            }
            
            Button(action: resumeProcess) {
                Image(systemName: "play.circle")
                    .help("Resume Process")
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - System Info
            Button(action: showSystemInfo) {
                Image(systemName: "info.circle")
                    .help("System Information")
            }
            
            Divider()
                .frame(height: 20)

            // MARK: - Preferences
            Button(action: { showingPreferences.toggle() }) {
                Image(systemName: "gearshape")
                    .help("Preferences…")
            }
        }
        .buttonStyle(.plain)
        .sheet(isPresented: $showingPreferences) {
            PreferencesView()
                .environmentObject(terminalManager)
                .environmentObject(themeManager)
                .environmentObject(shellManager)
                .environmentObject(lineNumbersManager)
        }
        .sheet(isPresented: $showingSearchReplace) {
            SearchReplaceSheet(findText: $findText, replaceText: $replaceText)
        }
        .sheet(isPresented: $showingQuickSearch) {
            QuickSearchSheet(searchQuery: $searchQuery)
        }
        // Listen for the menu‑command notification
        .onReceive(NotificationCenter.default.publisher(for: .showPreferences)) { _ in
            showingPreferences = true
        }
    }

    // MARK: – Actions

    private func newTab() {
        terminalManager.addSession()
        selectedTab = terminalManager.sessions.count - 1
    }

    private func closeCurrentTab() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        if terminalManager.sessions.count > 1 {
            terminalManager.closeSession(at: selectedTab)
            selectedTab = min(selectedTab, terminalManager.sessions.count - 1)
        }
    }
    
    private func copyOutput() {
        // Post notification to copy selected text from terminal
        // The terminal view will handle the actual copying
        NotificationCenter.default.post(name: .copySelectedText, object: nil)
    }
    
    private func pasteToInput() {
        guard let pasteboardString = NSPasteboard.general.string(forType: .string) else { return }
        // Post notification to paste text to the active terminal's input field
        NotificationCenter.default.post(name: .pasteToInput, object: pasteboardString)
    }
    
    private func clearScreen() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        session.clearOutput()
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
    }
    
    private func pauseProcess() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        session.sendSignal(SIGTSTP) // Ctrl+Z equivalent
    }
    
    private func resumeProcess() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        NotificationCenter.default.post(name: .resumeProcess, object: session)
    }
    
    private func showSystemInfo() {
        guard terminalManager.sessions.indices.contains(selectedTab) else { return }
        let session = terminalManager.sessions[selectedTab]
        NotificationCenter.default.post(name: .showSystemInfo, object: session)
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
            
            HStack {
                Button("Search") {
                    NotificationCenter.default.post(name: .searchInTerminal, object: searchQuery)
                    dismiss()
                }
                .buttonStyle(.borderedProminent)
                
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
