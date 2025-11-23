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

        let shouldForceActivation = (reason == .startup)

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
        logFocusSnapshot("request.start", window: window, field: field, editor: window.fieldEditor(false, for: field) as? NSTextView)
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
        field.selectText(nil)
        if let editor = window.fieldEditor(true, for: field) as? NSTextView {
            if editor.string.isEmpty {
                editor.selectedRange = NSRange(location: 0, length: 0)
            } else {
                editor.selectedRange = NSRange(location: editor.string.count, length: 0)
            }
            let editorResponder = window.makeFirstResponder(editor)
            log("window.makeFirstResponder(editor) \(editorResponder ? "succeeded" : "failed")")
            logFocusSnapshot("editor.activation", window: window, field: field, editor: editor)
        } else {
            log("activateEditing editor still missing")
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


