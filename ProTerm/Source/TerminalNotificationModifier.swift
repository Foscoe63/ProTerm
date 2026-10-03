import SwiftUI
import AppKit

/// Collects the long list of `NotificationCenter` listeners attached to the terminal
/// view. Keeping them here keeps `TerminalView.body` small enough for the Swift type
/// checker, which otherwise gives up on the modifier chain (see the "unable to
/// type-check this expression in reasonable time" errors these listeners used to cause).
struct TerminalNotificationModifier: ViewModifier {
  let session: TerminalSession
  @Binding var searchQuery: String
  @Binding var useRegex: Bool
  @Binding var showPasswordInput: Bool
  @Binding var showingHistorySheet: Bool
  let updateCachedAttributedOutput: () -> Void
  let applyPaste: (String) -> Void
  let applyRedo: () -> Void
  let isActivePane: () -> Bool
  let forceFocus: (CommandInputFocusController.FocusReason) -> Void
  let showSystemInfo: () -> Void
  let presentHistoryIfNeeded: () -> Void
  let handleHistorySelection: (String) -> Void
  let handleTerminalBell: () -> Void

  func body(content: Content) -> some View {
    content
      .onReceive(NotificationCenter.default.publisher(for: .searchInTerminal)) { notification in
        guard let query = notification.object as? String else { return }
        searchQuery = query
        updateCachedAttributedOutput()
      }
      .onReceive(NotificationCenter.default.publisher(for: .setSearchRegexMode)) { notification in
        guard let enabled = notification.object as? Bool else { return }
        useRegex = enabled
        updateCachedAttributedOutput()
      }
      .onReceive(NotificationCenter.default.publisher(for: .findInTerminal)) { notification in
        guard let query = notification.object as? String else { return }
        searchQuery = query
        updateCachedAttributedOutput()
      }
      .onReceive(NotificationCenter.default.publisher(for: .replaceInTerminal)) { notification in
        // Broken into separate guards so the closure body stays cheap to type-check.
        guard let dict = notification.object as? [String: String] else { return }
        guard let findText = dict["find"] else { return }
        guard let replaceText = dict["replace"] else { return }
        performReplace(find: findText, replace: replaceText)
      }
      .onReceive(NotificationCenter.default.publisher(for: .copySelectedText)) { _ in
        // Send copy action to first responder (works with SwiftUI Text view selection)
        NSApp.sendAction(#selector(NSText.copy(_:)), to: nil, from: nil)
      }
      .onReceive(NotificationCenter.default.publisher(for: .pasteToInput)) { notification in
        // Ensure UI updates occur on the main thread
        DispatchQueue.main.async {
          guard let dict = notification.object as? [String: Any] else {
            if let textToPaste = notification.object as? String {
              applyPaste(textToPaste)
            }
            return
          }
          guard let target = dict["session"] as? TerminalSession, target === session else { return }
          guard let text = dict["text"] as? String else { return }
          applyPaste(text)
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .copyLastCommand)) { note in
        guard let target = note.object as? TerminalSession, target.id == session.id else { return }
        applyRedo()
      }
      .onReceive(NotificationCenter.default.publisher(for: .focusCommandInput)) { note in
        let targetId = note.object as? UUID
        // A broadcast (nil target) only reaches the focused pane of a split.
        if (targetId == session.id) || (targetId == nil && isActivePane()) {
          if !showPasswordInput {
            forceFocus(.notification)
          }
        }
      }
      .onReceive(NotificationCenter.default.publisher(for: .showHistory)) { note in
        guard let target = note.object as? TerminalSession else { return }
        guard target.id == session.id else { return }
        presentHistoryIfNeeded()
      }
      .onReceive(NotificationCenter.default.publisher(for: .showSystemInfo)) { note in
        guard let target = note.object as? TerminalSession else { return }
        guard target.id == session.id else { return }
        showSystemInfo()
      }
      .sheet(isPresented: $showingHistorySheet) {
        EnhancedHistorySheetView(
          session: session,
          onPick: handleHistorySelection
        )
        .frame(width: 600, height: 400)
      }
      .onReceive(NotificationCenter.default.publisher(for: .terminalBell)) { notification in
        guard let sessionId = notification.object as? UUID, sessionId == session.id else { return }
        handleTerminalBell()
      }
  }

  private func performReplace(find: String, replace: String) {
    let trimmedFind = find.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !trimmedFind.isEmpty else { return }

    let originalOutput = session.output
    let replacedOutput = originalOutput.replacingOccurrences(
      of: trimmedFind, with: replace, options: .caseInsensitive)

    if replacedOutput != originalOutput {
      session.output = replacedOutput
      searchQuery = ""
      updateCachedAttributedOutput()
    }
  }
}