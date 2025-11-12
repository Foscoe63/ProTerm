import SwiftUI
import Foundation

#if os(macOS)
import AppKit          // Needed for NSApp, NSPasteboard and NSTextView
#endif

/// Ultra‑minimal TerminalView with ZERO complexity
@MainActor
struct TerminalView: View {
    @ObservedObject var session: TerminalSession
    @State private var commandInput: String = ""
    @State private var passwordInput: String = ""
    @State private var showPasswordInput: Bool = false
    @State private var searchQuery: String = ""
    @State private var selectedOutput: String = ""          // tracks current selection
    @FocusState private var commandFieldIsFocused: Bool     // ← focus‑state for the TextField
    @FocusState private var passwordFieldIsFocused: Bool    // ← focus‑state for password field
    @State private var hasRequestedInitialFocus = false     // Track if we've set initial focus
    @State private var cachedAttributedOutput: AttributedString = AttributedString("")
    
    @EnvironmentObject private var lineNumbersManager: LineNumbersManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var fontManager: FontManager
    @EnvironmentObject private var advancedFeatures: AdvancedFeatures
    @EnvironmentObject private var productivityTools: ProductivityTools
    @EnvironmentObject private var terminalManager: TerminalManager
    @EnvironmentObject private var visualSettings: TerminalVisualSettings

    // History UI state
    @State private var showingHistorySheet: Bool = false
    
    // Auto-completion state
    @State private var currentCompletions: [String] = []
    @State private var currentCompletionIndex: Int = 0
    @State private var lastCompletionInput: String = ""
    
    // Command history navigation
    @State private var historyIndex: Int = -1
    @State private var historySearchInput: String = ""
    
    // Enhanced search state
    @State private var useRegex: Bool = false
    @State private var searchHistory: [String] = []

    // Submit command helper (used by both onCommit and onSubmit)
    private func submitCommand() {
        let cmd = commandInput
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { 
            // Clear input even if empty
            commandInput = ""
            // Still restore focus even for empty commands
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                commandFieldIsFocused = true
                // Also broadcast a focus request to ensure AppKit first responder is set
                NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
            }
            return 
        }
        
        // Don't allow new commands if process is running (unless it has active PTY)
        // On first command, isProcessRunning should be false, so this should pass
        guard !session.isProcessRunning || session.hasActivePTY else { 
            // Restore focus even if command can't run
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                commandFieldIsFocused = true
                NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
            }
            return 
        }
        // Clear input immediately before running command
        // This ensures the field is cleared even if runCommand takes time
        commandInput = ""
        // Ensure password UI is hidden when starting a new command
        showPasswordInput = false
        // Expand aliases and bookmarks before running command
        var expandedCommand = advancedFeatures.expandAlias(trimmed)
        expandedCommand = expandBookmarkInCommand(expandedCommand)
        session.runCommand(expandedCommand)
        // Return focus to the field after running (with delay to ensure view has updated)
        // Use a longer delay to ensure all output updates have completed
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
            commandFieldIsFocused = true
            NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
            // Also try again after a bit more time in case output is still updating
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        commandFieldIsFocused = true
                NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
            }
        }
    }
    
    // Expand bookmark names in cd commands
    private func expandBookmarkInCommand(_ command: String) -> String {
        if command.hasPrefix("cd ") {
            let target = String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
            // Check if target matches a bookmark name
            if let bookmark = productivityTools.bookmarks.first(where: { $0.name.lowercased() == target.lowercased() }) {
                productivityTools.useBookmark(bookmark)
                return "cd \(bookmark.path)"
            }
        }
        return command
    }

    // MARK: - View Body
    
    var body: some View {
        terminalOutputArea
        .onAppear {
            // CRITICAL: Request initial focus immediately
            if !hasRequestedInitialFocus {
                hasRequestedInitialFocus = true
                commandFieldIsFocused = true
            }
            
            // Start attempting focus immediately and with retries
            forceFocus()
            
            // Retry sequence to handle window activation delays
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1s
                forceFocus()
                try? await Task.sleep(nanoseconds: 400_000_000) // 0.5s
                forceFocus()
                try? await Task.sleep(nanoseconds: 500_000_000) // 1.0s
                forceFocus()
            }
        }
        .background(WindowAccessor()) // Add WindowAccessor for robust window-level focus handling
        // Listen for window becoming key to set focus - this is the most reliable trigger
        .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
            // When window becomes key, ensure focus is set
            // Check if this notification is for our window
            if let window = notification.object as? NSWindow,
               let myWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow,
               window === myWindow {
                // Use forceFocus to ensure all focus mechanisms are triggered
                forceFocus()
            }
        }
        // (Removed early, duplicate focus listener. Focus is handled below with target filtering.)
        // Detect password prompts in output
        .onChange(of: session.output) { _, _ in
            checkForPasswordPrompt()
        }
        // Also check when process running state changes
        .onChange(of: session.isProcessRunning) { _, isRunning in
            if !isRunning && showPasswordInput {
                // Process finished, hide password input
                showPasswordInput = false
                passwordInput = ""
                commandFieldIsFocused = true
            }
        }
        // Listen for search notifications from the button bar
        .onReceive(NotificationCenter.default.publisher(for: .searchInTerminal)) { notification in
            if let query = notification.object as? String {
                searchQuery = query
                updateCachedAttributedOutput()
            }
        }
        // Listen for find notifications (same as search - just highlights)
        .onReceive(NotificationCenter.default.publisher(for: .findInTerminal)) { notification in
            if let query = notification.object as? String {
                searchQuery = query
                updateCachedAttributedOutput()
            }
        }
        // Listen for replace notifications
        .onReceive(NotificationCenter.default.publisher(for: .replaceInTerminal)) { notification in
            if let dict = notification.object as? [String: String],
               let findText = dict["find"],
               let replaceText = dict["replace"] {
                performReplace(find: findText, replace: replaceText)
            }
        }
        // Listen for copy selected text notification from button bar
        .onReceive(NotificationCenter.default.publisher(for: .copySelectedText)) { _ in
            // Send copy action to first responder (works with SwiftUI Text view selection)
            NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
        }
        // Listen for paste to input notification from button bar
        .onReceive(NotificationCenter.default.publisher(for: .pasteToInput)) { notification in
            // Ensure UI updates occur on the main thread
            DispatchQueue.main.async {
                if let dict = notification.object as? [String: Any] {
                    if let target = dict["session"] as? TerminalSession, target === session,
                       let text = dict["text"] as? String {
                        applyPaste(text)
                        return
                    } else {
                        return
                    }
                }
                if let textToPaste = notification.object as? String {
                    applyPaste(textToPaste)
                }
            }
        }
        // Listen for redo last command
        .onReceive(NotificationCenter.default.publisher(for: .copyLastCommand)) { note in
            // Check if this notification is for this session (by ID to be safe)
            if let target = note.object as? TerminalSession, target.id == session.id {
                applyRedo()
            }
        }
        // Listen for focus command input (targeted by session UUID, or nil for current session)
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ProTermFocusCommandInput"))) { note in
            // If notification has a specific session ID, only focus if it matches
            // If notification has nil (no specific session), focus this session
            let shouldFocus: Bool
            if let targetId = note.object as? UUID {
                shouldFocus = targetId == session.id
            } else {
                // No specific session ID - focus this session (useful for startup)
                shouldFocus = true
            }
            
            if shouldFocus {
                // Simple and direct - just set focus immediately
                DispatchQueue.main.async {
                    // If a password prompt is visible, do NOT steal focus for the command field
                    guard !self.showPasswordInput else { return }
                    NSApp.activate(ignoringOtherApps: true)
                    let window = NSApplication.shared.mainWindow
                        ?? NSApplication.shared.keyWindow
                        ?? NSApp.windows.first
                    window?.makeKeyAndOrderFront(nil)
                    self.commandFieldIsFocused = true
                    // Also try to focus directly via AppKit
                    if let window = window, let contentView = window.contentView {
                        self.focusCommandFieldInView(contentView)
                    }
                }
            }
        }
        // Listen for command history sheet
        .onReceive(NotificationCenter.default.publisher(for: .showHistory)) { note in
            // Check if this notification is for this session (by ID to be safe)
            if let target = note.object as? TerminalSession, target.id == session.id {
                presentHistoryIfNeeded()
            }
        }
        // Listen for system info notification
        .onReceive(NotificationCenter.default.publisher(for: .showSystemInfo)) { note in
            // Check if this notification is for this session (by ID to be safe)
            if let target = note.object as? TerminalSession, target.id == session.id {
                showSystemInfo()
            }
        }
        .sheet(isPresented: $showingHistorySheet) {
            EnhancedHistorySheetView(session: session, onPick: { cmd in
                showingHistorySheet = false
                // End editing first to ensure updateNSView can update the text field
                if let window = NSApplication.shared.keyWindow {
                    window.makeFirstResponder(nil)
                }
                // Wait a moment for editing to end and sheet to dismiss, then set the command
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Set the command input
                    self.commandInput = cmd
                    // Restore focus after a brief delay to ensure the update has completed
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        // Ensure window is key
                        if let window = NSApplication.shared.mainWindow {
                            NSApp.activate(ignoringOtherApps: true)
                            window.makeKeyAndOrderFront(nil)
                        }
                        // Set focus binding
                        self.commandFieldIsFocused = true
                        // Also try to directly focus the text field
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                            self.commandFieldIsFocused = true
                        }
                    }
                }
            })
            .frame(width: 600, height: 400)
        }
        // Listen for terminal bell
        .onReceive(NotificationCenter.default.publisher(for: Notification.Name("ProTermTerminalBell"))) { notification in
            if let sessionId = notification.object as? UUID, sessionId == session.id {
                handleTerminalBell()
            }
        }
    }
    
    // MARK: - Terminal Output Area
    
    private var terminalOutputArea: some View {
        let backgroundColor = themeManager.current.background
        
        return GeometryReader { geo in
                ZStack {
                    // Background
                    backgroundColor
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Output + line numbers
                    HStack(alignment: .top, spacing: 0) {
                        scrollContent(geo: geo)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .onTapGesture { /* bullet‑proof – do nothing */ }
                .onAppear {
                    // Update terminal width when view appears
                    let lineNumbersWidth = lineNumbersManager.showLineNumbers ? 60.0 : 0.0
                    session.terminalWidth = geo.size.width - lineNumbersWidth
                }
                .onChange(of: geo.size.width) { _, newWidth in
                    // Update terminal width when view resizes
                    let lineNumbersWidth = lineNumbersManager.showLineNumbers ? 60.0 : 0.0
                    session.terminalWidth = newWidth - lineNumbersWidth
                }
                .onChange(of: lineNumbersManager.showLineNumbers) { _, _ in
                    // Update terminal width when line numbers toggle
                    let lineNumbersWidth = lineNumbersManager.showLineNumbers ? 60.0 : 0.0
                    session.terminalWidth = geo.size.width - lineNumbersWidth
                }
            }
    }
    
    // MARK: - Scroll Content
    
    @ViewBuilder
    private func scrollContent(geo: GeometryProxy) -> some View {
        ScrollViewReader { proxy in
            ZStack(alignment: .topTrailing) {
                scrollViewContent(geo: geo, proxy: proxy)
                processIndicatorOverlay
            }
        }
    }
    
    @ViewBuilder
    private func scrollViewContent(geo: GeometryProxy, proxy: ScrollViewProxy) -> some View {
        ScrollView(.vertical) {
            VStack(alignment: .leading, spacing: 0) {
                outputLineWithNumbers
                commandInputArea
                Color.clear.frame(height: 1).id("BOTTOM")
            }
        }
        .scrollIndicators(.visible)
        .onChange(of: session.output) { _, _ in
            updateCachedAttributedOutput()
            DispatchQueue.main.async {
                withAnimation(.easeOut(duration: 0.15)) {
                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                }
            }
        }
        .onChange(of: commandFieldIsFocused) { _, isFocused in
            if isFocused {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("command-input", anchor: .bottom)
                    }
                }
            }
        }
        .onChange(of: passwordFieldIsFocused) { _, isFocused in
            if isFocused {
                DispatchQueue.main.async {
                    withAnimation(.easeOut(duration: 0.15)) {
                        proxy.scrollTo("password-input", anchor: .bottom)
                    }
                }
            }
        }
        .onChange(of: searchQuery) { _, _ in
            updateCachedAttributedOutput()
        }
        .onChange(of: fontManager.fontName) { _, _ in
            updateCachedAttributedOutput()
        }
        .onChange(of: fontManager.fontSize) { _, _ in
            updateCachedAttributedOutput()
        }
        .onAppear {
            updateCachedAttributedOutput()
            DispatchQueue.main.async {
                proxy.scrollTo("BOTTOM", anchor: .bottom)
                commandFieldIsFocused = true
            }
        }
        .frame(width: geo.size.width, height: geo.size.height)
        .clipped()
    }
    
    @ViewBuilder
    private var outputLineWithNumbers: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if lineNumbersManager.showLineNumbers {
                LineNumbersView(attributedText: highlightedAttributedOutput, font: fontManager.font)
                    .font(fontManager.font)
                    .foregroundColor(.gray)
                    .frame(width: 43, alignment: .trailing)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
            }
            terminalOutputText
        }
    }
    
    @ViewBuilder
    private var commandInputArea: some View {
        if showPasswordInput {
            passwordInputView
        } else {
            regularCommandInputView
        }
    }
    
    @ViewBuilder
    private var passwordInputView: some View {
        HStack(alignment: .center, spacing: 0) {
            if lineNumbersManager.showLineNumbers {
                Text("\(calculateCommandInputLineNumber())")
                    .font(fontManager.font)
                    .foregroundColor(.gray)
                    .frame(width: 43, alignment: .trailing)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
            }
            HStack(spacing: 4) {
                Text("Password: ")
                    .font(fontManager.font)
                    .foregroundColor(.yellow)
                
                SecureField("Enter password", text: $passwordInput)
                    .focused($passwordFieldIsFocused)
                    .onSubmit {
                        let password = passwordInput
                        passwordInput = ""
                        if !password.isEmpty {
                            session.sendInput(password + "\n")
                            DispatchQueue.main.async {
                                NSApp.activate(ignoringOtherApps: true)
                                passwordFieldIsFocused = true
                            }
                        }
                    }
                    .submitLabel(.return)
                    .textFieldStyle(PlainTextFieldStyle())
                    .font(fontManager.font)
                    .foregroundColor(themeManager.current.foreground)
                    .autocorrectionDisabled()
                    .disabled(!session.isProcessRunning && showPasswordInput)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 4)
            Spacer()
        }
        .id("password-input")
    }
    
    @ViewBuilder
    private var regularCommandInputView: some View {
        HStack(alignment: .firstTextBaseline, spacing: 0) {
            if lineNumbersManager.showLineNumbers {
                Text("\(calculateCommandInputLineNumber())")
                    .font(fontManager.font)
                    .foregroundColor(.gray)
                    .frame(width: 43, alignment: .trailing)
                    .padding(.trailing, 6)
                    .padding(.vertical, 4)
            }
            
            HStack(alignment: .firstTextBaseline, spacing: 4) {
                Text(session.prompt)
                    .font(fontManager.font)
                    .foregroundColor(themeManager.current.foreground)
                
                CustomTextField(
                    text: $commandInput,
                    placeholder: "",
                    font: NSFont(name: fontManager.fontName, size: fontManager.fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontManager.fontSize, weight: .regular),
                    textColor: NSColor(themeManager.current.foreground),
                    cursorStyle: visualSettings.cursorStyle,
                    cursorBlinking: visualSettings.cursorBlinking,
                    onSubmit: {
                        let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                        let activePTY = session.hasActivePTY
                        if activePTY {
                            session.sendInput(commandInput + "\n")
                            commandInput = ""
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                commandFieldIsFocused = true
                                NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
                            }
                        } else if !cmd.isEmpty {
                            submitCommand()
                        }
                        historyIndex = -1
                        historySearchInput = ""
                    },
                    onTab: {
                        handleTabCompletion()
                        return true
                    },
                    onUpArrow: {
                        navigateHistory(up: true)
                        return true
                    },
                    onDownArrow: {
                        navigateHistory(up: false)
                        return true
                    },
                    isFocused: Binding(
                        get: { commandFieldIsFocused },
                        set: { commandFieldIsFocused = $0 }
                    )
                )
                .id("\(visualSettings.cursorStyle.rawValue)-\(visualSettings.cursorBlinking)")
                .disabled(false)
                .onChange(of: commandInput) { oldValue, newValue in
                    if newValue != lastCompletionInput {
                        currentCompletions = []
                        currentCompletionIndex = 0
                    }
                    if !newValue.isEmpty && historyIndex >= 0 {
                        historyIndex = -1
                        historySearchInput = ""
                    }
                }
            }
            .padding(.leading, lineNumbersManager.showLineNumbers ? 0 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .id("command-input")
        .onAppear {
            NSApp.activate(ignoringOtherApps: true)
            let window = NSApplication.shared.mainWindow
                ?? NSApplication.shared.keyWindow
                ?? NSApp.windows.first
            window?.makeKeyAndOrderFront(nil)
            commandFieldIsFocused = true
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                NSApp.activate(ignoringOtherApps: true)
                let window = NSApplication.shared.mainWindow
                    ?? NSApplication.shared.keyWindow
                    ?? NSApp.windows.first
                window?.makeKeyAndOrderFront(nil)
                commandFieldIsFocused = true
            }
        }
        .onChange(of: session.isProcessRunning) { oldValue, newValue in
            if oldValue == true && newValue == false {
                commandInput = ""
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                    commandFieldIsFocused = true
                    NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        commandFieldIsFocused = true
                        NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
                    }
                }
            }
        }
        .onChange(of: session.output) { _, _ in
            if !session.isProcessRunning && commandFieldIsFocused {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                    if !session.isProcessRunning && commandFieldIsFocused {
                        commandFieldIsFocused = true
                    }
                }
            }
        }
    }
    
    @ViewBuilder
    private var processIndicatorOverlay: some View {
        if session.isProcessRunning {
            VStack {
                HStack(spacing: 6) {
                    ProgressView()
                        .scaleEffect(0.7)
                        .frame(width: 14, height: 14)
                    Text("Running")
                        .font(.caption2)
                        .foregroundColor(.secondary)
                }
                .padding(.horizontal, 8)
                .padding(.vertical, 4)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color(NSColor.controlBackgroundColor).opacity(0.9))
                        .shadow(color: .black.opacity(0.1), radius: 2, x: 0, y: 1)
                )
                Spacer()
            }
            .padding(.top, 8)
            .padding(.trailing, 8)
            .transition(.opacity.combined(with: .scale))
        }
    }
    
    // MARK: - Command Input Area (removed - now inline in terminal output)
    
    // Old commandInputArea removed - command input is now inline in terminalOutputArea
    // Keeping this comment for reference
    /*
    @ViewBuilder
    private var commandInputArea: some View {
        if showPasswordInput {
                // Password input for sudo commands
            HStack {
                    Text("Password: ")
                        .font(fontManager.font)
                        .foregroundColor(.yellow)

                    SecureField("Enter password", text: $passwordInput)
                        .focused($passwordFieldIsFocused)
                        .onSubmit {
                            let password = passwordInput
                            passwordInput = ""
                            if !password.isEmpty {
                                // Send password to the PTY
                                session.sendInput(password + "\n")
                                // Keep password input visible until process completes
                                // (don't hide immediately in case of wrong password)
                            }
                        }
                    .submitLabel(.return)
                    .textFieldStyle(PlainTextFieldStyle())
                        .font(fontManager.font)
                    .foregroundColor(themeManager.current.foreground)
                    .autocorrectionDisabled()
                        .disabled(!session.isProcessRunning && showPasswordInput)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(themeManager.current.background)
                .onAppear {
                    passwordFieldIsFocused = true
                }
            } else {
                // Regular command input
                HStack {
                    Text(session.prompt)
                        .font(fontManager.font)
                        .foregroundColor(themeManager.current.foreground)

                    CustomTextField(
                        text: $commandInput,
                        placeholder: "Enter command",
                        font: NSFont(name: fontManager.fontName, size: fontManager.fontSize) ?? NSFont.monospacedSystemFont(ofSize: fontManager.fontSize, weight: .regular),
                        textColor: NSColor(themeManager.current.foreground),
                        cursorStyle: visualSettings.cursorStyle,
                        cursorBlinking: visualSettings.cursorBlinking,
                        onSubmit: {
                            // Capture the command before clearing
                            let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
                            
                            // If we have an active PTY (interactive process), send input to it
                            if session.hasActivePTY {
                                session.sendInput(commandInput + "\n")
                                commandInput = ""
                                // Restore focus after a delay to ensure view has updated
                                DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                                    commandFieldIsFocused = true
                                    // Also try again after a bit more time
                                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                        commandFieldIsFocused = true
                                    }
                                }
                            } else if !cmd.isEmpty {
                                // Run as a new command (submitCommand already handles focus restoration)
                                submitCommand()
                            }
                            // Reset history navigation after submitting
                            historyIndex = -1
                            historySearchInput = ""
                        },
                        onTab: {
                            handleTabCompletion()
                            return true
                        },
                        onUpArrow: {
                            navigateHistory(up: true)
                            return true
                        },
                        onDownArrow: {
                            navigateHistory(up: false)
                            return true
                        },
                        isFocused: Binding(
                            get: { commandFieldIsFocused },
                            set: { commandFieldIsFocused = $0 }
                        )
                    )
                    // Force view refresh when cursor style or blinking changes
                    .id("\(visualSettings.cursorStyle.rawValue)-\(visualSettings.cursorBlinking)")
                    // CRITICAL: Set focused to true to ensure initial focus on app launch
                    .focused($commandFieldIsFocused)
                    // Allow typing even while a background/non‑PTY process runs
                    // (password mode is handled separately above)
                    .disabled(false)
                    .onAppear {
                        // Restore focus when view appears - use multiple attempts with delays
                        // First ensure window is key
                        DispatchQueue.main.async {
                            NSApp.activate(ignoringOtherApps: true)
                            if let window = NSApplication.shared.mainWindow {
                                window.makeKeyAndOrderFront(nil)
                            }
                        }
                        // Try with multiple delays to ensure the view is ready
                        for delay in [0.05, 0.1, 0.2, 0.3] {
                            DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                                commandFieldIsFocused = true
                                NSApp.activate(ignoringOtherApps: true)
                                if let window = NSApplication.shared.mainWindow {
                                    window.makeKeyAndOrderFront(nil)
                                    // Also try direct AppKit focus via the focus helper
                                    if let contentView = window.contentView {
                                        self.focusCommandFieldInView(contentView)
                                    }
                                    // Post notification to trigger focus as well
                                    NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
                                }
                            }
                        }
                    }
                    .onChange(of: commandInput) { oldValue, newValue in
                        // Reset completions when input changes
                        if newValue != lastCompletionInput {
                            currentCompletions = []
                            currentCompletionIndex = 0
                        }
                        // Reset history navigation when user types
                        if !newValue.isEmpty && historyIndex >= 0 {
                            historyIndex = -1
                            historySearchInput = ""
                        }
                    }
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(themeManager.current.background)
            // Ensure clicks anywhere on the command row focus the input field
            .contentShape(Rectangle())
            .onTapGesture { forceFocus() }
                .onChange(of: session.isProcessRunning) { oldValue, newValue in
                    // When process finishes, clear the input and refocus the field
                    if oldValue == true && newValue == false {
                        commandInput = ""
                        // Restore focus with a delay to ensure view has updated
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                            commandFieldIsFocused = true
                            // Also try again after a bit more time in case output is still updating
                            DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                                commandFieldIsFocused = true
                            }
                        }
                    }
                }
                // Also restore focus when output changes (after command completes)
                // Use a debounced approach to avoid constant focus restoration
                .onChange(of: session.output) { _, _ in
                    // Only restore focus if we're not currently running a process
                    // and focus is supposed to be on the command field
                    // This helps restore focus after output updates complete
                    if !session.isProcessRunning && commandFieldIsFocused {
                        // Cancel any previous pending focus restoration
                        // Use a longer delay to debounce rapid output updates
                        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                            // Double-check conditions before restoring focus
                            if !session.isProcessRunning && commandFieldIsFocused {
                                commandFieldIsFocused = true
                            }
                        }
                    }
                }
            }
    }
    */

    // MARK: - Terminal Output Text View
    
    private var terminalOutputText: some View {
        Text(highlightedAttributedOutput)
            .textSelection(.enabled)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.leading, lineNumbersManager.showLineNumbers ? 0 : 10)
            .padding(.trailing, 10)
            .padding(.vertical, 4)
            .font(fontManager.font)
            .foregroundColor(themeManager.current.foreground)
            .id("output-\(session.id.uuidString)") // Ensure output is tied to this session
    }

    // MARK: - ANSI‑parsed Output with Search Highlights
    
    @MainActor               // Guarantees main‑thread execution
    private var highlightedAttributedOutput: AttributedString {
        // Just return the cached value - updates happen in onChange
        return cachedAttributedOutput
    }
    
    // Helper to forcefully set focus
    @MainActor
    private func forceFocus() {
        // 1. Activate the app
        NSApp.activate(ignoringOtherApps: true)
        
        // 2. Find the window
        let window = NSApplication.shared.mainWindow 
            ?? NSApplication.shared.keyWindow 
            ?? NSApp.windows.first
            
        if let window = window {
            // 3. Make window key and visible
            window.makeKeyAndOrderFront(nil)
            
            // 4. Set SwiftUI focus state
            self.commandFieldIsFocused = true
            
            // 5. Direct AppKit focus (most reliable)
            if let contentView = window.contentView {
                self.focusCommandFieldInView(contentView)
            }
        }
    }

    // Helper to find and focus the command field directly via AppKit
    @MainActor
    private func focusCommandFieldInView(_ view: NSView) {
        // Find the editable NSTextField (command input)
        guard let textField = findTextField(in: view) else { return }
        // Ensure the text field is attached to a window and that window matches the container's window
        guard let tfWindow = textField.window else { return }
        guard let containerWindow = view.window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else { return }
        guard tfWindow === containerWindow else {
            // Do not try to make a control in a different window the first responder
            return
        }
        tfWindow.initialFirstResponder = textField
        NSApp.activate(ignoringOtherApps: true)
        tfWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            if tfWindow.makeFirstResponder(textField), let editor = textField.currentEditor() {
                tfWindow.makeFirstResponder(editor)
            }
        }
    }

    // Helper to find and focus the password field directly via AppKit
    @MainActor
    private func focusPasswordFieldInView(_ view: NSView) {
        guard let pwdField = findSecureTextField(in: view) else { return }
        guard let tfWindow = pwdField.window else { return }
        guard let containerWindow = view.window ?? NSApplication.shared.keyWindow ?? NSApplication.shared.mainWindow else { return }
        guard tfWindow === containerWindow else { return }
        tfWindow.initialFirstResponder = pwdField
        NSApp.activate(ignoringOtherApps: true)
        tfWindow.makeKeyAndOrderFront(nil)
        DispatchQueue.main.async {
            _ = tfWindow.makeFirstResponder(pwdField)
            if let editor = pwdField.currentEditor() {
                tfWindow.makeFirstResponder(editor)
            }
        }
    }
    
    // Helper to find the text field
    @MainActor
    private func findTextField(in view: NSView) -> NSTextField? {
        if let textField = view as? NSTextField, textField.isEditable {
            // Check if it's a CustomNSTextField or just any editable text field
            if textField.window != nil && textField.superview != nil && !textField.isHidden {
                return textField
            }
        }
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        return nil
    }

    // Helper to find the secure text field (password input)
    @MainActor
    private func findSecureTextField(in view: NSView) -> NSSecureTextField? {
        if let field = view as? NSSecureTextField, field.isEditable {
            if field.window != nil && field.superview != nil && !field.isHidden {
                return field
            }
        }
        for subview in view.subviews {
            if let found: NSSecureTextField = findSecureTextField(in: subview) {
                return found
            }
        }
        return nil
    }
    
    // Calculate line number for command input (output lines + 1)
    private func calculateCommandInputLineNumber() -> Int {
        let text = String(highlightedAttributedOutput.characters)
        var workingText = text
        
        // Remove ALL trailing newlines
        while workingText.hasSuffix("\n") || workingText.hasSuffix("\r\n") || workingText.hasSuffix("\r") {
            if workingText.hasSuffix("\r\n") {
                workingText = String(workingText.dropLast(2))
            } else if workingText.hasSuffix("\n") {
                workingText = String(workingText.dropLast(1))
            } else if workingText.hasSuffix("\r") {
                workingText = String(workingText.dropLast(1))
            }
        }
        
        if workingText.isEmpty {
            // No output yet, first line number for command input
            return 1
        }
        
        // Output line count is number of newlines + 1 (after trimming trailing newlines)
        // The command input should appear on the NEXT line, so add one more
        let outputLines = workingText.filter { $0 == "\n" }.count + 1
        return outputLines + 1
    }
    
    // Helper to update the cached attributed output
    private func updateCachedAttributedOutput() {
        // Ensure we're using the correct session's output
        let sessionOutput = session.output
        var attributed = ANSIParser.parse(sessionOutput, baseFont: fontManager.font)
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !q.isEmpty {
            if useRegex {
                // Use regex matching
                do {
                    let regex = try NSRegularExpression(pattern: q, options: .caseInsensitive)
                    let nsString = String(attributed.characters)
                    let range = NSRange(location: 0, length: nsString.utf16.count)
                    
                    regex.enumerateMatches(in: nsString, options: [], range: range) { match, _, _ in
                        guard let match = match else { return }
                        if let matchRange = Range(match.range, in: attributed) {
                            attributed[matchRange].backgroundColor = Color.yellow.opacity(0.35)
                        }
                    }
                } catch {
                    // Invalid regex, fall back to simple search
                    var cursor = attributed.startIndex
                    while cursor < attributed.endIndex {
                        let slice = attributed[cursor..<attributed.endIndex]
                        if let localRange = slice.range(of: q, options: .caseInsensitive) {
                            let matchRange = localRange
                            attributed[matchRange].backgroundColor = Color.yellow.opacity(0.35)
                            cursor = matchRange.upperBound
                        } else {
                            break
                        }
                    }
                }
            } else {
                // Simple string matching
        var cursor = attributed.startIndex
        while cursor < attributed.endIndex {
            let slice = attributed[cursor..<attributed.endIndex]
            if let localRange = slice.range(of: q, options: .caseInsensitive) {
                let matchRange = localRange
                attributed[matchRange].backgroundColor = Color.yellow.opacity(0.35)
                cursor = matchRange.upperBound
            } else {
                break
            }
        }
            }
            
            // Add to search history if not already present
            if !searchHistory.contains(q) {
                searchHistory.insert(q, at: 0)
                if searchHistory.count > 20 {
                    searchHistory.removeLast()
                }
            }
        }
        
        cachedAttributedOutput = attributed
    }
    
    // MARK: - Password Prompt Detection
    
    private func checkForPasswordPrompt() {
        // Only check for password prompts if we're running a sudo command
        // Check if the last command was a sudo command by looking at recent output
        let output = session.output
        let lines = output.components(separatedBy: .newlines)
        let recentLines = lines.suffix(5).joined(separator: "\n")
        let recentLinesLower = recentLines.lowercased()
        
        // Only show password prompt if we see a sudo command in recent output (case-insensitive)
        // Check for "sudo" at word boundaries to avoid false matches
        let hasSudoCommand = recentLinesLower.contains("sudo ") || 
                            recentLinesLower.contains(" sudo") ||
                            recentLinesLower.hasPrefix("sudo") ||
                            recentLinesLower.contains("\nsudo")
        
        // Check if the last non-empty line ends with a password prompt
        let lastNonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        let lastLine = lastNonEmptyLines.last?.lowercased() ?? ""
        
        // Password prompt should be at the end of a line (not in the middle of text)
        let hasPasswordPrompt = hasSudoCommand && session.isProcessRunning && 
                               (lastLine.hasSuffix("password:") || 
                                lastLine.contains("password for") ||
                                recentLinesLower.contains("\npassword:") ||
                                recentLinesLower.contains("password for "))
        
        // Check if password was accepted.
        // Important: we no longer append the prompt to output, so do NOT rely on session.prompt presence.
        // Consider password accepted when the password prompt disappears OR the process ends.
        let passwordAccepted = showPasswordInput && (!hasPasswordPrompt || !session.isProcessRunning)
        
        if hasPasswordPrompt {
            // Show password input if we detect a sudo password prompt
            if !showPasswordInput {
                showPasswordInput = true
            }
            // Force focus on password field and bring window to front
            DispatchQueue.main.async {
                NSApp.activate(ignoringOtherApps: true)
                let window = NSApplication.shared.mainWindow
                    ?? NSApplication.shared.keyWindow
                    ?? NSApp.windows.first
                window?.makeKeyAndOrderFront(nil)
                passwordFieldIsFocused = true
                // Ensure command field does not steal focus while password is needed
                commandFieldIsFocused = false
                if let contentView = window?.contentView {
                    // Focus the password field explicitly, but only if it's in the same window
                    self.focusPasswordFieldInView(contentView)
                }
            }
        } else if passwordAccepted && showPasswordInput {
            // Hide password input if:
            // 1. Process completed, OR
            // 2. Password was accepted (prompt is gone and we see output/prompt)
            showPasswordInput = false
            passwordInput = ""
            // Restore focus to command field. Even if the process is still running
            // (after successful sudo), we want the caret visible in the command line.
            DispatchQueue.main.async {
                commandFieldIsFocused = true
                NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
            }
        }
    }
    
    // Helper to perform find and replace in the terminal output
    private func performReplace(find: String, replace: String) {
        let trimmedFind = find.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedFind.isEmpty else { return }
        
        // Replace all occurrences in the session output (case-insensitive)
        let originalOutput = session.output
        let replacedOutput = originalOutput.replacingOccurrences(of: trimmedFind, with: replace, options: .caseInsensitive)
        
        if replacedOutput != originalOutput {
            // Update the session output
            session.output = replacedOutput
            
            // Clear search query and update cache
            searchQuery = ""
            updateCachedAttributedOutput()
        }
    }

    // MARK: - MainActor helpers for toolbar actions
    @MainActor
    private func applyPaste(_ original: String) {
        // Clamp pasted size to prevent runaway memory usage in the TextField
        let maxPaste = 4096
        var paste = original
        if paste.count > maxPaste {
            paste = String(paste.prefix(maxPaste))
        }
        // Convert newlines to spaces to keep input single-line and avoid large layout churn
        paste = paste.replacingOccurrences(of: "\r", with: " ")
                     .replacingOccurrences(of: "\n", with: " ")
        // Also cap total command input length
        let maxTotal = 8192
        if commandInput.count + paste.count > maxTotal {
            let remaining = max(0, maxTotal - commandInput.count)
            let clipped = String(paste.prefix(remaining))
            commandInput += clipped
        } else {
            commandInput += paste
        }
        commandFieldIsFocused = true
    }

    @MainActor
    private func applyRedo() {
        if let last = session.lastCommand, !last.isEmpty {
            // End editing first to ensure updateNSView can update the text field
            if let window = NSApplication.shared.keyWindow {
                window.makeFirstResponder(nil)
            }
            // Wait a moment for editing to end, then set the command
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                // Set the command input
                self.commandInput = last
                // Restore focus after a brief delay to ensure the update has completed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Ensure window is key
                    if let window = NSApplication.shared.mainWindow {
                        NSApp.activate(ignoringOtherApps: true)
                        window.makeKeyAndOrderFront(nil)
                    }
                    // Set focus binding
                    self.commandFieldIsFocused = true
                    // Also try to directly focus the text field (multiple attempts like history sheet)
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                        self.commandFieldIsFocused = true
                    }
                    // One more attempt to ensure focus
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
                        self.commandFieldIsFocused = true
                    }
                }
            }
        }
    }

    @MainActor
    private func presentHistoryIfNeeded() {
        showingHistorySheet = true
    }
    
    @MainActor
    private func showSystemInfo() {
        let info = session.getSystemInfo()
        // Append system info to output with proper formatting
        var textToAppend = ""
        if !session.output.hasSuffix("\n") {
            textToAppend = "\n"
        }
        textToAppend += info + "\n"
        session.appendOutput(textToAppend)
    }
    
    @MainActor
    private func handleTerminalBell() {
        let sessionName = terminalManager.getTabMetadata(for: session.id).name
        BellFeedbackManager.shared.triggerBell(
            in: NSApplication.shared.mainWindow,
            sessionName: sessionName,
            settings: visualSettings
        )
    }
    
    // MARK: - Auto-completion
    
    @MainActor
    private func navigateHistory(up: Bool) {
        let history = session.commandHistory
        guard !history.isEmpty else { return }
        
        if historyIndex == -1 {
            // Starting navigation - save current input
            historySearchInput = commandInput
        }
        
        if up {
            // Navigate up (older commands)
            if historyIndex < history.count - 1 {
                historyIndex += 1
                let index = history.count - 1 - historyIndex
                commandInput = history[index]
            }
        } else {
            // Navigate down (newer commands)
            if historyIndex > 0 {
                historyIndex -= 1
                let index = history.count - 1 - historyIndex
                commandInput = history[index]
            } else if historyIndex == 0 {
                // Return to original input
                historyIndex = -1
                commandInput = historySearchInput
            }
        }
    }
    
    @MainActor
    private func handleTabCompletion() {
        let input = commandInput.trimmingCharacters(in: .whitespaces)
        
        // Get completions if we don't have them or input changed
        if currentCompletions.isEmpty || input != lastCompletionInput {
            currentCompletions = advancedFeatures.getCompletions(for: input, in: session)
            currentCompletionIndex = 0
            lastCompletionInput = input
            
            if currentCompletions.isEmpty {
                return // No completions available
            }
        }
        
        // If we have completions, use the current one
        if !currentCompletions.isEmpty {
            let completion = currentCompletions[currentCompletionIndex]
            
            // Find the last word in the input to replace
            let components = input.components(separatedBy: .whitespaces)
            if let lastWord = components.last, !lastWord.isEmpty {
                // Replace the last word with the completion
                let prefix = components.dropLast().joined(separator: " ")
                if prefix.isEmpty {
                    commandInput = completion
                } else {
                    commandInput = "\(prefix) \(completion)"
                }
            } else {
                commandInput = completion
            }
            
            // Cycle to next completion for next Tab press
            currentCompletionIndex = (currentCompletionIndex + 1) % currentCompletions.count
        }
    }
}

// MARK: – History Sheet
private struct HistorySheetView: View {
    let commands: [String]
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("Command History").font(.headline)
                Spacer()
                Button("Close") { dismiss() }
            }
            .padding()
            Divider()
            List(commands, id: \.self) { cmd in
                HStack {
                    Text(cmd)
                    Spacer()
                    Button("Use") { onPick(cmd) }
                        .buttonStyle(.borderedProminent)
                }
                .contentShape(Rectangle())
                .onTapGesture { onPick(cmd) }
            }
        }
        .padding(.bottom, 8)
    }
}

// MARK: - Enhanced History Sheet with Search and Statistics
private struct EnhancedHistorySheetView: View {
    @ObservedObject var session: TerminalSession
    let onPick: (String) -> Void
    @Environment(\.dismiss) private var dismiss
    
    @State private var searchText: String = ""
    @State private var showStatistics: Bool = false
    
    var filteredCommands: [String] {
        let reversed = session.commandHistory.reversed()
        if searchText.isEmpty {
            return Array(reversed)
        }
        return reversed.filter { $0.localizedCaseInsensitiveContains(searchText) }
    }
    
    var commandStats: [String: Int] {
        var stats: [String: Int] = [:]
        for cmd in session.commandHistory {
            let baseCmd = cmd.components(separatedBy: " ").first ?? cmd
            stats[baseCmd, default: 0] += 1
        }
        return stats
    }
    
    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // Search bar
                HStack {
                    Image(systemName: "magnifyingglass")
                        .foregroundColor(.secondary)
                    TextField("Search history...", text: $searchText)
                    if !searchText.isEmpty {
                        Button(action: { searchText = "" }) {
                            Image(systemName: "xmark.circle.fill")
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding()
                
                Divider()
                
                if showStatistics {
                    // Statistics view
                    ScrollView {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Command Statistics")
                                .font(.headline)
                                .padding()
                            
                            ForEach(Array(commandStats.sorted(by: { $0.value > $1.value }).prefix(10)), id: \.key) { cmd, count in
                                HStack {
                                    Text(cmd)
                                        .font(.system(.body, design: .monospaced))
                                    Spacer()
                                    Text("\(count)")
                                        .foregroundColor(.secondary)
                                }
                                .padding(.horizontal)
                            }
                        }
                    }
                } else {
                    // Command list
                    if filteredCommands.isEmpty {
                        VStack {
                            Spacer()
                            Text("No commands found")
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                    } else {
                        List(filteredCommands, id: \.self) { cmd in
                            HStack {
                                Text(cmd)
                                    .font(.system(.body, design: .monospaced))
                                    .lineLimit(1)
                                Spacer()
                                Button("Use") { 
                                    onPick(cmd)
                                    dismiss()
                                }
                                .buttonStyle(.borderedProminent)
                            }
                            .contentShape(Rectangle())
                            .onTapGesture { 
                                onPick(cmd)
                                dismiss()
                            }
                        }
                        .listStyle(.plain)
                    }
                }
            }
            .navigationTitle("Command History")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
                ToolbarItem(placement: .primaryAction) {
                    Button(action: { showStatistics.toggle() }) {
                        Image(systemName: showStatistics ? "chart.bar.fill" : "chart.bar")
                    }
                }
            }
        }
        .frame(width: 600, height: 400)
    }
}

// MARK: - AppKit bridge for selectable, copy‑aware text

/// A thin `NSViewRepresentable` that wraps an `NSTextView`.
/// It displays the supplied AttributedString, allows user selection,
/// and reports the currently selected text back via a binding.
struct SelectableTextView: NSViewRepresentable {
    var attributedString: AttributedString
    @Binding var selectedText: String
    
    func makeNSView(context: Context) -> NSScrollView {
        // Create a scroll view to contain the text view
        let scrollView = NSScrollView()
        scrollView.hasVerticalScroller = true
        scrollView.hasHorizontalScroller = false
        scrollView.autohidesScrollers = true
        scrollView.borderType = .noBorder
        scrollView.drawsBackground = false
        
        // Create the text view
        let textView = NSTextView()
        textView.isEditable = false
        textView.isSelectable = true
        textView.drawsBackground = false
        textView.textContainerInset = .zero
        textView.delegate = context.coordinator
        textView.isAutomaticSpellingCorrectionEnabled = false
        
        // Configure text container for proper layout
        if let textContainer = textView.textContainer {
            textContainer.widthTracksTextView = true
            textContainer.containerSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        }
        textView.isHorizontallyResizable = false
        textView.isVerticallyResizable = true
        textView.minSize = NSSize(width: 0, height: 0)
        textView.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        textView.autoresizingMask = [.width, .height]
        
        // Set the text view as the document view
        scrollView.documentView = textView
        
        return scrollView
    }
    
    func updateNSView(_ nsView: NSScrollView, context: Context) {
        // Get the text view from the scroll view
        guard let textView = nsView.documentView as? NSTextView else { return }
        
        // Convert SwiftUI AttributedString → NSAttributedString
        let nsAttributedString = NSAttributedString(attributedString)
        guard let textStorage = textView.textStorage else { return }
        
        let currentString = textStorage.string
        let newString = nsAttributedString.string
        
        // Only update if content actually changed to avoid cycles
        if currentString != newString {
            // Update synchronously (we're already on main thread)
            // Temporarily disable delegate to prevent feedback loops
            let oldDelegate = textView.delegate
            textView.delegate = nil
            
            // Ensure the text view is properly configured
            textView.isEditable = false
            textView.isSelectable = true
            textView.drawsBackground = false
            
            // Set the attributed string
            textStorage.setAttributedString(nsAttributedString)
            
            // Ensure the text container is properly sized
            if let textContainer = textView.textContainer {
                textContainer.widthTracksTextView = true
                textContainer.containerSize = NSSize(width: nsView.contentSize.width, height: CGFloat.greatestFiniteMagnitude)
            }
            
            // Restore delegate
            textView.delegate = oldDelegate
            
            // Force multiple types of updates
            textView.needsDisplay = true
            textView.needsLayout = true
            textView.displayIfNeeded()
            
            // Scroll to bottom to show latest output
            if textStorage.length > 0 {
                let range = NSRange(location: max(0, textStorage.length - 1), length: 1)
                textView.scrollRangeToVisible(range)
                // Also scroll the scroll view
                let point = NSPoint(x: 0, y: max(0, textView.bounds.height - nsView.contentSize.height))
                nsView.contentView.scroll(to: point)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }
    
    class Coordinator: NSObject, NSTextViewDelegate {
        var parent: SelectableTextView
        
        init(parent: SelectableTextView) {
            self.parent = parent
        }
        
        // ✅ Correct delegate method name – matches NSTextViewDelegate protocol
        func textViewDidChangeSelection(_ notification: Notification) {
            guard let tv = notification.object as? NSTextView else { return }
            if let rangeValue = tv.selectedRanges.first?.rangeValue,
               let fullString = tv.string as NSString? {
                let selected = fullString.substring(with: rangeValue)
                // Dispatch the state change asynchronously to avoid modifying
                // SwiftUI state during a view update.
                DispatchQueue.main.async {
                    self.parent.selectedText = selected
                }
            } else {
                DispatchQueue.main.async {
                    self.parent.selectedText = ""
                }
            }
        }
    }
}

// MARK: - Line Count Measurer

struct LineCountMeasurer: View {
    let attributedText: AttributedString
    let width: CGFloat
    @State private var lineCount: Int = 0
    
    var body: some View {
        Color.clear
            .task {
                // Use task for async execution to avoid blocking
                updateLineCount()
            }
            .onChange(of: attributedText) {
                Task {
                    updateLineCount()
                }
            }
            .onChange(of: width) {
                Task {
                    updateLineCount()
                }
            }
            .preference(key: LineCountPreferenceKey.self, value: lineCount)
    }
    
    private func updateLineCount() {
        // Use a simpler, faster approach that won't block the UI
        let text = String(attributedText.characters)
        var workingText = text
        
        // Remove ALL trailing newlines
        while workingText.hasSuffix("\n") || workingText.hasSuffix("\r\n") || workingText.hasSuffix("\r") {
            if workingText.hasSuffix("\r\n") {
                workingText = String(workingText.dropLast(2))
            } else if workingText.hasSuffix("\n") {
                workingText = String(workingText.dropLast(1))
            } else if workingText.hasSuffix("\r") {
                workingText = String(workingText.dropLast(1))
            }
        }
        
        // If text is empty after trimming, return 0
        if workingText.isEmpty {
            DispatchQueue.main.async {
                self.lineCount = 0
            }
            return
        }
        
        // Simple newline count + 1
        let newlineCount = workingText.filter { $0 == "\n" }.count
        let count = newlineCount + 1
        
        DispatchQueue.main.async {
            self.lineCount = max(0, count)
        }
    }
}

struct LineCountPreferenceKey: PreferenceKey {
    // Use immutable default to satisfy Swift 6.2 concurrency-safety rules
    static let defaultValue: Int = 0
    static func reduce(value: inout Int, nextValue: () -> Int) {
        value = nextValue()
    }
}

// MARK: - Line Numbers View

struct LineNumbersView: View {
    let attributedText: AttributedString
    let font: Font
    
    var body: some View {
        Text(lineNumbersString())
            .font(font)
            .foregroundColor(.gray)
            .frame(maxWidth: .infinity, alignment: .trailing)
            .multilineTextAlignment(.trailing)
    }
    
    private func lineNumbersString() -> String {
        let raw = String(attributedText.characters)
        if raw.isEmpty { return "" }
        
        let normalized = raw
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        
        // Remove trailing newlines to avoid counting empty trailing lines
        var trimmed = normalized
        while trimmed.hasSuffix("\n") {
            trimmed = String(trimmed.dropLast())
        }
        
        let segments = trimmed.split(separator: "\n", omittingEmptySubsequences: false)
        
        if segments.isEmpty {
            return ""
        }
        
        return segments.enumerated()
            .map { "\($0.offset + 1)" }
            .joined(separator: "\n")
    }
}
