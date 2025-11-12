import SwiftUI
import SwiftUI
import Foundation

#if os(macOS)
import AppKit          // Needed for NSApp, NSPasteboard and NSTextView
#endif

/// Ultra‑minimal TerminalView with ZERO complexity
struct TerminalView: View {
    @ObservedObject var session: TerminalSession
    @State private var commandInput: String = ""
    @State private var passwordInput: String = ""
    @State private var showPasswordInput: Bool = false
    @State private var searchQuery: String = ""
    @State private var selectedOutput: String = ""          // tracks current selection
    @FocusState private var commandFieldIsFocused: Bool     // ← focus‑state for the TextField
    @FocusState private var passwordFieldIsFocused: Bool    // ← focus‑state for password field
    @State private var cachedAttributedOutput: AttributedString = AttributedString("")
    
    @EnvironmentObject private var lineNumbersManager: LineNumbersManager
    @EnvironmentObject private var themeManager: ThemeManager
    @EnvironmentObject private var fontManager: FontManager

    // Submit command helper (used by both onCommit and onSubmit)
    private func submitCommand() {
        let cmd = commandInput
        let trimmed = cmd.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !session.isProcessRunning else { return }
        commandInput = ""
        session.runCommand(trimmed)
        // Return focus to the field after running
        commandFieldIsFocused = true
    }

    // MARK: - View Body
    
    var body: some View {
        VStack(spacing: 0) {
            // MARK: Terminal output area
            GeometryReader { geo in
                ZStack {
                    // Background
                    themeManager.current.background
                        .frame(maxWidth: .infinity, maxHeight: .infinity)

                    // Output + line numbers
                    HStack(alignment: .top, spacing: 0) {
                        // Terminal output – using simple Text view for now
                        ScrollViewReader { proxy in
                            ScrollView(.vertical) {
                                HStack(alignment: .top, spacing: 0) {
                                    // Line numbers (if enabled) - inside ScrollView so they scroll
                                    if lineNumbersManager.showLineNumbers {
                                        LineNumbersView(text: session.output)
                                            .font(fontManager.font)
                                            .foregroundColor(.gray)
                                            .padding(.leading, 10)
                                            .padding(.trailing, 5)
                                    }
                                    
                                    // Terminal output text
                                    Text(highlightedAttributedOutput)
                                        .textSelection(.enabled)
                                        .frame(maxWidth: .infinity, alignment: .leading)
                                        .padding(.horizontal, 10)
                                        .padding(.vertical, 4)
                                        .font(fontManager.font)
                                        .foregroundColor(themeManager.current.foreground)
                                }

                                // Invisible anchor for auto‑scrolling to bottom
                                Color.clear.frame(height: 1).id("BOTTOM")
                            }
                            .scrollIndicators(.visible)
                            .onChange(of: session.output) { _, _ in
                                // Update cached attributed output when session output changes
                                updateCachedAttributedOutput()
                                // Auto‑scroll to the bottom when new output arrives
                                DispatchQueue.main.async {
                                    withAnimation(.easeOut(duration: 0.15)) {
                                        proxy.scrollTo("BOTTOM", anchor: .bottom)
                                    }
                                }
                            }
                            .onChange(of: searchQuery) { _, _ in
                                // Update cache when search query changes
                                updateCachedAttributedOutput()
                            }
                            .onChange(of: fontManager.fontName) { _, _ in
                                // Update cache when font name changes
                                updateCachedAttributedOutput()
                            }
                            .onChange(of: fontManager.fontSize) { _, _ in
                                // Update cache when font size changes
                                updateCachedAttributedOutput()
                            }
                            .onAppear {
                                // Initialize cache on appear
                                updateCachedAttributedOutput()
                                // Ensure we start at the bottom
                                DispatchQueue.main.async {
                                    proxy.scrollTo("BOTTOM", anchor: .bottom)
                                }
                            }
                        }
                        .frame(width: geo.size.width, height: geo.size.height)
                        .clipped()
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

            // MARK: Command input line
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
                                session.sendInput(password)
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

                    TextField("Enter command", text: $commandInput)
                        .focused($commandFieldIsFocused)
                        .onSubmit { 
                            // If we have an active PTY (interactive process), send input to it
                            // Otherwise, run as a new command
                            if session.hasActivePTY {
                                session.sendInput(commandInput)
                                commandInput = ""
                            } else {
                                submitCommand()
                            }
                        }
                        .submitLabel(.return)
                        .textFieldStyle(PlainTextFieldStyle())
                        .font(fontManager.font)
                        .foregroundColor(themeManager.current.foreground)
                        .autocorrectionDisabled()
                        // Don't disable if we have an active PTY (interactive process)
                        .disabled(session.isProcessRunning && !session.hasActivePTY)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 8)
                .background(themeManager.current.background)
                // Ensure clicks anywhere on the command row focus the input field
                .contentShape(Rectangle())
                .onTapGesture { commandFieldIsFocused = true }
                .onChange(of: session.isProcessRunning) { oldValue, newValue in
                    // When process finishes, clear the input and refocus the field
                    if oldValue == true && newValue == false {
                        commandInput = ""
                        commandFieldIsFocused = true
                    }
                }
            }
        }
        // Ensure the field is focused when the view appears
        .onAppear { commandFieldIsFocused = true }
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
            if let textToPaste = notification.object as? String {
                commandInput += textToPaste
                commandFieldIsFocused = true
            }
        }
    }   // ← end of var body

    // MARK: - ANSI‑parsed Output with Search Highlights
    
    @MainActor               // Guarantees main‑thread execution
    private var highlightedAttributedOutput: AttributedString {
        // Just return the cached value - updates happen in onChange
        return cachedAttributedOutput
    }
    
    // Helper to update the cached attributed output
    private func updateCachedAttributedOutput() {
        var attributed = ANSIParser.parse(session.output, baseFont: fontManager.font)
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        
        if !q.isEmpty {
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
        
        // Check if password was accepted (password prompt is gone and we see output or prompt)
        let passwordAccepted = showPasswordInput && !hasPasswordPrompt && 
                               (recentLines.contains(session.prompt) || 
                                lines.last?.contains(session.prompt) == true ||
                                (!session.isProcessRunning && recentLines.trimmingCharacters(in: .whitespacesAndNewlines).count > 0))
        
        if hasPasswordPrompt {
            // Show password input if we detect a sudo password prompt
            if !showPasswordInput {
                showPasswordInput = true
                // Force focus on password field
                DispatchQueue.main.async {
                    passwordFieldIsFocused = true
                }
            }
        } else if (!session.isProcessRunning || passwordAccepted) && showPasswordInput {
            // Hide password input if:
            // 1. Process completed, OR
            // 2. Password was accepted (prompt is gone and we see output/prompt)
            showPasswordInput = false
            passwordInput = ""
            if !session.isProcessRunning {
                commandFieldIsFocused = true
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

// MARK: - Line Numbers View

struct LineNumbersView: View {
    let text: String
    
    var body: some View {
        VStack(alignment: .trailing, spacing: 0) {
            let lines = text.components(separatedBy: .newlines)
            ForEach(Array(lines.enumerated()), id: \.offset) { index, _ in
                Text("\(index + 1)")
                    .font(.system(.body, design: .monospaced))
                    .foregroundColor(.gray)
                    .frame(height: 20, alignment: .trailing)
            }
        }
    }
}
