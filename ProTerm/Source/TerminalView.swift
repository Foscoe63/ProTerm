import Foundation
import SwiftUI

#if os(macOS)
  import AppKit  // Needed for NSApp, NSPasteboard and NSTextView
#endif

/// Ultra‑minimal TerminalView with ZERO complexity
@MainActor
struct TerminalView: View {
  @ObservedObject var session: TerminalSession
  @State private var commandInput: String = ""
  @State private var passwordInput: String = ""
  @State private var showPasswordInput: Bool = false
  @State private var showPaginationInput: Bool = false
  @State private var lastPasswordSentTime: Date? = nil
  @State private var isPasswordBeingSent: Bool = false
  @State private var outputSnapshotWhenPasswordSent: String = ""
  @State private var lastPaginationKeySentTime: Date? = nil
  @State private var lastCommandSentTime: Date? = nil
  @State private var focusRestorationTimer: Timer? = nil
  @State private var lastTypingTime: Date? = nil
  @State private var searchQuery: String = ""
  @State private var selectedOutput: String = ""  // tracks current selection
  @FocusState private var commandFieldIsFocused: Bool  // ← focus‑state for the TextField
  @FocusState private var passwordFieldIsFocused: Bool  // ← focus‑state for password field
  @State private var hasRequestedInitialFocus = false  // Track if we've set initial focus
  @State private var commandFieldIsFocusedState: Bool = false  // Sync state for modifiers
  @State private var cachedAttributedOutput: AttributedString = AttributedString("")
  @State private var hasPendingBracketedPaste = false

  @EnvironmentObject private var themeManager: ThemeManager
  @EnvironmentObject private var fontManager: FontManager
  @EnvironmentObject private var advancedFeatures: AdvancedFeatures
  @EnvironmentObject private var productivityTools: ProductivityTools
  @EnvironmentObject private var terminalManager: TerminalManager
  @EnvironmentObject private var visualSettings: TerminalVisualSettings

  private var activeProfile: AppearanceProfile { themeManager.activeProfile }
  private var mouseReportingActive: Bool {
    visualSettings.enableMouseReporting && session.hasActivePTY
  }
  private var pointerCellSize: CGSize {
    fontManager.characterCellSize
  }
  
  // Calculate text width - use full availableWidth, gap comes from outer container's horizontalPadding
  private func preferredTextWidth(availableWidth: CGFloat) -> CGFloat {
    // Use full availableWidth - the outer container's horizontalPadding provides the gap
    return max(40, availableWidth)
  }

  private var focusController: CommandInputFocusController { CommandInputFocusController.shared }

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
    let originalInput = commandInput
    let sanitizedInput = originalInput.sanitizedTerminalCommand()
    if sanitizedInput != originalInput {
      commandInput = sanitizedInput
    }
    let trimmed = sanitizedInput.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmed.isEmpty else {
      // Clear input even if empty
      commandInput = ""
      // Still restore focus even for empty commands
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        self.commandFieldIsFocused = true
        self.requestControllerFocus(reason: .manual)
        // Also broadcast a focus request to ensure AppKit first responder is set
        NotificationCenter.default.post(
          name: Notification.Name("ProTermFocusCommandInput"), object: self.session.id)
      }
      return
    }

    // Don't allow new commands if process is running (unless it has active PTY)
    // On first command, isProcessRunning should be false, so this should pass
    guard !session.isProcessRunning || session.hasActivePTY else {
      // Restore focus even if command can't run
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
        commandFieldIsFocused = true
        requestControllerFocus(reason: .manual)
        NotificationCenter.default.post(
          name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
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
    hasPendingBracketedPaste = false
    // Return focus to the field after running (with delay to ensure view has updated)
    // Use a longer delay to ensure all output updates have completed
    DispatchQueue.main.asyncAfter(deadline: .now() + 0.2) {
        commandFieldIsFocused = true
        requestControllerFocus(reason: .manual)
        NotificationCenter.default.post(
          name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
      
      // Also try again after a bit more time in case output is still updating
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
          commandFieldIsFocused = true
          requestControllerFocus(reason: .manual)
          NotificationCenter.default.post(
            name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
      }
    }
  }

  // Expand bookmark names in cd commands
  private func expandBookmarkInCommand(_ command: String) -> String {
    if command.hasPrefix("cd ") {
      let target = String(command.dropFirst(3)).trimmingCharacters(in: .whitespaces)
      // Check if target matches a bookmark name
      if let bookmark = productivityTools.bookmarks.first(where: {
        $0.name.lowercased() == target.lowercased()
      }) {
        productivityTools.useBookmark(bookmark)
        return "cd \(bookmark.path)"
      }
    }
    return command
  }

  // MARK: - View Body

  var body: some View {
    terminalOutputArea
      .onAppear(perform: handleViewAppear)
      .onDisappear(perform: handleViewDisappear)
      .modifier(SSHTimerModifier(
        session: session,
        showPasswordInput: showPasswordInput,
        showPaginationInput: showPaginationInput,
        focusRestorationTimer: $focusRestorationTimer,
        startFocusRestorationTimer: startFocusRestorationTimer
      ))
      .modifier(FocusRestorationModifier(
        session: session,
        showPasswordInput: showPasswordInput,
        showPaginationInput: showPaginationInput,
        commandFieldIsFocused: commandFieldIsFocused,
        lastTypingTime: lastTypingTime,
        requestControllerFocus: requestControllerFocus,
        commandFieldIsFocusedBinding: $commandFieldIsFocusedState
      ))
      .onChange(of: commandFieldIsFocused) { _, newValue in
        commandFieldIsFocusedState = newValue
      }
      .onChange(of: commandFieldIsFocusedState) { _, newValue in
        commandFieldIsFocused = newValue
      }
      .background(WindowAccessor())
      .modifier(OutputChangeModifier(
        session: session,
        showPaginationInput: showPaginationInput,
        showPasswordInput: $showPasswordInput,
        showPaginationInputBinding: $showPaginationInput,
        passwordInput: $passwordInput,
        commandInput: $commandInput,
        commandFieldIsFocused: $commandFieldIsFocusedState,
        lastPasswordSentTime: $lastPasswordSentTime,
        isPasswordBeingSent: $isPasswordBeingSent,
        outputSnapshotWhenPasswordSent: $outputSnapshotWhenPasswordSent,
        lastPaginationKeySentTime: $lastPaginationKeySentTime,
        checkForPasswordPrompt: checkForPasswordPrompt,
        checkForPaginationPrompt: checkForPaginationPrompt,
        updateCachedAttributedOutput: updateCachedAttributedOutput,
        handleSSHOutputChange: handleSSHOutputChange
      ))
      // Listen for search notifications from the button bar
      .onReceive(NotificationCenter.default.publisher(for: .searchInTerminal)) { notification in
        if let query = notification.object as? String {
          searchQuery = query
          updateCachedAttributedOutput()
        }
      }
      // Listen for regex mode toggle
      .onReceive(NotificationCenter.default.publisher(for: .setSearchRegexMode)) { notification in
        if let useRegexValue = notification.object as? Bool {
          useRegex = useRegexValue
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
          let replaceText = dict["replace"]
        {
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
              let text = dict["text"] as? String
            {
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
          Task { @MainActor in
            guard !self.showPasswordInput else { return }
            forceFocus(reason: .notification)
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
        EnhancedHistorySheetView(
          session: session,
          onPick: { cmd in
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
          }
        )
        .frame(width: 600, height: 400)
      }
      // Listen for terminal bell
      .onReceive(
        NotificationCenter.default.publisher(for: Notification.Name("ProTermTerminalBell"))
      ) { notification in
        if let sessionId = notification.object as? UUID, sessionId == session.id {
          handleTerminalBell()
        }
      }
  }

  // MARK: - Terminal Output Area

  private var terminalOutputArea: some View {
    GeometryReader { geo in
      let appearance = activeProfile
      let horizontalPadding = CGFloat(appearance.horizontalPadding)
      let verticalPadding = CGFloat(appearance.verticalPadding)
      let lineNumbersWidth = visualSettings.showLineNumbers ? 40.0 : 0.0
      let availableWidth = max(40, geo.size.width - horizontalPadding * 2)

      ZStack {
        HStack(alignment: .top, spacing: 0) {
          scrollContent(geo: geo, availableWidth: availableWidth)
        }
      }
      .frame(maxWidth: .infinity, maxHeight: .infinity)
      .padding(.horizontal, horizontalPadding)
      .padding(.vertical, verticalPadding)
      .background(
        terminalBackground(for: appearance)
      )
      .clipShape(RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous))
      .overlay(
        RoundedRectangle(cornerRadius: appearance.cornerRadius, style: .continuous)
          .stroke(Color.white.opacity(0.05), lineWidth: 1)
      )
      .shadow(color: Color.black.opacity(0.18), radius: 18, y: 10)
      .overlay {
        if mouseReportingActive {
          let insets = EdgeInsets(
            top: verticalPadding,
            leading: horizontalPadding + (visualSettings.showLineNumbers ? 60 : 0),
            bottom: verticalPadding,
            trailing: horizontalPadding
          )
          MouseReportingOverlay(
            isEnabled: true,
            cellSize: pointerCellSize,
            contentInsets: insets,
            sendSequence: { sequence in
              session.sendInput(sequence)
            }
          )
        }
      }
      .onTapGesture {}
      .onAppear {
        recalculateTerminalWidth(totalWidth: geo.size.width, lineNumberWidth: lineNumbersWidth)
      }
      .onChange(of: geo.size.width) { _, newWidth in
        recalculateTerminalWidth(totalWidth: newWidth, lineNumberWidth: lineNumbersWidth)
      }
      .onChange(of: visualSettings.showLineNumbers) { _, _ in
        let newLineNumbersWidth = visualSettings.showLineNumbers ? 40.0 : 0.0
        recalculateTerminalWidth(totalWidth: geo.size.width, lineNumberWidth: newLineNumbersWidth)
      }
      .onChange(of: themeManager.activeProfileID) { _, _ in
        let newLineNumbersWidth = visualSettings.showLineNumbers ? 40.0 : 0.0
        recalculateTerminalWidth(totalWidth: geo.size.width, lineNumberWidth: newLineNumbersWidth)
      }
      .onChange(of: themeManager.activeProfile.horizontalPadding) { _, _ in
        let newLineNumbersWidth = visualSettings.showLineNumbers ? 40.0 : 0.0
        recalculateTerminalWidth(totalWidth: geo.size.width, lineNumberWidth: newLineNumbersWidth)
      }
      .onChange(of: fontManager.fontSize) { _, _ in
        let newLineNumbersWidth = visualSettings.showLineNumbers ? 40.0 : 0.0
        recalculateTerminalWidth(totalWidth: geo.size.width, lineNumberWidth: newLineNumbersWidth)
      }
      .onChange(of: fontManager.fontName) { _, _ in
        let newLineNumbersWidth = visualSettings.showLineNumbers ? 40.0 : 0.0
        recalculateTerminalWidth(totalWidth: geo.size.width, lineNumberWidth: newLineNumbersWidth)
      }
    }
  }

  @ViewBuilder
  private func terminalBackground(for profile: AppearanceProfile) -> some View {
    let baseColor = themeManager.current.background.opacity(profile.backgroundOpacity)
    if let material = profile.backgroundMaterial.material {
      RoundedRectangle(cornerRadius: profile.cornerRadius, style: .continuous)
        .fill(material)
        .background(
          RoundedRectangle(cornerRadius: profile.cornerRadius, style: .continuous)
            .fill(baseColor)
        )
    } else {
      RoundedRectangle(cornerRadius: profile.cornerRadius, style: .continuous)
        .fill(baseColor)
    }
  }

  private func recalculateTerminalWidth(totalWidth: CGFloat, lineNumberWidth: CGFloat) {
    let padding = CGFloat(themeManager.activeProfile.horizontalPadding * 2)
    let width = max(40, totalWidth - lineNumberWidth - padding)
    session.characterWidth = fontManager.characterCellSize.width
    session.terminalWidth = width
  }

  // MARK: - Scroll Content

  @ViewBuilder
  private func scrollContent(geo: GeometryProxy, availableWidth: CGFloat) -> some View {
    ScrollViewReader { proxy in
      ZStack(alignment: .topTrailing) {
        scrollViewContent(geo: geo, proxy: proxy, availableWidth: availableWidth)
        processIndicatorOverlay
      }
      .onAppear {
        // Restore scroll position when view appears
        if let savedPosition = terminalManager.scrollPositions[session.id] {
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
            // Use a calculated anchor based on saved position
            // Since we can't directly set scroll offset, we'll scroll to a calculated position
            // For now, if position is near bottom (>= 0.9), scroll to bottom
            // Otherwise, try to maintain relative position
            if savedPosition >= 0.9 {
              proxy.scrollTo("BOTTOM", anchor: .bottom)
            } else {
              // Try to scroll to a position that approximates the saved ratio
              // This is a simplified approach - full implementation would require tracking line IDs
              proxy.scrollTo("BOTTOM", anchor: UnitPoint(x: 0.5, y: savedPosition))
            }
          }
        }
      }
      .onDisappear {
        // Save current scroll position (simplified - would need actual scroll offset)
        // For now, we'll save a flag that user was not at bottom
        // Full implementation would require ScrollViewReader with offset tracking
      }
    }
  }

  @ViewBuilder
  private func scrollViewContent(
    geo: GeometryProxy, proxy: ScrollViewProxy, availableWidth: CGFloat
  ) -> some View {
    ScrollView(.vertical) {
      if shouldUseVirtualScrolling {
        LazyVStack(alignment: .leading, spacing: 0) {
          virtualScrolledOutput(availableWidth: availableWidth)
          commandInputArea
          Color.clear.frame(height: 1).id("BOTTOM")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      } else {
        VStack(alignment: .leading, spacing: 0) {
          outputLineWithNumbers(availableWidth: availableWidth)
          commandInputArea
          Color.clear.frame(height: 1).id("BOTTOM")
        }
        .frame(maxWidth: .infinity, alignment: .leading)
      }
    }
    .id("TERMINAL_SCROLL_VIEW")
    .scrollIndicators(.visible)
    .onChange(of: session.output) { _, _ in
      updateCachedAttributedOutput()
      // Logic: Only auto-scroll if:
      // 1. We're showing pagination (always show new pages)
      // 2. Auto-scroll is enabled AND user is already at bottom (Standard "Follow Tail" behavior)
      // 3. User is actively typing (they want to see their input)
      let wasAtBottom = terminalManager.scrollPositions[session.id] ?? 1.0 >= 0.9
      let userIsTyping = lastTypingTime.map { Date().timeIntervalSince($0) < 1.0 } ?? false
      
      if showPaginationInput || (visualSettings.autoScroll && wasAtBottom) || userIsTyping {
        DispatchQueue.main.async {
          // Perform immediate scroll
          proxy.scrollTo("BOTTOM", anchor: .bottom)
          
          // Redundant follow-up to catch layout settling in high-volume dumps
          DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
            proxy.scrollTo("BOTTOM", anchor: .bottom)
          }
        }
        terminalManager.scrollPositions[session.id] = 1.0
      }
    }
    .onChange(of: commandFieldIsFocused) { _, isFocused in
      if isFocused {
        let wasAtBottom = terminalManager.scrollPositions[session.id] ?? 1.0 >= 0.9
        let userIsTyping = lastTypingTime.map { Date().timeIntervalSince($0) < 1.0 } ?? false
        
        // Only scroll to input if user is near bottom or actively typing.
        // This prevents yanking during SSH focus restoration if user is scrolled up.
        if wasAtBottom || userIsTyping {
          DispatchQueue.main.async {
            withAnimation(.easeOut(duration: 0.15)) {
              proxy.scrollTo("command-input", anchor: .bottom)
            }
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
      // Initialize scroll position tracking
      if terminalManager.scrollPositions[session.id] == nil {
        terminalManager.scrollPositions[session.id] = 1.0
      }
      
      // Listen for pagination key sends to update cooldown
      NotificationCenter.default.addObserver(forName: Notification.Name("ProTermPaginationKeySent"), object: nil, queue: .main) { [weak session] _ in
        guard let _ = session else { return }
        Task { @MainActor in
          self.lastPaginationKeySentTime = Date()
        }
      }
      
      DispatchQueue.main.async {
        // Always start at bottom on appear (user can scroll if needed)
        proxy.scrollTo("BOTTOM", anchor: .bottom)
        commandFieldIsFocused = true
      }
    }
    .background(ScrollPositionTracker(sessionId: session.id, terminalManager: terminalManager))
    .frame(width: availableWidth, height: geo.size.height)
    .clipped()
  }

  @ViewBuilder
  private func outputLineWithNumbers(availableWidth: CGFloat) -> some View {
    let split = calculateOutputSplit()
    let lineNumberWidth: CGFloat = visualSettings.showLineNumbers ? 40.0 : 0.0
    let textWidth = max(40, availableWidth - lineNumberWidth)
    
    HStack(alignment: .top, spacing: 0) {
      if visualSettings.showLineNumbers {
          // Use a very simple, direct approach for the gutter to ensure it matches the body
          LineNumbersView(attributedText: split.body, font: fontManager.font)
            .frame(width: 30, alignment: .trailing)
            .padding(.trailing, 10)
            .padding(.top, 4)
      }
      
      Text(split.body)
        .font(fontManager.font)
        .foregroundColor(themeManager.current.foreground)
        .textSelection(.enabled) // RESTORE HIGHLIGHT AND COPY
        .lineSpacing(0)
        .frame(width: textWidth, alignment: .leading)
        .padding(.top, 4)
    }
  }

  @ViewBuilder
  private var commandInputArea: some View {
    if showPasswordInput {
      passwordInputView
    } else if showPaginationInput {
      paginationInputView
    } else {
      regularCommandInputView
    }
  }
  
  @ViewBuilder
  private var paginationInputView: some View {
    let split = calculateOutputSplit()
    HStack(alignment: .center, spacing: 0) {
      if visualSettings.showLineNumbers {
        Text("\(calculateCommandInputLineNumber())")
          .font(fontManager.font)
          .foregroundColor(.gray)
          .frame(width: 23, alignment: .trailing)
          .padding(.trailing, 6)
          .padding(.vertical, 4)
      }
      HStack(spacing: 4) {
        // Show the terminal's prompt if it's not empty (e.g. "<--- More --->")
        if !split.prompt.characters.isEmpty {
          Text(split.prompt)
            .font(fontManager.font)
            .foregroundColor(themeManager.current.foreground)
            .padding(.trailing, 4)
        }
        
        Text("Pagination active - Press Space/Enter/Q: ")
          .font(fontManager.font)
          .foregroundColor(.blue)

        CustomTextField(
          text: $commandInput,
          placeholder: "Press Space, Enter, or Q",
          font: NSFont(name: fontManager.fontName, size: fontManager.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontManager.fontSize, weight: .regular),
          textColor: NSColor(themeManager.current.foreground),
          cursorStyle: visualSettings.cursorStyle,
          cursorBlinking: visualSettings.cursorBlinking,
          cursorColor: NSColor(themeManager.current.cursor),
          onSubmit: {
            // Send Enter directly to PTY for pagination
            if session.hasActivePTY {
              // Record when we sent the pagination key for cooldown
              lastPaginationKeySentTime = Date()
              session.sendInput("\n")
              commandInput = ""
              // Keep focus on the field for next pagination key
              DispatchQueue.main.async {
                commandFieldIsFocused = true
              }
            }
          },
          onTab: {
            return false
          },
          onUpArrow: {
            return false
          },
          onDownArrow: {
            return false
          },
          isFocused: Binding(
            get: { commandFieldIsFocused },
            set: { commandFieldIsFocused = $0 }
          ),
          sessionID: session.id,
          isPaginationActive: true,
          onPaginationKey: { key in
            // Send pagination key directly to PTY
            if session.hasActivePTY {
              // Record when we sent the pagination key for cooldown
              lastPaginationKeySentTime = Date()
              session.sendInput(key)
              commandInput = ""
              // Keep pagination UI visible and focused - CRITICAL to prevent UI from hiding
              showPaginationInput = true
              // Keep focus on the field for next pagination key
              DispatchQueue.main.async {
                self.commandFieldIsFocused = true
              }
            }
          }
        )
        .id("\(visualSettings.cursorStyle.rawValue)-\(visualSettings.cursorBlinking)-pagination")
        .disabled(false)
        .accessibilityLabel("Pagination input field")
        .accessibilityHint("Press Space for next page, Enter for next line, Q to quit")
        .frame(maxWidth: 200)
      }
      .padding(.horizontal, 10)
      .padding(.vertical, 4)
      Spacer()
    }
    .id("pagination-input")
  }

  @ViewBuilder
  private var passwordInputView: some View {
    HStack(alignment: .center, spacing: 0) {
      if visualSettings.showLineNumbers {
        Text("\(calculateCommandInputLineNumber())")
          .font(fontManager.font)
          .foregroundColor(.gray)
          .frame(width: 23, alignment: .trailing)
          .padding(.trailing, 6)
          .padding(.vertical, 4)
      }
      HStack(spacing: 4) {
        Text("Password: ")
          .font(fontManager.font)
          .foregroundColor(.yellow)

        SecureField("Enter password", text: $passwordInput)
          .focused($passwordFieldIsFocused)
          .accessibilityLabel("Password input field")
          .accessibilityHint("Enter your password for sudo commands")
          .onSubmit {
            // Prevent sending password multiple times
            guard !isPasswordBeingSent else { return }
            
            let password = passwordInput.trimmingCharacters(in: .whitespacesAndNewlines)
            passwordInput = ""
            
            guard !password.isEmpty else { return }
            
            // Set flag to prevent duplicate sends
            isPasswordBeingSent = true
            // Record when we sent the password to prevent immediate re-detection
            lastPasswordSentTime = Date()
            // Save output snapshot to detect if output changes after sending password
            outputSnapshotWhenPasswordSent = session.output
            
            
            // Send password immediately - SSH expects immediate response to password prompt
            // No delay needed - the prompt detection already ensures the prompt is ready
            session.sendInput(password + "\n")
            
            // Clear password input immediately
            DispatchQueue.main.async {
              NSApp.activate(ignoringOtherApps: true)
              passwordFieldIsFocused = true
              
              // Reset the flag after a short delay to allow for retry if needed
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                isPasswordBeingSent = false
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
      if visualSettings.showLineNumbers {
        Text("\(calculateCommandInputLineNumber())")
          .font(fontManager.font)
          .foregroundColor(.gray)
          .frame(width: 23, alignment: .trailing)
          .padding(.trailing, 6)
          .padding(.vertical, 4)
      }

      HStack(alignment: .firstTextBaseline, spacing: 0) {
        let split = calculateOutputSplit()
        let promptText = !String(split.prompt.characters).isEmpty ? split.prompt : AttributedString(session.prompt)
        
        if !String(promptText.characters).isEmpty {
            Text(promptText)
              .font(fontManager.font)
              .foregroundColor(themeManager.current.foreground)
              .padding(.trailing, 0)
              .baselineOffset(0)
        }

        CustomTextField(
          text: $commandInput,
          placeholder: "Enter command",
          font: NSFont(name: fontManager.fontName, size: fontManager.fontSize)
            ?? NSFont.monospacedSystemFont(ofSize: fontManager.fontSize, weight: .regular),
          textColor: NSColor(themeManager.current.foreground),
          cursorStyle: visualSettings.cursorStyle,
          cursorBlinking: visualSettings.cursorBlinking,
          cursorColor: NSColor(themeManager.current.cursor),
          onSubmit: {
            // If pagination is active, send Enter directly to PTY
            if showPaginationInput && session.hasActivePTY {
              // Record when we sent the pagination key for cooldown
              lastPaginationKeySentTime = Date()
              session.sendInput("\n")
              commandInput = ""
              // Keep focus on the field for next pagination key
              DispatchQueue.main.async {
                commandFieldIsFocused = true
              }
              return
            }
            
            let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
            let activePTY = session.hasActivePTY
            if activePTY {
              let payload = preparePTYInputPayload(from: commandInput)
              session.sendInput(payload + "\n")
              commandInput = ""
              hasPendingBracketedPaste = false
              // Track when command was sent for focus restoration
              lastCommandSentTime = Date()
              // For SSH/PTY commands, restore focus after a delay to ensure output has started
              // Use multiple attempts to ensure focus is restored
              for delay in [0.5, 1.0, 1.5] {
                DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
                  Task { @MainActor in
                    // Only restore focus if we're not in password or pagination mode
                    if !self.showPasswordInput && !self.showPaginationInput {
                      self.commandFieldIsFocused = true
                      self.requestControllerFocus(reason: .manual)
                      NotificationCenter.default.post(
                        name: Notification.Name("ProTermFocusCommandInput"), object: self.session.id)
                      // Ensure window is key
                      NSApp.activate(ignoringOtherApps: true)
                      if let window = NSApplication.shared.mainWindow {
                        window.makeKeyAndOrderFront(nil)
                      }
                    }
                  }
                }
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
          ),
          sessionID: session.id,
          isPaginationActive: false,  // Regular command input - pagination is handled by paginationInputView
          onPaginationKey: nil  // Not needed for regular input
        )
        .id("\(visualSettings.cursorStyle.rawValue)-\(visualSettings.cursorBlinking)")
        .disabled(false)
        .accessibilityLabel("Command input field")
        .accessibilityHint("Type commands here. Press Return to execute.")
        .padding(.horizontal, visualSettings.showCommandBoxOutline ? 4 : 0)
        .padding(.vertical, visualSettings.showCommandBoxOutline ? 2 : 0)
        .overlay(
          Group {
            if visualSettings.showCommandBoxOutline {
              RoundedRectangle(cornerRadius: visualSettings.commandBoxOutlineCornerRadius)
                .stroke(
                  visualSettings.commandBoxOutlineColor,
                  lineWidth: visualSettings.commandBoxOutlineWidth)
            }
          }
        )
        .onChange(of: commandInput) { oldValue, newValue in
          // Track when user is typing to prevent focus restoration from interfering
          if newValue != oldValue && !newValue.isEmpty {
            lastTypingTime = Date()
            // Stop focus restoration timer while user is actively typing
            focusRestorationTimer?.invalidate()
            focusRestorationTimer = nil
          }
          
          if newValue != lastCompletionInput {
            currentCompletions = []
            currentCompletionIndex = 0
          }
          if !newValue.isEmpty && historyIndex >= 0 {
            historyIndex = -1
            historySearchInput = ""
          }
          if newValue.isEmpty {
            hasPendingBracketedPaste = false
            // Restart timer when input is cleared (command was sent)
            if session.isSSHSession && session.isProcessRunning && !showPasswordInput && !showPaginationInput {
              // Restart timer after a delay to restore focus after command completes
              DispatchQueue.main.asyncAfter(deadline: .now() + 1.0) {
                if self.session.isSSHSession && self.session.isProcessRunning && !self.showPasswordInput && !self.showPaginationInput && self.commandInput.isEmpty {
                  self.startFocusRestorationTimer()
                }
              }
            }
          }
        }
      }
      .padding(.leading, visualSettings.showLineNumbers ? 0 : CGFloat(themeManager.activeProfile.horizontalPadding))
      .padding(.trailing, CGFloat(themeManager.activeProfile.horizontalPadding))
      .padding(.top, session.isSSHSession ? 0 : 4) // Reduce gap in SSH
      .padding(.bottom, 4)
      .frame(maxWidth: .infinity, alignment: .leading)
    }
    .id("command-input")
    .onAppear {
      // Use multiple attempts with increasing delays to ensure focus is set on startup
      for delay in [0.05, 0.15, 0.3, 0.5] {
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
          Task { @MainActor in
            // Use allowActivation: true to ensure focus works even on initial startup
            self.forceFocus(reason: .viewAppeared, allowActivation: true)
          }
        }
      }
    }
    .onChange(of: session.isProcessRunning) { oldValue, newValue in
      if oldValue == true && newValue == false {
        commandInput = ""
        // Restore focus after process completes - use multiple attempts to ensure it works
        for delay in [0.1, 0.3, 0.5] {
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.commandFieldIsFocused = true
            self.requestControllerFocus(reason: .manual)
            NotificationCenter.default.post(
              name: Notification.Name("ProTermFocusCommandInput"), object: self.session.id)
            // Also ensure window is key and front
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.mainWindow {
              window.makeKeyAndOrderFront(nil)
            }
          }
        }
      }
    }
    .onChange(of: session.output) { _, _ in
      if !session.isProcessRunning && commandFieldIsFocused {
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
          if !session.isProcessRunning && commandFieldIsFocused {
            Task { @MainActor in
              commandFieldIsFocused = true
              requestControllerFocus(reason: .manual)
            }
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
                      cursorColor: NSColor(themeManager.current.cursor),
                      onSubmit: {
                          // Capture the command before clearing
                          let cmd = commandInput.trimmingCharacters(in: .whitespacesAndNewlines)
  
                          // If we have an active PTY (interactive process), send input to it
                          if session.hasActivePTY {
                              let sanitizedInput = commandInput.sanitizedTerminalCommand()
                              if sanitizedInput != commandInput {
                                  commandInput = sanitizedInput
                              }
                              session.sendInput(sanitizedInput + "\n")
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
                      ),
                      sessionID: session.id
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
                                      self.focusCommandFieldInView(contentView, allowActivation: true)
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

  @ViewBuilder
  private func terminalOutputText(availableWidth: CGFloat) -> some View {
    let split = calculateOutputSplit()
    Text(split.body)
      .textSelection(.enabled)
      .frame(maxWidth: .infinity, alignment: .leading)
      .fixedSize(horizontal: false, vertical: true)  // Allow horizontal expansion, prevent vertical
      .padding(.leading, visualSettings.showLineNumbers ? 0 : 10)
      .padding(.trailing, 0)
      .padding(.top, 4)
      .padding(.bottom, 0) // No bottom padding to keep it tight with input
      .font(fontManager.font)
      .foregroundColor(themeManager.current.foreground)
      .id("output-\(session.id.uuidString)")  // Ensure output is tied to this session
      .accessibilityLabel("Terminal output")
      .accessibilityHint("Command output and terminal text. Use search to find specific content.")
  }

  // MARK: - ANSI‑parsed Output with Search Highlights

  @MainActor  // Guarantees main‑thread execution
  private var highlightedAttributedOutput: AttributedString {
    // Just return the cached value - updates happen in onChange
    return cachedAttributedOutput
  }

  // Check if we should use virtual scrolling (for large outputs)
  private var shouldUseVirtualScrolling: Bool {
    let outputLines = session.output.components(separatedBy: .newlines).count
    return outputLines > 10000
  }

  // Virtual scrolled output - splits into lines for LazyVStack
  @ViewBuilder
  private func virtualScrolledOutput(availableWidth: CGFloat) -> some View {
    let split = calculateOutputSplit()
    let lines = splitOutputIntoLines(from: split.body)
    let lineNumberWidth: CGFloat = visualSettings.showLineNumbers ? 29.0 : 0.0  // 23 + 6 padding
    let textWidth = availableWidth - lineNumberWidth
    
    ForEach(Array(lines.enumerated()), id: \.offset) { index, line in
      HStack(alignment: .firstTextBaseline, spacing: 0) {
        if visualSettings.showLineNumbers {
          Text("\(index + 1)")
            .font(fontManager.font)
            .foregroundColor(.gray)
            .frame(width: 23, alignment: .trailing)
            .padding(.trailing, 6)
            .padding(.vertical, 4)
        }
        Text(line)
          .frame(width: textWidth, alignment: .leading)
          .fixedSize(horizontal: false, vertical: true)
          .padding(.leading, visualSettings.showLineNumbers ? 0 : 10)
          .padding(.trailing, 0)
          .padding(.vertical, 4)
          .font(fontManager.font)
          .foregroundColor(themeManager.current.foreground)
      }
      .id("line-\(index)")
    }
  }

  // Split output into individual lines for virtual scrolling
  private func splitOutputIntoLines(from fullOutput: AttributedString) -> [AttributedString] {
    let string = String(fullOutput.characters)
    let lines = string.components(separatedBy: .newlines)

    // Convert back to AttributedString lines (simplified - preserves basic formatting)
    return lines.map { line in
      // Try to preserve attributes from original if possible
      // For now, create simple attributed strings
      var attributed = AttributedString(line)
      // Apply search highlighting if needed
      if !searchQuery.isEmpty {
        let q = searchQuery.trimmingCharacters(in: .whitespacesAndNewlines)
        if useRegex {
          if let range = attributed.range(of: q, options: .regularExpression) {
            attributed[range].backgroundColor = Color.yellow.opacity(0.35)
          }
        } else {
          if let range = attributed.range(of: q, options: .caseInsensitive) {
            attributed[range].backgroundColor = Color.yellow.opacity(0.35)
          }
        }
      }
      return attributed
    }
  }

  @MainActor
  private func handleViewAppear() {
    // Aggressively set initial focus with multiple attempts
    for delay in [0.05, 0.1, 0.2, 0.3, 0.5, 0.7, 1.0] {
      DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
        Task { @MainActor in
          // Set the SwiftUI focus state
          self.commandFieldIsFocused = true
          
          // Force app and window activation
          NSApp.activate(ignoringOtherApps: true)
          
          if let window = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            
            // Try to focus the command field directly
            if let contentView = window.contentView {
              self.focusCommandFieldInView(contentView, allowActivation: true)
            }
          }
          
          // Also use the focus controller
          self.requestControllerFocus(reason: .viewAppeared)
        }
      }
    }
  }
  
  @MainActor
  private func handleViewDisappear() {
    // View disappeared - any cleanup can go here
  }
  
  @MainActor
  private func requestControllerFocus(reason: CommandInputFocusController.FocusReason) {
    focusController.setActiveSession(session.id)
    focusController.requestFocus(for: session.id, reason: reason)
  }

  // Helper to forcefully set focus
  @MainActor
  private func forceFocus(
    reason: CommandInputFocusController.FocusReason = .manual, allowActivation: Bool = false
  ) {
    requestControllerFocus(reason: reason)
    let window =
      NSApplication.shared.mainWindow
      ?? NSApplication.shared.keyWindow
      ?? NSApp.windows.first

    guard let window else { return }

    if allowActivation {
      NSApp.activate(ignoringOtherApps: true)
      window.makeKeyAndOrderFront(nil)
    } else {
      guard NSApp.isActive, window.isKeyWindow else { return }
    }

    self.commandFieldIsFocused = true

    if let contentView = window.contentView {
      self.focusCommandFieldInView(contentView, allowActivation: allowActivation)
    }
  }

  // Helper to find and focus the command field directly via AppKit
  @MainActor
  private func focusCommandFieldInView(_ view: NSView, allowActivation: Bool) {
    // Find the editable NSTextField (command input)
    guard let textField = findTextField(in: view) else { return }
    // Ensure the text field is attached to a window and that window matches the container's window
    guard let tfWindow = textField.window else { return }
    guard
      let containerWindow = view.window ?? NSApplication.shared.keyWindow
        ?? NSApplication.shared.mainWindow
    else { return }
    guard tfWindow === containerWindow else {
      // Do not try to make a control in a different window the first responder
      return
    }
    tfWindow.initialFirstResponder = textField
    if allowActivation {
      NSApp.activate(ignoringOtherApps: true)
      tfWindow.makeKeyAndOrderFront(nil)
    } else {
      guard NSApp.isActive, tfWindow.isKeyWindow else { return }
    }
    // Execute AppKit calls asynchronously on main queue with high QoS
    // This helps avoid priority inversion warnings from AppKit's internal threading
    DispatchQueue.main.async(qos: .userInitiated) {
      if tfWindow.makeFirstResponder(textField) {
        // Get editor synchronously - this is safe on main thread
        if let editor = textField.currentEditor() {
          tfWindow.makeFirstResponder(editor)
        }
      }
    }
  }

  // Helper to find and focus the password field directly via AppKit
  @MainActor
  private func focusPasswordFieldInView(_ view: NSView, allowActivation: Bool = true) {
    guard let pwdField = findSecureTextField(in: view) else { return }
    guard let tfWindow = pwdField.window else { return }
    guard
      let containerWindow = view.window ?? NSApplication.shared.keyWindow
        ?? NSApplication.shared.mainWindow
    else { return }
    guard tfWindow === containerWindow else { return }
    tfWindow.initialFirstResponder = pwdField
    if allowActivation {
      NSApp.activate(ignoringOtherApps: true)
      tfWindow.makeKeyAndOrderFront(nil)
    } else {
      guard NSApp.isActive, tfWindow.isKeyWindow else { return }
    }
    // Execute AppKit calls asynchronously on main queue with high QoS
    // This helps avoid priority inversion warnings from AppKit's internal threading
    DispatchQueue.main.async(qos: .userInitiated) {
      if tfWindow.makeFirstResponder(pwdField) {
        // Get editor synchronously - this is safe on main thread
        if let editor = pwdField.currentEditor() {
          tfWindow.makeFirstResponder(editor)
        }
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

  // Handle SSH output changes - restore focus if needed
  private func handleSSHOutputChange() {
    // For SSH sessions, aggressively restore focus after output changes
    // This handles the case where commands complete but process stays running
    guard session.isSSHSession && session.isProcessRunning && !showPasswordInput && !showPaginationInput else {
      return
    }
    
    // Detect if output ends with a command prompt (indicates command completed)
    let output = session.output
    let lines = output.components(separatedBy: .newlines)
    let lastNonEmptyLine = lines.last(where: { !$0.trimmingCharacters(in: .whitespaces).isEmpty }) ?? ""
    let trimmedLine = lastNonEmptyLine.trimmingCharacters(in: .whitespaces)
    
    // Common shell prompt patterns - if we see one, command has completed
    let hasPrompt = trimmedLine.hasSuffix("> ") || 
                    trimmedLine.hasSuffix("# ") || 
                    trimmedLine.hasSuffix("$ ") ||
                    trimmedLine.hasSuffix(">") ||
                    trimmedLine.hasSuffix("#") ||
                    trimmedLine.hasSuffix("$") ||
                    trimmedLine.contains("@") && (trimmedLine.hasSuffix(">") || trimmedLine.hasSuffix("#"))
    
    // If we detect a prompt, restore focus immediately
    if hasPrompt {
      restoreSSHFocus()
    } else {
      // Use delayed attempts for other cases
      DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
        if self.session.isSSHSession && self.session.isProcessRunning && !self.showPasswordInput && !self.showPaginationInput {
          self.restoreSSHFocus()
        }
      }
    }
  }
  
  // Separate function to restore SSH focus - can be called from multiple places
  @MainActor
  private func restoreSSHFocus() {
    guard session.isSSHSession && session.isProcessRunning && !showPasswordInput && !showPaginationInput else {
      return
    }
    
    // Don't restore if user is actively typing
    if let lastTyped = lastTypingTime, Date().timeIntervalSince(lastTyped) < 1.0 {
      return
    }
    
    commandFieldIsFocused = true
    requestControllerFocus(reason: .manual)
    
    // Directly focus the text field via AppKit for more reliable focus
    // Use allowActivation: true to ensure focus is set even if window lost key status
    if let window = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow {
      // Make sure window is key
      if !window.isKeyWindow {
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
      }
      if let contentView = window.contentView {
        focusCommandFieldInView(contentView, allowActivation: true)
      }
    }
  }

  // Start focus restoration timer for SSH sessions
  // Only restores focus if it's actually lost and user is not actively typing
  private func startFocusRestorationTimer() {
    // Stop any existing timer
    focusRestorationTimer?.invalidate()
    
    // Don't start timer if user is actively typing
    if let lastTyped = lastTypingTime, Date().timeIntervalSince(lastTyped) < 2.0 {
      return
    }
    
    // Don't start timer if app is not active
    if !NSApp.isActive {
      return
    }
    
    // Capture session ID to avoid capturing the entire view
    let sessionId = session.id
    
    // Create a timer that runs every 5 seconds to restore focus ONLY if lost
    // Must run on main thread for UI updates
    focusRestorationTimer = Timer.scheduledTimer(withTimeInterval: 5.0, repeats: true) { _ in
      DispatchQueue.main.async {
        // Only restore focus if:
        // 1. App is active
        // 2. User is not actively typing
        // 3. Not in password/pagination mode
        let recentlyTyped = self.lastTypingTime != nil && Date().timeIntervalSince(self.lastTypingTime!) < 3.0
        if NSApp.isActive && 
           !recentlyTyped &&
           !self.showPasswordInput && 
           !self.showPaginationInput &&
           self.session.isSSHSession && 
           self.session.isProcessRunning {
          // Check via notification to avoid capturing view state
          NotificationCenter.default.post(
            name: Notification.Name("ProTermFocusCommandInput"), object: sessionId)
        }
      }
    }
    // Add timer to main run loop
    if let timer = focusRestorationTimer {
      RunLoop.main.add(timer, forMode: .common)
    }
  }

  private func calculateCommandInputLineNumber() -> Int {
    let raw = session.output
    if raw.isEmpty { return 1 }
    
    // The input area should show the line number of the LAST line if it's a partial line
    // Or the NEXT line if the output ends in a newline.
    let lines = raw.components(separatedBy: .newlines)
    return max(1, lines.count)
  }

  // Splits the output into a main body and a trailing partial line (the prompt)
  private func calculateOutputSplit() -> (body: AttributedString, prompt: AttributedString) {
    let full = highlightedAttributedOutput
    let raw = String(full.characters)
    
    // Find the last newline to split off the prompt/partial line
    if let lastNewlineRange = raw.range(of: "\n", options: .backwards) {
        // Map the string index to AttributedString index
        let offset = raw.distance(from: raw.startIndex, to: lastNewlineRange.upperBound)
        let splitIndex = full.characters.index(full.startIndex, offsetBy: offset)
        
        // Slicing AttributedString returns a slice; convert back to AttributedString for use
        let body = AttributedString(full[..<splitIndex])
        let prompt = AttributedString(full[splitIndex...])
        return (body, prompt)
    } else if !raw.isEmpty {
        // No newlines, the whole thing is a prompt
        return (AttributedString(""), full)
    }
    
    return (full, AttributedString(""))
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

  // MARK: - Pagination Prompt Detection

  private func checkForPaginationPrompt() {
    let normalizedOutput = String(highlightedAttributedOutput.characters)
    let normalizedLines = normalizedOutput.components(separatedBy: .newlines)
    
    // 1. Pattern detection - check this FIRST
    // Look at the very last line and a raw tail of the output
    let lastLine = normalizedLines.last?.lowercased() ?? ""
    let rawTail = normalizedOutput.suffix(60).lowercased()
    
    let paginationPatterns = [
      "---more---", "--more--", "press return", "press space", "(more)", "more--",
      "press return for more", "press space for more", "-- more --", "pagination active",
      "<--- more --->", "<- more ->", "more >", "<--- more", "more --->", "more ---"
    ]
    
    let hasPaginationPattern = paginationPatterns.contains { pattern in 
        lastLine.contains(pattern) || rawTail.contains(pattern)
    }
    
    // 2. Prompt detection - only used to DEACTIVATE pagination
    // Check if the output ends with a command prompt (#, >, $)
    // We only look at the VERY last line to avoid catching old prompts from the buffer
    let trimmedLastLine = lastLine.trimmingCharacters(in: .whitespacesAndNewlines)
    
    // Cisco/ASA prompts usually end with # or >
    // We only consider it a clear prompt if it's NOT also a pagination pattern
    let hasClearPrompt = (trimmedLastLine.hasSuffix(">") || 
                         trimmedLastLine.hasSuffix("#") || 
                         trimmedLastLine.hasSuffix("$") ||
                         trimmedLastLine.hasSuffix("> ") || 
                         trimmedLastLine.hasSuffix("# ") || 
                         trimmedLastLine.hasSuffix("$ ")) && !hasPaginationPattern
    
    // 3. Determine if we should be active
    let shouldBeActive = hasPaginationPattern && session.isProcessRunning && session.hasActivePTY
    
    if shouldBeActive {
        if !showPaginationInput {
            showPaginationInput = true
            DispatchQueue.main.async {
                commandFieldIsFocused = true
            }
        }
        return // Stay in pagination mode, don't check for prompts or cooldowns
    }

    // 4. Deactivation by clear prompt
    if hasClearPrompt {
        if showPaginationInput {
            showPaginationInput = false
            commandFieldIsFocused = true
            lastPaginationKeySentTime = nil
        }
        return
    }

    // 5. Cooldown/Auto-hide logic
    if let lastSent = lastPaginationKeySentTime {
      let timeSinceSent = Date().timeIntervalSince(lastSent)
      if timeSinceSent < 1.0 {
        // Maintain current state during short cooldown
        return
      }
    }
    
    if showPaginationInput {
      showPaginationInput = false
      commandFieldIsFocused = true
    }
  }

  // MARK: - Password Prompt Detection

  private func checkForPasswordPrompt() {
    // First, check if password was accepted (even during cooldown)
    // This allows us to hide the password input immediately when login succeeds
    if showPasswordInput {
      let output = session.output
      let lines = output.components(separatedBy: .newlines)
      let recentLines = lines.suffix(5).joined(separator: "\n")
      let recentLinesLower = recentLines.lowercased()
      let lastNonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
      let lastLine = lastNonEmptyLines.last?.lowercased() ?? ""
      
      // Check for successful login indicators (SSH) or prompt changes (enable command)
      let hasSuccessfulLogin = recentLinesLower.contains("logged in") || 
                                recentLinesLower.contains("login:")
      
      // Check for prompt changes that indicate password was accepted
      // For enable command, we might see prompt change from ">" to "#" or just a new prompt
      let hasPromptChange = (lastLine.contains("# ") && !lastLine.contains("password:")) ||
                            (lastLine.contains("> ") && !lastLine.contains("password:") && !recentLinesLower.contains("password:")) ||
                            (lastLine.contains("$ ") && !lastLine.contains("password:"))
      
      // Check if password prompt is still present
      let hasPasswordPrompt = (lastLine.hasSuffix("password:") || lastLine.hasSuffix("'s password:") || 
                               lastLine.hasSuffix("Password:") || recentLinesLower.contains("password:")) &&
                              session.isProcessRunning &&
                              !lastLine.contains("# ") && !lastLine.contains("$ ")
      
      // If we see successful login OR prompt change AND no password prompt, accept the password immediately
      if (hasSuccessfulLogin || hasPromptChange) && !hasPasswordPrompt {
        showPasswordInput = false
        passwordInput = ""
        lastPasswordSentTime = nil
        isPasswordBeingSent = false
        outputSnapshotWhenPasswordSent = ""
        // Restore focus with multiple attempts to ensure it works
        for delay in [0.1, 0.3, 0.5] {
          DispatchQueue.main.asyncAfter(deadline: .now() + delay) {
            self.commandFieldIsFocused = true
            self.requestControllerFocus(reason: .manual)
            NotificationCenter.default.post(
              name: Notification.Name("ProTermFocusCommandInput"), object: self.session.id)
            NSApp.activate(ignoringOtherApps: true)
            if let window = NSApplication.shared.mainWindow {
              window.makeKeyAndOrderFront(nil)
            }
          }
        }
        return
      }
    }
    
    // Don't re-detect password prompt immediately after sending password
    // This prevents the prompt from being detected again before SSH processes the password
    if let lastSent = lastPasswordSentTime {
      let timeSinceSent = Date().timeIntervalSince(lastSent)
      // If output hasn't changed since we sent password, extend the cooldown
      let outputChanged = session.output != outputSnapshotWhenPasswordSent
      let cooldownTime = outputChanged ? 1.0 : 3.0  // Longer cooldown if output unchanged
      
      if timeSinceSent < cooldownTime {
        // Too soon after sending password - don't re-detect
        if session.isSSHSession {
        }
        return
      }
    }
    
    // Don't detect if we're currently sending a password
    if isPasswordBeingSent {
      return
    }
    
    // Check for password prompts from both sudo and SSH
    let output = session.output
    let lines = output.components(separatedBy: .newlines)
    let recentLines = lines.suffix(5).joined(separator: "\n")
    let recentLinesLower = recentLines.lowercased()

    // Check for sudo command in recent output (case-insensitive)
    let hasSudoCommand =
      recentLinesLower.contains("sudo ") || recentLinesLower.contains(" sudo")
      || recentLinesLower.hasPrefix("sudo") || recentLinesLower.contains("\nsudo")

    // Check for SSH session (look for SSH-specific patterns)
    // More specific: look for the exact pattern "user@host's password:" or just "password:" at end of line
    // Also check for variations like "user@host's password:" or "Password:" or "password:"
    let hasSSHSession =
      session.isSSHSession
      || (recentLinesLower.contains("@") && (recentLinesLower.contains("'s password:") || recentLinesLower.contains(" password:")))
      || (recentLinesLower.contains("password:") && !hasSudoCommand && !recentLinesLower.contains("permission denied"))

    // Check if the last non-empty line ends with a password prompt
    let lastNonEmptyLines = lines.filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    let lastLine = lastNonEmptyLines.last?.lowercased() ?? ""

    // Password prompt patterns for both sudo and SSH
    // For SSH, be more specific - look for the exact prompt pattern
    let hasSudoPasswordPrompt =
      hasSudoCommand && session.isProcessRunning
      && (lastLine.hasSuffix("password:") || lastLine.contains("password for")
        || recentLinesLower.contains("\npassword:") || recentLinesLower.contains("password for "))

    // For SSH, check for the specific pattern: "user@host's password:" or just "password:" at end
    // But exclude "Permission denied" messages which come AFTER failed authentication
    // Also check if we see "Permission denied" - this means authentication failed and we should reset
    let hasPermissionDenied = recentLinesLower.contains("permission denied")
    
    // If we see permission denied, reset password state to allow retry
    if hasPermissionDenied && showPasswordInput {
      // Reset password state but keep showing input for retry
      isPasswordBeingSent = false
      lastPasswordSentTime = nil
      // Don't hide the password input - let user retry
    }
    
    // More robust SSH password prompt detection
    // Check for various formats: "user@host's password:", "Password:", "password:", etc.
    let hasSSHPasswordPrompt =
      hasSSHSession && session.isProcessRunning
      && !hasPermissionDenied
      && (
        lastLine.hasSuffix("password:") 
        || lastLine.hasSuffix("'s password:")
        || lastLine.hasSuffix(" password:")
        || (lastLine.contains("password:") && !lastLine.contains("denied") && !lastLine.contains("authentication"))
        || (recentLinesLower.contains("'s password:") && !recentLinesLower.contains("denied"))
        || (recentLinesLower.contains("@") && recentLinesLower.contains("password:") && !recentLinesLower.contains("denied"))
      )

    let hasPasswordPrompt = hasSudoPasswordPrompt || hasSSHPasswordPrompt
    
    // Debug: Log output when SSH session is active to help diagnose password prompt detection
    if session.isSSHSession && session.isProcessRunning {
      if showPasswordInput {
        // After sending password, log what we're seeing
      } else {
      }
    }


    // Check if password was accepted.
    // For SSH, look for successful login indicators:
    // - "logged in" message
    // - Shell prompt appearing (like "hostname> " or "$ " or "# ")
    // - Password prompt disappearing
    let hasSuccessfulLogin = recentLinesLower.contains("logged in") || 
                              recentLinesLower.contains("login:") ||
                              (lastLine.contains("> ") && !lastLine.contains("password:")) ||
                              (lastLine.contains("$ ") && !lastLine.contains("password:")) ||
                              (lastLine.contains("# ") && !lastLine.contains("password:"))
    
    // Consider password accepted when:
    // 1. Password prompt disappears AND we see successful login indicators, OR
    // 2. Process ends, OR
    // 3. Password prompt disappears and we see a shell prompt
    let passwordAccepted = showPasswordInput && (
      (hasSuccessfulLogin && !hasPasswordPrompt) ||
      !session.isProcessRunning ||
      (!hasPasswordPrompt && hasSuccessfulLogin)
    )

    if hasPasswordPrompt {
      // Show password input if we detect a password prompt
      // Only show if we haven't just sent a password (to avoid re-showing immediately)
      if !showPasswordInput {
        // Reset the last sent time when showing a new prompt
        lastPasswordSentTime = nil
        showPasswordInput = true
      }
      // Force focus on password field and bring window to front
      DispatchQueue.main.async {
        NSApp.activate(ignoringOtherApps: true)
        let window =
          NSApplication.shared.mainWindow
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
      lastPasswordSentTime = nil
      isPasswordBeingSent = false
      outputSnapshotWhenPasswordSent = ""
      // Restore focus to command field. Even if the process is still running
      // (after successful sudo/ssh), we want the caret visible in the command line.
      DispatchQueue.main.async {
        commandFieldIsFocused = true
        NotificationCenter.default.post(
          name: Notification.Name("ProTermFocusCommandInput"), object: session.id)
      }
    }
  }

  // Helper to perform find and replace in the terminal output
  private func performReplace(find: String, replace: String) {
    let trimmedFind = find.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedFind.isEmpty else { return }

    // Replace all occurrences in the session output (case-insensitive)
    let originalOutput = session.output
    let replacedOutput = originalOutput.replacingOccurrences(
      of: trimmedFind, with: replace, options: .caseInsensitive)

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
    if visualSettings.enableBracketedPaste {
      hasPendingBracketedPaste = true
    }
    commandFieldIsFocused = true
  }

  private func preparePTYInputPayload(from text: String) -> String {
    guard visualSettings.enableBracketedPaste, hasPendingBracketedPaste else {
      return text
    }
    return "\u{001B}[200~\(text)\u{001B}[201~"
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
        return  // No completions available
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

              ForEach(Array(commandStats.sorted(by: { $0.value > $1.value }).prefix(10)), id: \.key)
              { cmd, count in
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

  func makeNSView(context: Context) -> NSTextView {
    // Create the text view directly
    let textView = NSTextView()
    textView.isEditable = false
    textView.isSelectable = true
    textView.drawsBackground = false
    textView.textContainerInset = .zero
    textView.delegate = context.coordinator
    textView.isAutomaticSpellingCorrectionEnabled = false
    
    // Configure text container for proper layout
    // Width tracks text view, Height is infinite to allow SwiftUI to scroll it
    if let textContainer = textView.textContainer {
      textContainer.widthTracksTextView = true
      textContainer.containerSize = NSSize(
        width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
      textContainer.lineFragmentPadding = 0 // Align closely with other views
    }
    
    textView.isHorizontallyResizable = false
    textView.isVerticallyResizable = true
    textView.minSize = NSSize(width: 0, height: 0)
    textView.maxSize = NSSize(
      width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
    
    // Key to allowing SwiftUI calculation: Autoresizing mask
    textView.autoresizingMask = [.width]
    
    return textView
  }

  func updateNSView(_ nsView: NSTextView, context: Context) {
    let textView = nsView

    // Convert SwiftUI AttributedString → NSAttributedString
    let nsAttributedString = NSAttributedString(attributedString)
    guard let textStorage = textView.textStorage else { return }

    let currentString = textStorage.string
    let newString = nsAttributedString.string

    // Only update if content actually changed to avoid cycles
    if currentString != newString {
      let savedSelectedRange = textView.selectedRange
      
      // Update synchronously
      let oldDelegate = textView.delegate
      textView.delegate = nil

      textView.isEditable = false
      textView.isSelectable = true

      textStorage.beginEditing()
      textStorage.setAttributedString(nsAttributedString)
      textStorage.endEditing()

      // Restore selection if valid
      if savedSelectedRange.length > 0 {
        let maxLocation = textStorage.length
        if savedSelectedRange.location < maxLocation {
          let validLength = min(savedSelectedRange.length, maxLocation - savedSelectedRange.location)
          textView.selectedRange = NSRange(location: savedSelectedRange.location, length: validLength)
        }
      }

      // Ensure layout
      if let textContainer = textView.textContainer {
         textContainer.containerSize = NSSize(
           width: nsView.bounds.width, height: CGFloat.greatestFiniteMagnitude)
         textView.layoutManager?.ensureLayout(for: textContainer)
      }

      textView.delegate = oldDelegate
      textView.needsDisplay = true
      textView.needsLayout = true
      
      // Removed internal scrolling logic ("Yanking" fix)
      // The outer ScrollViewReader now handles "follow tail" via the "formatted" output ID or "BOTTOM" ID
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
        let fullString = tv.string as NSString?
      {
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
    while workingText.hasSuffix("\n") || workingText.hasSuffix("\r\n")
      || workingText.hasSuffix("\r")
    {
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

// MARK: - Scroll Position Tracking
// Simplified scroll position tracking - saves whether user was at bottom
// Full position restoration would require more complex ScrollView offset tracking
struct ScrollPositionTracker: View {
  let sessionId: UUID
  @ObservedObject var terminalManager: TerminalManager

  var body: some View {
    Color.clear
      .onAppear {
        // Initialize scroll position to bottom if not set
        if terminalManager.scrollPositions[sessionId] == nil {
          terminalManager.scrollPositions[sessionId] = 1.0
        }
      }
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

    // Normalize only CRLF to LF, keep CRLF as one newline
    let normalized = raw.replacingOccurrences(of: "\r\n", with: "\n")
    
    // Split into components to find total count
    let segments = normalized.components(separatedBy: "\n")
    
    // In our split view, the 'split.body' is the portion *before* the last line.
    // However, split.body could itself end in a newline.
    // If it ends in \n, components() gives an extra trailing empty string.
    let count = normalized.hasSuffix("\n") ? max(0, segments.count - 1) : segments.count
    
    if count <= 0 { return "" }
    
    return (1...count)
      .map { "\($0)" }
      .joined(separator: "\n")
  }
}
