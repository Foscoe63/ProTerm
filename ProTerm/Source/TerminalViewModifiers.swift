import SwiftUI

// MARK: - View Modifiers to break up complex view body

struct SSHTimerModifier: ViewModifier {
  let session: TerminalSession
  let showPasswordInput: Bool
  let showPaginationInput: Bool
  @Binding var focusRestorationTimer: Timer?
  let startFocusRestorationTimer: () -> Void
  
  func body(content: Content) -> some View {
    content
      .onChange(of: session.isSSHSession) { _, isSSH in
        if isSSH && session.isProcessRunning && !showPasswordInput && !showPaginationInput {
          startFocusRestorationTimer()
        } else {
          focusRestorationTimer?.invalidate()
          focusRestorationTimer = nil
        }
      }
      .onChange(of: session.isProcessRunning) { _, isRunning in
        if session.isSSHSession && isRunning && !showPasswordInput && !showPaginationInput {
          startFocusRestorationTimer()
        } else {
          focusRestorationTimer?.invalidate()
          focusRestorationTimer = nil
        }
      }
      .onChange(of: showPasswordInput) { _, _ in
        focusRestorationTimer?.invalidate()
        focusRestorationTimer = nil
      }
      .onChange(of: showPaginationInput) { _, _ in
        focusRestorationTimer?.invalidate()
        focusRestorationTimer = nil
      }
  }
}

struct FocusRestorationModifier: ViewModifier {
  let session: TerminalSession
  let showPasswordInput: Bool
  let showPaginationInput: Bool
  let commandFieldIsFocused: Bool
  let lastTypingTime: Date?
  let requestControllerFocus: (CommandInputFocusController.FocusReason) -> Void
  @Binding var commandFieldIsFocusedBinding: Bool
  
  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .focusCommandInput)) { notification in
        if let notifiedSessionId = notification.object as? UUID, notifiedSessionId == session.id {
          let recentlyTyped = lastTypingTime != nil && Date().timeIntervalSince(lastTypingTime!) < 2.0
          
          if !showPasswordInput && 
             !showPaginationInput && 
             session.isSSHSession && 
             session.isProcessRunning &&
             !commandFieldIsFocused &&
             !recentlyTyped {
            commandFieldIsFocusedBinding = true
            requestControllerFocus(.manual)
          }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: NSWindow.didBecomeKeyNotification)) { notification in
        if let window = notification.object as? NSWindow,
          let myWindow = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow,
          window === myWindow {
          // Window became key - focus will be handled by other mechanisms
        }
      }
  }
}

struct OutputChangeModifier: ViewModifier {
  let session: TerminalSession
  let showPaginationInput: Bool
  @Binding var showPasswordInput: Bool
  @Binding var showPaginationInputBinding: Bool
  @Binding var passwordInput: String
  @Binding var commandInput: String
  @Binding var commandFieldIsFocused: Bool
  @Binding var lastPasswordSentTime: Date?
  @Binding var isPasswordBeingSent: Bool
  @Binding var outputSnapshotWhenPasswordSent: String
  @Binding var lastPaginationKeySentTime: Date?
  let checkForPasswordPrompt: () -> Void
  let checkForPaginationPrompt: () -> Void
  let updateCachedAttributedOutput: () -> Void
  let handleSSHOutputChange: () -> Void
  
  func body(content: Content) -> some View {
    content
      .onChange(of: session.output) { _, _ in
        checkForPasswordPrompt()
        checkForPaginationPrompt()
        
        // ALWAYS update the cached output, regardless of pagination state
        // This ensures new content is displayed immediately during pagination
        updateCachedAttributedOutput()
        
        handleSSHOutputChange()
      }
      .onChange(of: session.isProcessRunning) { _, isRunning in
        if !isRunning && showPasswordInput {
          showPasswordInput = false
          passwordInput = ""
          lastPasswordSentTime = nil
          isPasswordBeingSent = false
          outputSnapshotWhenPasswordSent = ""
          commandFieldIsFocused = true
        }
        if !isRunning && showPaginationInput {
          showPaginationInputBinding = false
          lastPaginationKeySentTime = nil
          commandInput = ""
          commandFieldIsFocused = true
        }
      }
  }
}
