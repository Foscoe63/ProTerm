import SwiftUI
import UniformTypeIdentifiers   // needed for UTType

struct ContentView: View {
    @EnvironmentObject var terminalManager: TerminalManager
    @EnvironmentObject var themeManager: ThemeManager
    @EnvironmentObject var shellManager: ShellManager
    @EnvironmentObject var lineNumbersManager: LineNumbersManager
    @EnvironmentObject var keyboardShortcutsManager: KeyboardShortcutsManager

    // The index of the currently‑selected tab.
    @State private var selectedTab = 0

    // Optional global search bar (kept from the original scaffold).
    @State private var searchQuery = ""

    var body: some View {
        VStack(spacing: 0) {
            // MARK: – Button bar (receives the binding to keep tabs in sync)
            ButtonBarView(selectedTab: $selectedTab)
                .padding(.horizontal, 8)
                .frame(height: 40)
                .background(themeManager.current.background.opacity(0.2))

            // MARK: – Optional global search bar
            if !searchQuery.isEmpty {
                SearchBarView(query: $searchQuery)
            }

            // MARK: – Tab view – one tab per session
            TabView(selection: $selectedTab) {
                ForEach(terminalManager.sessions.indices, id: \.self) { index in
                    TerminalView(session: terminalManager.sessions[index])
                        .tabItem {
                            Text("Session \(index + 1)")
                        }
                        .tag(index)
                }
            }
            // Use the standard macOS tab bar style.
            .tabViewStyle(.automatic)
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            // MARK: – Status bar (bottom)
            StatusBarView()
                .frame(height: 22)
                .background(themeManager.current.background.opacity(0.1))
        }
        .onAppear {
            terminalManager.setShellManager(shellManager)
            setupKeyboardShortcuts()
        }
        .keyboardShortcuts(keyboardShortcutsManager)
        // MARK: – Drag‑and‑drop support (read‑only tabs)
        .onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            guard let provider = providers.first else { return false }
            _ = provider.loadObject(ofClass: URL.self) { url, error in
                if let fileURL = url,
                   let content = try? String(contentsOf: fileURL, encoding: .utf8) {
                    DispatchQueue.main.async {
                        let session = TerminalSession(shellManager: shellManager)
                        session.output = content
                        terminalManager.sessions.append(session)
                    }
                }
            }
            return true
        }
    }
    
    // MARK: - Keyboard Shortcuts Setup
    private func setupKeyboardShortcuts() {
        keyboardShortcutsManager.onSelectAll = {
            // Select all terminal output
            NotificationCenter.default.post(name: .selectAllTerminal, object: nil)
        }
        
        keyboardShortcutsManager.onQuickSearch = {
            // Open quick search
            NotificationCenter.default.post(name: .quickSearch, object: nil)
        }
        
        keyboardShortcutsManager.onClearScreen = {
            // Clear current terminal
            if terminalManager.sessions.indices.contains(selectedTab) {
                terminalManager.sessions[selectedTab].clearOutput()
            }
        }
        
        keyboardShortcutsManager.onNewTab = {
            // Create new tab
            terminalManager.addSession()
            selectedTab = terminalManager.sessions.count - 1
        }
        
        keyboardShortcutsManager.onCloseTab = {
            // Close current tab
            if terminalManager.sessions.count > 1 {
                terminalManager.closeSession(at: selectedTab)
                selectedTab = min(selectedTab, terminalManager.sessions.count - 1)
            }
        }
        
        keyboardShortcutsManager.onSwitchTab = { index in
            // Switch to specific tab
            if terminalManager.sessions.indices.contains(index) {
                selectedTab = index
            }
        }
        
        keyboardShortcutsManager.onCopy = {
            // Copy terminal output
            if terminalManager.sessions.indices.contains(selectedTab) {
                let session = terminalManager.sessions[selectedTab]
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(session.output, forType: .string)
            }
        }
        
        keyboardShortcutsManager.onPaste = {
            // Paste to input
            if let pasteboardString = NSPasteboard.general.string(forType: .string) {
                NotificationCenter.default.post(name: .pasteToInput, object: pasteboardString)
            }
        }
        
        keyboardShortcutsManager.onFind = {
            // Open find dialog
            NotificationCenter.default.post(name: .searchInTerminal, object: "")
        }
        
        keyboardShortcutsManager.onReplace = {
            // Open replace dialog
            NotificationCenter.default.post(name: .replaceInTerminal, object: ["find": "", "replace": ""])
        }
    }
}

// MARK: - Additional Notification Names
extension Notification.Name {
    static let selectAllTerminal = Notification.Name("ProTermSelectAllTerminal")
}

// MARK: – Preview
struct ContentView_Previews: PreviewProvider {
    static var previews: some View {
        ContentView()
            .environmentObject(TerminalManager())
            .environmentObject(ThemeManager())
    }
}
