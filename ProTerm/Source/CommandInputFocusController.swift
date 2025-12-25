import AppKit
import os.log

@MainActor
final class CommandInputFocusController {
    static let shared = CommandInputFocusController()
    private let logger = Logger(subsystem: "com.proterm.app", category: "Focus")

    enum FocusReason: String {
        case startup
        case viewAppeared
        case notification
        case windowBecameKey
        case fieldRegistered
        case manual
    }

    private struct FieldEntry {
        weak var field: CustomNSTextField?
        let identifier: ObjectIdentifier
    }

    private var fieldTable: [UUID: FieldEntry] = [:]
    private var activeSessionID: UUID?
    private let verificationDelays: [UInt64] = [
        50_000_000,    // 0.05s
        200_000_000,   // 0.20s
        500_000_000,   // 0.50s
        1_000_000_000  // 1.00s
    ]

    func register(field: CustomNSTextField, sessionID: UUID) {
        fieldTable[sessionID] = FieldEntry(field: field, identifier: ObjectIdentifier(field))
        log("register session=\(sessionID.uuidString) window=\(field.window != nil)")
        if let window = field.window {
            window.initialFirstResponder = field
            let editor = window.fieldEditor(false, for: field) as? NSTextView
            logFocusSnapshot("register", window: window, field: field, editor: editor)
        }
        if activeSessionID == sessionID {
            requestFocus(for: sessionID, reason: .fieldRegistered)
        }
    }

    func unregister(field: CustomNSTextField) {
        guard let sessionID = field.sessionID else {
            log("unregister field missing session id")
            return
        }
        unregister(sessionID: sessionID, identifier: ObjectIdentifier(field))
    }

    func unregister(sessionID: UUID, identifier: ObjectIdentifier? = nil) {
        guard let entry = fieldTable[sessionID] else {
            log("unregister session missing entry session=\(sessionID.uuidString)")
            return
        }
        if let identifier, entry.identifier != identifier {
            log("unregister identifier mismatch for session=\(sessionID.uuidString)")
            return
        }
        fieldTable.removeValue(forKey: sessionID)
        log("unregister success session=\(sessionID.uuidString)")
    }

    func setActiveSession(_ id: UUID?) {
        guard activeSessionID != id else { return }
        let old = activeSessionID?.uuidString ?? "nil"
        let new = id?.uuidString ?? "nil"
        activeSessionID = id
        log("active session changed \(old) → \(new)")
    }

    func clearActiveSession(_ id: UUID? = nil) {
        guard let current = activeSessionID else { return }
        if let id, id != current {
            log("clearActiveSession ignored (active=\(current.uuidString) requested=\(id.uuidString))")
            return
        }
        log("active session cleared \(current.uuidString)")
        activeSessionID = nil
    }

    func requestFocus(for sessionID: UUID? = nil, reason: FocusReason = .manual) {
        let targetID = sessionID ?? activeSessionID
        guard let targetID else {
            log("requestFocus no active session reason=\(reason.rawValue)")
            return
        }
        guard let entry = fieldTable[targetID], let field = entry.field else {
            fieldTable.removeValue(forKey: targetID)
            log("requestFocus field missing for session=\(targetID.uuidString)")
            return
        }
        guard let window = field.window else {
            log("requestFocus field has no window session=\(targetID.uuidString)")
            return
        }

        // Force activation for startup and viewAppeared to ensure initial focus works
        let shouldForceActivation = (reason == .startup || reason == .viewAppeared)

        if !NSApp.isActive && !shouldForceActivation {
            log("requestFocus skipped (inactive app) session=\(targetID.uuidString) reason=\(reason.rawValue)")
            return
        }

        if shouldForceActivation {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        } else if !window.isKeyWindow {
            log("requestFocus skipped (window not key) session=\(targetID.uuidString) reason=\(reason.rawValue)")
            return
        }

        log("requestFocus start session=\(targetID.uuidString) reason=\(reason.rawValue)")
        let existingEditor = window.fieldEditor(false, for: field) as? NSTextView
        logFocusSnapshot("request.start", window: window, field: field, editor: existingEditor)
        
        // Check if editor is already the first responder - if so, just ensure cursor is visible
        if let editor = existingEditor, window.firstResponder === editor {
            log("editor already first responder, ensuring cursor visibility")
            editor.updateInsertionPointStateAndRestartTimer(true)
            editor.needsDisplay = true
            // Also set cursor visible on CustomFieldEditor
            if let customEditor = editor as? CustomFieldEditor {
                customEditor.cursorVisible = true
                customEditor.needsDisplay = true
            }
            log("requestFocus completed session=\(targetID.uuidString)")
            return
        }
        
        let fieldResponder = window.makeFirstResponder(field)
        log("window.makeFirstResponder(field) \(fieldResponder ? "succeeded" : "failed")")
        if fieldResponder {
            activateEditing(for: field, in: window)
            scheduleVerification(for: targetID, window: window, field: field, attempt: 0)
        } else {
            log("requestFocus editor step skipped because field responder failed")
        }

        field.autoFocusOnAttach = true
        field.forceBecomeFirstResponder(allowActivation: shouldForceActivation)
        log("requestFocus completed session=\(targetID.uuidString)")
    }

    private func activateEditing(for field: CustomNSTextField, in window: NSWindow) {
        // Check if editor is already active
        if let existingEditor = field.currentEditor() as? NSTextView,
           window.firstResponder === existingEditor {
            // Editor is already active - just ensure cursor visibility
            log("activateEditing: editor already active, ensuring cursor")
            existingEditor.updateInsertionPointStateAndRestartTimer(true)
            existingEditor.setNeedsDisplay(existingEditor.bounds)
            if let customEditor = existingEditor as? CustomFieldEditor {
                customEditor.cursorVisible = true
                customEditor.setNeedsDisplay(customEditor.bounds)
            }
            return
        }
        
        // First, ensure the custom cell is set up
        if !(field.cell is CustomTextFieldCell) {
            let customCell = CustomTextFieldCell(textCell: field.stringValue)
            customCell.cursorStyle = field.cursorStyle
            customCell.cursorBlinking = field.cursorBlinking
            field.cell = customCell
            log("activateEditing: installed CustomTextFieldCell")
        }
        
        // Use selectText(nil) to start editing
        field.selectText(nil)
        log("activateEditing: called selectText(nil)")
        
        // Check if editing started, if not try cell's select method
        if field.currentEditor() == nil {
            if let customCell = field.cell as? CustomTextFieldCell,
               let editor = customCell.fieldEditor(for: field) {
                // Manually start editing using the cell
                customCell.select(withFrame: field.bounds,
                                  in: field,
                                  editor: editor,
                                  delegate: field,
                                  start: 0,
                                  length: 0)
                log("activateEditing: used cell.select() fallback")
            }
        }
        
        // After selectText, the editor should be available - set up cursor
        DispatchQueue.main.async { [weak self, weak field] in
            guard let self = self, let field = field, let window = field.window else { return }
            if let editor = field.currentEditor() as? NSTextView {
                editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                editor.updateInsertionPointStateAndRestartTimer(true)
                editor.setNeedsDisplay(editor.bounds)
                if let customEditor = editor as? CustomFieldEditor {
                    customEditor.cursorVisible = true
                    customEditor.setNeedsDisplay(customEditor.bounds)
                }
                self.log("activateEditing: cursor setup complete")
            } else {
                self.log("activateEditing: no editor after selectText, retrying")
                self.setupEditorCursor(for: field, in: window, attempt: 1)
            }
        }
    }
    
    private func setupEditorCursor(for field: CustomNSTextField, in window: NSWindow, attempt: Int) {
        // Only use currentEditor - this is the ACTIVE editor that's properly attached
        if let editor = field.currentEditor() as? NSTextView {
            if editor.string.isEmpty {
                editor.selectedRange = NSRange(location: 0, length: 0)
            } else {
                editor.selectedRange = NSRange(location: editor.string.count, length: 0)
            }
            // Force cursor display
            editor.updateInsertionPointStateAndRestartTimer(true)
            editor.setNeedsDisplay(editor.bounds)
            // Also set cursorVisible on CustomFieldEditor
            if let customEditor = editor as? CustomFieldEditor {
                customEditor.cursorVisible = true
                customEditor.setNeedsDisplay(customEditor.bounds)
            }
            log("setupEditorCursor succeeded on attempt \(attempt)")
            logFocusSnapshot("editor.activation", window: window, field: field, editor: editor)
        } else if attempt < 5 {
            // Editor not ready - try selectText and retry
            log("setupEditorCursor attempt \(attempt) failed, retrying with selectText")
            field.selectText(nil)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.1 * Double(attempt)) { [weak self, weak field] in
                guard let self = self, let field = field, let window = field.window else { return }
                self.setupEditorCursor(for: field, in: window, attempt: attempt + 1)
            }
        } else {
            log("setupEditorCursor failed after \(attempt) attempts")
        }
    }

    private func scheduleVerification(for sessionID: UUID, window: NSWindow, field: CustomNSTextField, attempt: Int) {
        guard attempt < verificationDelays.count else { return }
        let delay = verificationDelays[attempt]
        Task { @MainActor [weak self, weak field] in
            try? await Task.sleep(nanoseconds: delay)
            guard
                let self,
                let currentField = field,
                let entry = self.fieldTable[sessionID],
                entry.field === currentField,
                currentField.window === window
            else { return }

            let editor = window.fieldEditor(false, for: currentField) as? NSTextView
            let firstResponder = window.firstResponder
            let stillFocused = firstResponder === currentField || (editor != nil && firstResponder === editor)

            if stillFocused {
                self.log("focus verification \(attempt) confirmed session=\(sessionID.uuidString)")
                self.logFocusSnapshot("verification.confirmed", window: window, field: currentField, editor: editor)
                return
            }
            guard window.isKeyWindow else {
                self.log("focus verification \(attempt) skipped (window not key) session=\(sessionID.uuidString)")
                return
            }

            self.log("focus verification \(attempt) lost session=\(sessionID.uuidString) responder=\(String(describing: firstResponder))")
            self.activateEditing(for: currentField, in: window)
            self.scheduleVerification(for: sessionID, window: window, field: currentField, attempt: attempt + 1)
        }
    }

    private func logFocusSnapshot(_ label: String, window: NSWindow, field: CustomNSTextField?, editor: NSTextView?) {
        let responderDescription: String
        if let responder = window.firstResponder {
            responderDescription = "\(type(of: responder))"
        } else {
            responderDescription = "nil"
        }
        let fieldAttached = field?.window != nil
        let editorAttached = editor != nil
        log("[snapshot:\(label)] appActive=\(NSApp.isActive) key=\(window.isKeyWindow) firstResponder=\(responderDescription) fieldAttached=\(fieldAttached) editorAttached=\(editorAttached)")
    }

    private func log(_ message: String) {
        logger.log("[ProTermFocus] \(message, privacy: .public)")
    }
}


