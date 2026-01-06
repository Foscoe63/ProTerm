import SwiftUI
import AppKit
import ObjectiveC

// C function signatures used with method IMPs (file-scoped for Swift 6.2 compatibility)
typealias NSViewDrawFunc = @convention(c) (AnyObject, Selector, NSRect) -> Void

nonisolated(unsafe) private var cursorStyleKey: UInt8 = 0
nonisolated(unsafe) private var cursorBlinkingKey: UInt8 = 1
nonisolated(unsafe) private var cursorColorKey: UInt8 = 2

// Custom window that provides a custom field editor
class CustomFieldEditorWindow: NSWindow {
    private var customFieldEditor: CustomFieldEditor?
    
    override func fieldEditor(_ createFlag: Bool, for object: Any?) -> NSTextView? {
        // If we're editing a CustomNSTextField, return our custom editor
        if let textField = object as? CustomNSTextField {
            if customFieldEditor == nil {
                customFieldEditor = CustomFieldEditor()
                customFieldEditor?.cursorStyle = textField.cursorStyle
                customFieldEditor?.cursorBlinking = textField.cursorBlinking
            } else {
                // Update existing editor
                customFieldEditor?.cursorStyle = textField.cursorStyle
                customFieldEditor?.cursorBlinking = textField.cursorBlinking
            }
            return customFieldEditor
        }
        // For other controls, use default field editor
        return super.fieldEditor(createFlag, for: object) as? NSTextView
    }
}

@MainActor
final class CustomFieldEditorPool {
    static let shared = CustomFieldEditorPool()
    
    private let editorTable = NSMapTable<NSWindow, CustomFieldEditor>(
        keyOptions: .weakMemory,
        valueOptions: .strongMemory
    )
    
    func editor(for field: CustomNSTextField) -> CustomFieldEditor {
        guard let window = field.window else {
            let editor = CustomFieldEditor()
            editor.apply(from: field)
            return editor
        }
        
        if let existing = editorTable.object(forKey: window) {
            existing.apply(from: field)
            return existing
        }
        
        let editor = CustomFieldEditor()
        editorTable.setObject(editor, forKey: window)
        editor.apply(from: field)
        return editor
    }
}

/// A custom text field that supports different cursor styles
struct CustomTextField: NSViewRepresentable {
    @Binding var text: String
    var placeholder: String
    var font: NSFont
    var textColor: NSColor
    var cursorStyle: TerminalVisualSettings.CursorStyle
    var cursorBlinking: Bool
    var cursorColor: NSColor
    var onSubmit: () -> Void
    var onTab: (() -> Bool)?
    var onUpArrow: (() -> Bool)?
    var onDownArrow: (() -> Bool)?
    var isFocused: Binding<Bool>
    var sessionID: UUID
    var isPaginationActive: Bool = false
    var onPaginationKey: ((String) -> Void)? = nil
    
    func makeNSView(context: Context) -> NSTextField {
        // Initialize swizzling for cursor styles (only once)
        NSTextView.swizzleDrawInsertionPoint()
        
        let textField = CustomNSTextField()
        textField.sessionID = sessionID
        textField.delegate = context.coordinator
        textField.placeholderString = placeholder
        textField.stringValue = text  // Set initial text value
        textField.font = font
        textField.textColor = textColor
        textField.backgroundColor = .clear
        textField.isBordered = false
        textField.focusRingType = .none
        textField.isBezeled = false
        textField.isEditable = true
        textField.isEnabled = true
        textField.isSelectable = true
        // Set accessibility properties
        textField.setAccessibilityLabel(placeholder.isEmpty ? "Command input" : placeholder)
        textField.setAccessibilityRole(.textField)
        // Remove any cell padding/insets and disable focus ring
        if let cell = textField.cell as? NSTextFieldCell {
            cell.lineBreakMode = .byCharWrapping
            cell.focusRingType = .none
        }
        // CRITICAL: Set up the custom cell SYNCHRONOUSLY before any focus attempts
        // This ensures the custom field editor is available immediately
        let customCell = CustomTextFieldCell(textCell: textField.stringValue)
        customCell.cursorStyle = cursorStyle
        customCell.cursorBlinking = cursorBlinking
        textField.cell = customCell
        
        textField.cursorStyle = cursorStyle
        textField.cursorBlinking = cursorBlinking
        textField.cursorColor = cursorColor
        textField.cursorColor = cursorColor
        textField.onSubmit = onSubmit
        textField.onTab = onTab
        textField.onUpArrow = onUpArrow
        textField.onDownArrow = onDownArrow
        textField.isPaginationActive = isPaginationActive
        textField.onPaginationKey = onPaginationKey
        // Initialize coordinator's last known value
        context.coordinator.lastUserInputValue = text
        
        // Set up focus observation
        NotificationCenter.default.addObserver(
            forName: NSControl.textDidBeginEditingNotification,
            object: textField,
            queue: .main
        ) { _ in
            isFocused.wrappedValue = true
        }
        
        NotificationCenter.default.addObserver(
            forName: NSControl.textDidEndEditingNotification,
            object: textField,
            queue: .main
        ) { _ in
            isFocused.wrappedValue = false
        }
        
        // Set autoFocusOnAttach for command input fields
        // This ensures focus is set when the text field is first added to the window
        // All CustomTextFields with sessionID are command input fields
        textField.autoFocusOnAttach = true
        textField.requestAutoFocus()
        
        return textField
    }
    
    func updateNSView(_ nsView: NSTextField, context: Context) {
        // Ensure text field is editable and enabled
        nsView.isEditable = true
        nsView.isEnabled = true
        nsView.isSelectable = true
        
        // Always disable focus ring to prevent default AppKit outline
        nsView.focusRingType = .none
        nsView.isBordered = false
        nsView.isBezeled = false
        
        // Update text if different
        // Check if there's an active field editor
        if let editor = nsView.currentEditor() as? NSTextView, nsView.window?.firstResponder === editor {
            // User is currently editing - DO NOT update the editor's text during editing
            // This prevents feedback loops when pasting or typing
            // EXCEPTION: If the binding is empty and coordinator is also empty, we just cleared it - force clear
            let editorText = editor.string
            let coordinatorValue = context.coordinator.lastUserInputValue
            
            // Special case: if binding is empty, we just cleared - force clear the editor
            // This handles the case where we clear the text after submitting
            if text.isEmpty && !editorText.isEmpty {
                editor.string = ""
                nsView.stringValue = ""
                context.coordinator.lastUserInputValue = ""
                editor.needsDisplay = true
                // Force the text field to update
                nsView.needsDisplay = true
            }
            // Special case: if binding changed and coordinator matches binding, this is a programmatic update
            // (e.g., from history selection or last command button)
            // This handles cases where we're setting a new command programmatically
            else if text != editorText && text == coordinatorValue {
                // This is a programmatic update from outside (e.g., history selection, last command)
                // Update carefully without triggering more notifications
                editor.string = text
                nsView.stringValue = text
                context.coordinator.lastUserInputValue = text
                editor.needsDisplay = true
                nsView.needsDisplay = true
            }
            // Special case: if binding changed but coordinator doesn't match, and binding doesn't match editor,
            // this is likely a programmatic update (e.g., setting command from history)
            // Update the editor to match the binding
            else if text != editorText && text != coordinatorValue && coordinatorValue == editorText {
                // Binding changed programmatically - update editor and coordinator
                editor.string = text
                nsView.stringValue = text
                context.coordinator.lastUserInputValue = text
                editor.needsDisplay = true
                nsView.needsDisplay = true
            }
            // Otherwise, trust the editor's current text and update coordinator to match
            else if editorText != coordinatorValue {
                context.coordinator.lastUserInputValue = editorText
            }
        } else {
            // Not editing - safe to update from binding
            if nsView.stringValue != text {
                nsView.stringValue = text
                context.coordinator.lastUserInputValue = text
            }
        }
        
        nsView.font = font
        nsView.textColor = textColor
        
        // Ensure cell also has focus ring disabled
        if let cell = nsView.cell as? NSTextFieldCell {
            cell.focusRingType = .none
        }
        
        if let customField = nsView as? CustomNSTextField {
            // ALWAYS update cursor style and blinking (even if same value)
            // This ensures changes from preferences take effect immediately
            let styleChanged = customField.cursorStyle != cursorStyle
            let blinkingChanged = customField.cursorBlinking != cursorBlinking
            
            customField.cursorStyle = cursorStyle
            customField.cursorBlinking = cursorBlinking
            customField.cursorColor = cursorColor
            customField.onSubmit = onSubmit
            customField.onTab = onTab
            customField.onUpArrow = onUpArrow
            customField.onDownArrow = onDownArrow
            customField.isPaginationActive = isPaginationActive
            customField.onPaginationKey = onPaginationKey
            
            // Force cursor redraw and update associated objects immediately
            // Especially important when preferences change
            if styleChanged || blinkingChanged {
                DispatchQueue.main.async {
                    // Update current editor
                    if let editor = nsView.currentEditor() as? NSTextView {
                        // Force TextKit 1 by accessing layoutManager
                        let _ = editor.layoutManager
                        objc_setAssociatedObject(editor, &cursorStyleKey, cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        objc_setAssociatedObject(editor, &cursorBlinkingKey, cursorBlinking, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        objc_setAssociatedObject(editor, &cursorColorKey, cursorColor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        editor.insertionPointColor = cursorColor
                        // Force cursor to redraw by invalidating and restarting
                        editor.updateInsertionPointStateAndRestartTimer(true)
                        editor.needsDisplay = true
                        // Force immediate redraw of the entire view
                        editor.display()
                    }
                    // Also update window's field editor
                    if let window = nsView.window,
                       let editor = window.fieldEditor(false, for: nsView) as? NSTextView {
                        // Force TextKit 1 by accessing layoutManager
                        let _ = editor.layoutManager
                        objc_setAssociatedObject(editor, &cursorStyleKey, cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        objc_setAssociatedObject(editor, &cursorBlinkingKey, cursorBlinking, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        objc_setAssociatedObject(editor, &cursorColorKey, cursorColor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        editor.insertionPointColor = cursorColor
                        editor.updateInsertionPointStateAndRestartTimer(true)
                        editor.needsDisplay = true
                        // Force immediate redraw
                        editor.display()
                    }
                    // Force the text field itself to update
                    // updateCursorStyle() is called automatically via the cursorStyle didSet observer
                    customField.needsDisplay = true
                    customField.display()
                }
            } else {
                // Even if style didn't change, ensure associated objects are set
                // This is important for when the field editor is reused
                DispatchQueue.main.async {
                    if let window = nsView.window,
                       let editor = window.fieldEditor(false, for: nsView) as? NSTextView {
                        objc_setAssociatedObject(editor, &cursorStyleKey, cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        objc_setAssociatedObject(editor, &cursorBlinkingKey, cursorBlinking, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        objc_setAssociatedObject(editor, &cursorColorKey, cursorColor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                        editor.insertionPointColor = cursorColor
                    }
                }
            }
        }
        
        // Handle focus - set focus when requested immediately
        if isFocused.wrappedValue, let customField = nsView as? CustomNSTextField {
            let editor = nsView.currentEditor()
            let isEditorFirstResponder = nsView.window?.firstResponder === editor
            if !isEditorFirstResponder {
                customField.autoFocusOnAttach = true
                customField.requestAutoFocus()
                
                // Also try to force focus immediately if window exists and is key
                if let window = nsView.window, window.isKeyWindow {
                    customField.forceBecomeFirstResponder(allowActivation: true)
                }
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator(self)
    }
    
    class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: CustomTextField
        var lastUserInputValue: String = ""
        
        init(_ parent: CustomTextField) {
            self.parent = parent
        }
        
        func control(_ control: NSControl, textView: NSTextView, doCommandBy commandSelector: Selector) -> Bool {
            if commandSelector == #selector(NSResponder.insertNewline(_:)) {
                // Ensure binding is up to date before submitting
                if let textField = control as? NSTextField {
                    let currentValue = textField.stringValue
                    lastUserInputValue = currentValue
                    parent.text = currentValue
                }
                // Call onSubmit - this is already on main thread from delegate
                parent.onSubmit()
                
                // End editing first to ensure updateNSView doesn't think we're still editing
                if let textField = control as? NSTextField, let window = textField.window {
                    // End editing by making the window the first responder (temporarily)
                    window.makeFirstResponder(nil)
                }
                
                // Clear the text field immediately and forcefully
                if let textField = control as? NSTextField {
                    // Clear the text field directly
                    textField.stringValue = ""
                    // Clear the editor if it exists (this is the active editing view)
                    if let editor = textField.currentEditor() as? NSTextView {
                        editor.string = ""
                        // Force the editor to update its display
                        editor.needsDisplay = true
                    }
                    // Update the coordinator's last known value
                    lastUserInputValue = ""
                }
                // Update the parent binding to empty immediately
                parent.text = ""
                
                // Restore focus after a delay to ensure the command has been processed
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) {
                    // Ensure the text field is still cleared (in case updateNSView tried to restore it)
                    if let textField = control as? NSTextField {
                        if textField.stringValue != "" {
                            textField.stringValue = ""
                        }
                        if let editor = textField.currentEditor() as? NSTextView, editor.string != "" {
                            editor.string = ""
                            editor.needsDisplay = true
                        }
                    }
                    // Ensure the parent's focus binding is set
                    self.parent.isFocused.wrappedValue = true
                    // Also try to force focus on the text field directly
                    if let textField = control as? CustomNSTextField {
                        textField.forceBecomeFirstResponder()
                    } else if let textField = control as? NSTextField {
                        textField.window?.makeFirstResponder(textField)
                    }
                }
                return true
            }
            // Handle arrow keys and tab
            if commandSelector == #selector(NSResponder.moveUp(_:)) {
                return parent.onUpArrow?() ?? false
            } else if commandSelector == #selector(NSResponder.moveDown(_:)) {
                return parent.onDownArrow?() ?? false
            } else if commandSelector == #selector(NSResponder.insertTab(_:)) {
                return parent.onTab?() ?? false
            }
            return false
        }
        
        func controlTextDidChange(_ obj: Notification) {
            if let textField = obj.object as? NSTextField {
                let newValue = textField.stringValue
                lastUserInputValue = newValue
                // Update the binding - this is called from the delegate on main thread
                parent.text = newValue
            }
        }
    }
}

// Store cursor style in a way that the field editor can access it
@MainActor
private var cursorStyleStorage: [NSTextField: TerminalVisualSettings.CursorStyle] = [:]
@MainActor
private var cursorBlinkingStorage: [NSTextField: Bool] = [:]

/// Custom NSTextField that supports different cursor styles
class CustomNSTextField: NSTextField {
    var sessionID: UUID? {
        didSet {
            let previousID = oldValue
            let identifier = ObjectIdentifier(self)
            Task { @MainActor [weak self] in
                if let previousID {
                    CommandInputFocusController.shared.unregister(sessionID: previousID, identifier: identifier)
                }
                self?.registerIfPossible()
            }
        }
    }
    
    override func mouseDown(with event: NSEvent) {
        // Ensure we become first responder when clicked
        if let window = self.window {
            window.makeFirstResponder(self)
        }
        super.mouseDown(with: event)
    }
    
    override func keyDown(with event: NSEvent) {
        // If pagination is active, intercept Space, Enter, and Q keys
        if isPaginationActive, let onPaginationKey = onPaginationKey {
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers ?? ""
            
            // Debug logging to help troubleshoot pagination issues
            #if DEBUG
            // print("[Pagination] KeyDown: keyCode=\(keyCode), char=\(characters)")
            #endif
            
            // Space key (keyCode 49) or 'q'/'Q' key or Enter key
            if keyCode == 49 {
                // Space key - send space to pagination handler
                // Clear the input field first to prevent interference
                self.stringValue = ""
                if let editor = self.currentEditor() as? NSTextView {
                    editor.string = ""
                    editor.needsDisplay = true
                }
                self.needsDisplay = true
                
                // Send space to pagination handler
                onPaginationKey(" ")
                NotificationCenter.default.post(name: Notification.Name("ProTermPaginationKeySent"), object: nil)
                return
            } else if characters.lowercased() == "q" {
                // Q key - send q to pagination handler
                // Clear the input field first to prevent interference
                self.stringValue = ""
                if let editor = self.currentEditor() as? NSTextView {
                    editor.string = ""
                    editor.needsDisplay = true
                }
                self.needsDisplay = true
                
                // Send q to pagination handler
                onPaginationKey("q")
                NotificationCenter.default.post(name: Notification.Name("ProTermPaginationKeySent"), object: nil)
                return
            } else if keyCode == 36 || keyCode == 76 {
                // Return/Enter key (keyCode 36 for regular, 76 for numpad)
                // Clear the input field first to prevent interference
                self.stringValue = ""
                if let editor = self.currentEditor() as? NSTextView {
                    editor.string = ""
                    editor.needsDisplay = true
                }
                self.needsDisplay = true
                
                // Send newline to pagination handler
                onPaginationKey("\n")
                NotificationCenter.default.post(name: Notification.Name("ProTermPaginationKeySent"), object: nil)
                return
            }
        }
        
        // For all other keys, use default behavior
        super.keyDown(with: event)
    }
    
    // Also handle keys when field editor is active
    override func textDidChange(_ notification: Notification) {
        super.textDidChange(notification)
        
        // If pagination is active, check for Space or Q in the input
        // Only process pagination keys if pagination is explicitly active AND we have a handler
        if isPaginationActive, let onPaginationKey = onPaginationKey {
            let currentText = self.stringValue
            // Only intercept if we have a single character (Space or Q)
            // Don't clear multi-character input - user might be typing a command
            if currentText.count == 1 {
                if currentText == " " {
                    // Space was typed - send it to pagination handler
                    onPaginationKey(" ")
                    self.stringValue = ""
                    if let editor = self.currentEditor() as? NSTextView {
                        editor.string = ""
                    }
                } else if currentText.lowercased() == "q" {
                    // Q was typed - send it to pagination handler
                    onPaginationKey("q")
                    self.stringValue = ""
                    if let editor = self.currentEditor() as? NSTextView {
                        editor.string = ""
                    }
                }
            }
            // If text is longer than 1 character, don't interfere - user is typing a command
        }
    }
    
    override var acceptsFirstResponder: Bool {
        return true
    }
    
    override func viewDidMoveToWindow() {
        super.viewDidMoveToWindow()
        hasAutoFocusedOnAttach = false
        
        // Always schedule auto focus for command input fields (those with sessionID)
        if autoFocusOnAttach || sessionID != nil {
            scheduleAutoFocus()
        }
        
        let identifier = ObjectIdentifier(self)
        let currentSessionID = sessionID
        Task { @MainActor [weak self] in
            if let self, let window = self.window {
                self.registerIfPossible()
                window.initialFirstResponder = self
                
                // For command input fields, ALWAYS try to focus when attached to window
                // Use multiple delays to ensure focus succeeds
                if self.sessionID != nil || self.autoFocusOnAttach {
                    for delay in [0.05, 0.1, 0.2, 0.3, 0.5] {
                        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                            guard let self = self, self.window != nil else { return }
                            self.forceBecomeFirstResponder(allowActivation: true)
                        }
                    }
                }
            } else if let sessionID = currentSessionID {
                CommandInputFocusController.shared.unregister(sessionID: sessionID, identifier: identifier)
            }
        }
    }
    
    func requestAutoFocus() {
        autoFocusOnAttach = true
        hasAutoFocusedOnAttach = false
        scheduleAutoFocus()
    }
    
    private func scheduleAutoFocus() {
        guard autoFocusOnAttach else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) { [weak self] in
            self?.performAutoFocusIfNeeded()
        }
    }
    
    private func performAutoFocusIfNeeded() {
        guard autoFocusOnAttach else { return }
        guard let window = self.window else {
            scheduleAutoFocus()
            return
        }
        // Always try to focus if requested, don't gate on hasAutoFocusedOnAttach too strictly
        // hasAutoFocusedOnAttach = true // Allow retries
        
        // Activate app first
        if !NSApp.isActive {
            NSApp.activate(ignoringOtherApps: true)
        }
        
        window.makeKeyAndOrderFront(nil)
        window.initialFirstResponder = self
        
        // Force focus
        forceBecomeFirstResponder()
        
        // Retry shortly to ensure the field editor is active
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.1) { [weak self] in
            self?.forceBecomeFirstResponder()
        }
        // And again
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            self?.forceBecomeFirstResponder()
        }
    }
    
    /// Force this text field to become first responder
    @MainActor
    func forceBecomeFirstResponder(allowActivation: Bool = true) {
        guard let window = self.window else { return }
        
        if !allowActivation {
            guard NSApp.isActive, window.isKeyWindow else { return }
        } else {
            if !NSApp.isActive {
                NSApp.activate(ignoringOtherApps: true)
            }
            if !window.isKeyWindow {
                window.makeKey()
            }
            if !window.isVisible {
                window.orderFront(nil)
            }
        }
        
        window.initialFirstResponder = self
        
        // Check if editor is already active - if so, just ensure cursor is visible
        if let editor = self.currentEditor() as? NSTextView,
           window.firstResponder === editor {
            // Editor already active - just ensure cursor visibility
            editor.updateInsertionPointStateAndRestartTimer(true)
            editor.setNeedsDisplay(editor.bounds)
            if let customEditor = editor as? CustomFieldEditor {
                customEditor.cursorVisible = true
                customEditor.setNeedsDisplay(customEditor.bounds)
            }
            return
        }
        
        // First, ensure our custom cell is set up
        if !(self.cell is CustomTextFieldCell) {
            let customCell = CustomTextFieldCell(textCell: self.stringValue)
            customCell.cursorStyle = cursorStyle
            customCell.cursorBlinking = cursorBlinking
            self.cell = customCell
        }
        
        // Use selectText(nil) - this is the proper way to start editing
        self.selectText(nil)
        
        // Check if editing started
        if self.currentEditor() != nil {
            self.setupEditorCursor()
        } else {
            // selectText didn't work - try calling the cell's edit method directly
            if let customCell = self.cell as? CustomTextFieldCell,
               let editor = customCell.fieldEditor(for: self) {
                // Manually start editing using the cell
                customCell.select(withFrame: self.bounds,
                                  in: self,
                                  editor: editor,
                                  delegate: self,
                                  start: 0,
                                  length: 0)
                self.setupEditorCursor()
            }
        }
        
        // Retry a few times to ensure it sticks
        for delay in [0.1, 0.2, 0.4] {
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                guard let self = self else { return }
                if self.currentEditor() == nil {
                    // If editor still not active, try selectText again
                    self.selectText(nil)
                }
                self.setupEditorCursor()
            }
        }
        
        if allowActivation, !window.isKeyWindow {
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
        }
    }
    
    @MainActor
    private func setupEditorCursor() {
        // Only use currentEditor - this is the ACTIVE editor that's properly attached
        if let editor = self.currentEditor() as? NSTextView {
            // Position cursor at end
            editor.selectedRange = NSRange(location: editor.string.count, length: 0)
            // Force cursor to be visible and blinking
            editor.updateInsertionPointStateAndRestartTimer(true)
            editor.setNeedsDisplay(editor.bounds)
            // Also set cursorVisible on CustomFieldEditor
            if let customEditor = editor as? CustomFieldEditor {
                customEditor.cursorVisible = true
                customEditor.setNeedsDisplay(customEditor.bounds)
            }
        }
    }
    var autoFocusOnAttach: Bool = false {
        didSet {
            if autoFocusOnAttach {
                hasAutoFocusedOnAttach = false
                scheduleAutoFocus()
            }
        }
    }
    private var hasAutoFocusedOnAttach = false
    
    var cursorStyle: TerminalVisualSettings.CursorStyle = .bar {
        didSet {
            MainActor.assumeIsolated {
                cursorStyleStorage[self] = cursorStyle
            }
            let updateEditor = { [weak self] in
                guard let self else { return }
                if let editor = self.currentEditor() as? NSTextView {
                    objc_setAssociatedObject(editor, &cursorStyleKey, self.cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                    editor.updateInsertionPointStateAndRestartTimer(true)
                    editor.needsDisplay = true
                }
                if let window = self.window,
                   let editor = window.fieldEditor(false, for: self) as? NSTextView {
                    objc_setAssociatedObject(editor, &cursorStyleKey, self.cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                    editor.updateInsertionPointStateAndRestartTimer(true)
                    editor.needsDisplay = true
                }
            }
            if Thread.isMainThread {
                updateCursorStyle()
                updateEditor()
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.updateCursorStyle()
                    updateEditor()
                }
            }
            if let window = self.window,
               let customEditor = window.fieldEditor(false, for: self) as? CustomFieldEditor {
                customEditor.cursorStyle = cursorStyle
            }
        }
    }
    var cursorBlinking: Bool = true {
        didSet {
            cursorBlinkingStorage[self] = cursorBlinking
            if Thread.isMainThread {
                cursorBlinking ? startCursorBlinking() : stopCursorBlinking()
            } else {
                DispatchQueue.main.async { [weak self] in
                    guard let self else { return }
                    self.cursorBlinking ? self.startCursorBlinking() : self.stopCursorBlinking()
                }
            }
            if let window = self.window,
               let customEditor = window.fieldEditor(false, for: self) as? CustomFieldEditor {
                customEditor.cursorBlinking = cursorBlinking
            }
        }
    }
    var cursorColor: NSColor = .white {
        didSet {
            updateCursorColor()
        }
    }
    var onSubmit: (() -> Void)?
    var onTab: (() -> Bool)?
    var onUpArrow: (() -> Bool)?
    var onDownArrow: (() -> Bool)?
    var isPaginationActive: Bool = false {
        didSet {
            if let editor = currentEditor() as? CustomFieldEditor {
                editor.isPaginationActive = isPaginationActive
            }
            if let window = self.window,
               let editor = window.fieldEditor(false, for: self) as? CustomFieldEditor {
                editor.isPaginationActive = isPaginationActive
            }
        }
    }
    var onPaginationKey: ((String) -> Void)? = nil {
        didSet {
            if let editor = currentEditor() as? CustomFieldEditor {
                editor.onPaginationKey = onPaginationKey
            }
            if let window = self.window,
               let editor = window.fieldEditor(false, for: self) as? CustomFieldEditor {
                editor.onPaginationKey = onPaginationKey
            }
        }
    }
    
    nonisolated(unsafe) private var cursorTimer: Timer?
    private var cursorVisible: Bool = true
    
    override func awakeFromNib() {
        super.awakeFromNib()
        DispatchQueue.main.async { [weak self] in
            self?.setupCursor()
        }
    }
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        // Initialize storage
        cursorStyleStorage[self] = .bar
        cursorBlinkingStorage[self] = true
        // Delay cursor setup to ensure delegate is set first
        DispatchQueue.main.async { [weak self] in
            self?.setupCursor()
        }
    }
    
required init?(coder: NSCoder) {
    super.init(coder: coder)
    DispatchQueue.main.async { [weak self] in
        self?.setupCursor()
    }
}
    
    private func setupCursor() {
        // Ensure we're on main thread for UI operations
        if Thread.isMainThread {
            MainActor.assumeIsolated {
                performSetupCursor()
            }
        } else {
            DispatchQueue.main.sync {
                MainActor.assumeIsolated {
                    performSetupCursor()
                }
            }
        }
    }
    
    @MainActor
    private func performSetupCursor() {
        // Use custom cell that provides custom field editor
        if !(self.cell is CustomTextFieldCell) {
            let customCell = CustomTextFieldCell(textCell: self.stringValue)
            customCell.cursorStyle = cursorStyle
            customCell.cursorBlinking = cursorBlinking
            self.cell = customCell
        }
        updateCursorStyle()
    }
    
    @MainActor
    private func updateCursorStyle() {
        // Update the custom cell if it exists
        if let customCell = self.cell as? CustomTextFieldCell {
            customCell.cursorStyle = cursorStyle
            customCell.cursorBlinking = cursorBlinking
        }
        // Update the current field editor if it exists
        if let editor = currentEditor() as? CustomFieldEditor {
            editor.cursorStyle = cursorStyle
            editor.cursorBlinking = cursorBlinking
            editor.cursorVisible = true
            editor.needsDisplay = true
            editor.updateInsertionPointStateAndRestartTimer(true)
        } else if let editor = currentEditor() as? NSTextView {
            // Force TextKit 1 by accessing layoutManager
            let _ = editor.layoutManager
            // Fallback: use associated objects for standard editor
            objc_setAssociatedObject(editor, &cursorStyleKey, cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(editor, &cursorBlinkingKey, cursorBlinking, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            editor.needsDisplay = true
            editor.updateInsertionPointStateAndRestartTimer(true)
        }
        // Also update via window's field editor
        if let window = self.window {
            if let editor = window.fieldEditor(false, for: self) as? CustomFieldEditor {
                // Force TextKit 1
                let _ = editor.layoutManager
                editor.cursorStyle = cursorStyle
                editor.cursorBlinking = cursorBlinking
                editor.cursorVisible = true
                editor.needsDisplay = true
                editor.updateInsertionPointStateAndRestartTimer(true)
            } else if let editor = window.fieldEditor(false, for: self) as? NSTextView {
                // Force TextKit 1 by accessing layoutManager
                let _ = editor.layoutManager
                objc_setAssociatedObject(editor, &cursorStyleKey, cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                objc_setAssociatedObject(editor, &cursorBlinkingKey, cursorBlinking, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
                editor.needsDisplay = true
                editor.updateInsertionPointStateAndRestartTimer(true)
            }
        }
        updateCursorColor()
    }
    
    @MainActor
    private func updateCursorColor() {
        if let editor = currentEditor() as? NSTextView {
            editor.insertionPointColor = cursorColor
            editor.needsDisplay = true
            objc_setAssociatedObject(editor, &cursorColorKey, cursorColor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        if let window = self.window,
           let editor = window.fieldEditor(false, for: self) as? NSTextView {
            editor.insertionPointColor = cursorColor
            editor.needsDisplay = true
            objc_setAssociatedObject(editor, &cursorColorKey, cursorColor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
    }
    
    // Override to provide custom field editor and handle cursor blinking
    override func becomeFirstResponder() -> Bool {
        let result = super.becomeFirstResponder()
        if result {
            // Replace the field editor with our custom one
            DispatchQueue.main.async { [weak self] in
                guard let self = self, let window = self.window else { return }
                // Get the current field editor
                if let currentEditor = window.fieldEditor(false, for: self) as? NSTextView {
                    // Create a custom field editor wrapper
                    let customEditor = CustomFieldEditor()
                    customEditor.cursorStyle = self.cursorStyle
                    customEditor.cursorBlinking = self.cursorBlinking
                    customEditor.string = currentEditor.string
                    customEditor.selectedRange = currentEditor.selectedRange
                    customEditor.font = currentEditor.font
                    customEditor.textColor = currentEditor.textColor
                    customEditor.backgroundColor = currentEditor.backgroundColor
                    customEditor.isEditable = currentEditor.isEditable
                    customEditor.isSelectable = currentEditor.isSelectable
                    
                    // Try to replace the field editor (this might not work, but worth trying)
                    // Actually, we can't easily replace the window's field editor
                    // So we'll use the swizzling approach, but ensure it's working
                }
            }
            // Handle cursor blinking
            if cursorBlinking {
                if Thread.isMainThread {
                    startCursorBlinking()
                } else {
                    DispatchQueue.main.async { [weak self] in
                        self?.startCursorBlinking()
                    }
                }
            }
            // Set up custom field editor after becoming first responder
            DispatchQueue.main.async { [weak self] in
                self?.setupCustomFieldEditor()
            }
        }
        return result
    }
    
    @MainActor
    private func setupCustomFieldEditor() {
        guard let window = self.window else { return }
        // Get or create the field editor
        let editor = window.fieldEditor(false, for: self)
        
        // Force TextKit 1 by accessing layoutManager (TextKit 2 doesn't use drawInsertionPoint)
        if let textView = editor as? NSTextView {
            // Force TextKit 1 by accessing layoutManager - this should force it to use TextKit 1
            let _ = textView.layoutManager
            
            // Store cursor style directly on the editor using associated objects
            objc_setAssociatedObject(textView, &cursorStyleKey, cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(textView, &cursorBlinkingKey, cursorBlinking, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
        }
        
        // Update cursor style when editor becomes active
        updateCursorStyle()
        
        // Also set up a notification to update when editor changes
        NotificationCenter.default.addObserver(
            forName: NSText.didBeginEditingNotification,
            object: editor,
            queue: .main
        ) { [weak self] _ in
            DispatchQueue.main.async {
                self?.updateCursorStyle()
            }
        }
    }
    
    @MainActor
    private func startCursorBlinking() {
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            DispatchQueue.main.async {
                self?.cursorVisible.toggle()
                if let customCell = self?.cell as? CustomTextFieldCell {
                    customCell.cursorVisible = self?.cursorVisible ?? true
                    self?.currentEditor()?.needsDisplay = true
                }
            }
        }
    }
    
    @MainActor
    private func stopCursorBlinking() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorVisible = true
        if let customCell = self.cell as? CustomTextFieldCell {
            customCell.cursorVisible = true
        }
    }
    
    override func resignFirstResponder() -> Bool {
        if Thread.isMainThread {
            stopCursorBlinking()
        } else {
            DispatchQueue.main.async { [weak self] in
                self?.stopCursorBlinking()
            }
        }
        return super.resignFirstResponder()
    }
    
    deinit {
        // Clean up timer - invalidate synchronously if on main thread
        if Thread.isMainThread, let timer = cursorTimer {
            timer.invalidate()
        } else if let timer = cursorTimer {
            DispatchQueue.main.sync {
                timer.invalidate()
            }
        }

        let id = sessionID
        let identifier = ObjectIdentifier(self)
        if let id {
            Task { @MainActor in
                CommandInputFocusController.shared.unregister(sessionID: id, identifier: identifier)
            }
        }
    }

    @MainActor
    private func registerIfPossible() {
        guard let sessionID = sessionID, window != nil else { return }
        CommandInputFocusController.shared.register(field: self, sessionID: sessionID)
    }
}

/// Custom NSTextFieldCell that provides a custom field editor
class CustomTextFieldCell: NSTextFieldCell {
    var cursorStyle: TerminalVisualSettings.CursorStyle = .bar {
        didSet {
            // Update field editor if it exists
            updateFieldEditor()
        }
    }
    var cursorBlinking: Bool = true {
        didSet {
            updateFieldEditor()
        }
    }
    var cursorVisible: Bool = true {
        didSet {
            updateFieldEditor()
        }
    }
    
    private func updateFieldEditor() {
        if let controlView = self.controlView {
            // Update via window's field editor
            if let editor = controlView.window?.fieldEditor(false, for: controlView) as? CustomFieldEditor {
                editor.cursorStyle = cursorStyle
                editor.cursorBlinking = cursorBlinking
                editor.cursorVisible = cursorVisible
                editor.needsDisplay = true
            }
            // Also update current editor (if controlView is an NSControl)
            if let control = controlView as? NSControl,
               let editor = control.currentEditor() as? CustomFieldEditor {
                editor.cursorStyle = cursorStyle
                editor.cursorBlinking = cursorBlinking
                editor.cursorVisible = cursorVisible
                editor.needsDisplay = true
            }
        }
    }
    
    override func fieldEditor(for controlView: NSView) -> NSTextView? {
        guard let customField = controlView as? CustomNSTextField else {
            return super.fieldEditor(for: controlView)
        }
        return CustomFieldEditorPool.shared.editor(for: customField)
    }
}

/// Custom field editor (NSTextView) that draws custom cursor styles
class CustomFieldEditor: NSTextView {
    var cursorStyle: TerminalVisualSettings.CursorStyle = .bar {
        didSet {
            updateInsertionPointStateAndRestartTimer(true)
            needsDisplay = true
        }
    }
    var cursorBlinking: Bool = true
    var cursorVisible: Bool = true
    var isPaginationActive: Bool = false
    var onPaginationKey: ((String) -> Void)? = nil
    
    override var isFieldEditor: Bool {
        get { true }
        set { /* ignore */ }
    }
    
    override func keyDown(with event: NSEvent) {
        // If pagination is active, intercept Space, Enter, and Q keys
        if isPaginationActive, let onPaginationKey = onPaginationKey {
            let keyCode = event.keyCode
            let characters = event.charactersIgnoringModifiers ?? ""
            
            // Debug logging to help troubleshoot pagination issues
            #if DEBUG
            // print("[Pagination-Editor] KeyDown: keyCode=\(keyCode), char=\(characters)")
            #endif
            
            // Space key (keyCode 49) or 'q'/'Q' key or Enter key
            if keyCode == 49 {
                // Space key - send space to pagination handler
                self.string = ""
                self.needsDisplay = true
                onPaginationKey(" ")
                // Record the time to maintain the cooldown in TerminalView
                NotificationCenter.default.post(name: Notification.Name("ProTermPaginationKeySent"), object: nil)
                return
            } else if characters.lowercased() == "q" {
                // Q key - send q to pagination handler
                self.string = ""
                self.needsDisplay = true
                onPaginationKey("q")
                NotificationCenter.default.post(name: Notification.Name("ProTermPaginationKeySent"), object: nil)
                return
            } else if keyCode == 36 || keyCode == 76 {
                // Return/Enter key (keyCode 36 for regular, 76 for numpad)
                self.string = ""
                self.needsDisplay = true
                onPaginationKey("\n")
                NotificationCenter.default.post(name: Notification.Name("ProTermPaginationKeySent"), object: nil)
                return
            }
        }
        
        super.keyDown(with: event)
    }
    
    override func draw(_ dirtyRect: NSRect) {
        // Call super to draw the text
        super.draw(dirtyRect)
        
        // Manually draw the cursor if it should be visible
        if window?.firstResponder === self && cursorVisible {
            if let insertionPointRect = insertionPointRect() {
                drawCustomCursor(in: insertionPointRect)
            }
        }
    }
    
    private func insertionPointRect() -> NSRect? {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return nil }
        
        let selectedRange = selectedRange()
        guard selectedRange.length == 0 else { return nil }
        
        // Handle empty text - return a rect at the start of the text container
        if string.isEmpty {
            let lineHeight = font?.pointSize ?? 14.0
            let origin = textContainerOrigin
            return NSRect(x: origin.x, y: origin.y, width: 2, height: lineHeight * 1.2)
        }
        
        // For non-empty text, get the rect from layout manager
        let location = min(selectedRange.location, string.count)
        if location >= string.count {
            // Cursor at end - get rect after last character
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: max(0, string.count - 1), length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            return NSRect(x: rect.maxX, y: rect.origin.y, width: 2, height: rect.height)
        } else {
            let characterRange = NSRange(location: location, length: 1)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            return NSRect(x: rect.origin.x, y: rect.origin.y, width: 2, height: rect.height)
        }
    }
    
    private func expandedRect(from rect: NSRect) -> NSRect {
        let width: CGFloat
        if let font = font {
            width = max(rect.width, font.maximumAdvancement.width)
        } else {
            width = max(rect.width, 8)
        }
        return NSRect(x: rect.origin.x, y: rect.origin.y, width: width, height: rect.height)
    }
    
    private func drawCustomCursor(in rect: NSRect) {
        let fullRect = expandedRect(from: rect)
        guard let color = insertionPointColor else { return }
        color.set()
        
        switch cursorStyle {
        case .bar:
            // Vertical line (default)
            NSBezierPath.strokeLine(from: NSPoint(x: rect.midX, y: rect.minY), to: NSPoint(x: rect.midX, y: rect.maxY))
            
        case .block:
            // Solid block
            NSBezierPath(rect: fullRect).fill()
            
        case .underline:
            // Underline
            let underlineRect = NSRect(x: fullRect.origin.x, y: fullRect.origin.y, width: fullRect.width, height: 2)
            NSBezierPath(rect: underlineRect).fill()
            
        case .hollowBlock:
            // Hollow block (outline)
            let path = NSBezierPath(rect: fullRect)
            path.lineWidth = 1.0
            path.stroke()
        }
    }
    
    override func drawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn: Bool) {
        guard turnedOn && cursorVisible else { 
            return 
        }
        
        // Use our custom drawing
        drawCustomCursor(in: rect)
    }
    
    override func updateInsertionPointStateAndRestartTimer(_ restartFlag: Bool) {
        super.updateInsertionPointStateAndRestartTimer(restartFlag && cursorBlinking)
        // Force redraw when cursor state changes
        needsDisplay = true
    }
}

extension CustomFieldEditor {
    func apply(from field: CustomNSTextField) {
        cursorStyle = field.cursorStyle
        cursorBlinking = field.cursorBlinking
        isPaginationActive = field.isPaginationActive
        onPaginationKey = field.onPaginationKey
        font = field.font
        textColor = field.textColor
        insertionPointColor = field.cursorColor
        backgroundColor = .clear
        drawsBackground = false
        isRichText = false
        usesFindPanel = false
        usesRuler = false
        isContinuousSpellCheckingEnabled = false
        isAutomaticQuoteSubstitutionEnabled = false
        isAutomaticDashSubstitutionEnabled = false
        isAutomaticDataDetectionEnabled = false
        isAutomaticLinkDetectionEnabled = false
        isAutomaticSpellingCorrectionEnabled = false
    }
}

// Extension on NSTextView to apply custom cursor styles using method swizzling
extension NSTextView {
    private static var swizzled = false
    private static var swizzledDraw = false
    private static var originalDrawInsertionPointIMP: IMP?
    private static var originalDrawIMP: IMP?
    
    @objc dynamic func customDrawInsertionPoint(in rect: NSRect, color: NSColor, turnedOn: Bool) {
        // Get cursor style directly from associated object on this text view
        if let storedStyle = objc_getAssociatedObject(self, &cursorStyleKey) as? TerminalVisualSettings.CursorStyle {
            // Use the stored cursor style
            guard turnedOn else { 
                return 
            }
            let insertionColor = (objc_getAssociatedObject(self, &cursorColorKey) as? NSColor) ?? color
            insertionColor.set()
            
            // Draw custom cursor based on style
            switch storedStyle {
            case .bar:
                // Vertical line cursor (default)
                NSBezierPath.strokeLine(from: NSPoint(x: rect.midX, y: rect.minY), to: NSPoint(x: rect.midX, y: rect.maxY))
            case .block:
                // Solid block - fill the entire rect
                NSBezierPath(rect: rect).fill()
            case .underline:
                // Underline - draw a line at the bottom
                let underlineRect = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: 2)
                NSBezierPath(rect: underlineRect).fill()
            case .hollowBlock:
                // Hollow block - stroke the rect
                let path = NSBezierPath(rect: rect)
                path.lineWidth = 1.0
                path.stroke()
            }
            return
        }
        
        // Fallback: try to get cursor style from the text field that owns this editor
        // Check if this editor is associated with a CustomNSTextField
        if let textField = self.delegate as? NSTextField,
           let customField = textField as? CustomNSTextField {
            guard turnedOn else { return }
            let insertionColor = customField.cursorColor
            insertionColor.set()
            
            // Set the associated object for future calls
            objc_setAssociatedObject(self, &cursorStyleKey, customField.cursorStyle, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            objc_setAssociatedObject(self, &cursorColorKey, insertionColor, .OBJC_ASSOCIATION_RETAIN_NONATOMIC)
            
            switch customField.cursorStyle {
            case .bar:
                NSBezierPath.strokeLine(from: NSPoint(x: rect.midX, y: rect.minY), to: NSPoint(x: rect.midX, y: rect.maxY))
            case .block:
                NSBezierPath(rect: rect).fill()
            case .underline:
                let underlineRect = NSRect(x: rect.origin.x, y: rect.origin.y, width: rect.width, height: 2)
                NSBezierPath(rect: underlineRect).fill()
            case .hollowBlock:
                let path = NSBezierPath(rect: rect)
                path.lineWidth = 1.0
                path.stroke()
            }
            return
        }
        
        // Default behavior - draw a simple vertical bar
        guard turnedOn else { return }
        let insertionColor = (objc_getAssociatedObject(self, &cursorColorKey) as? NSColor) ?? color
        insertionColor.set()
        NSBezierPath.strokeLine(from: NSPoint(x: rect.midX, y: rect.minY), to: NSPoint(x: rect.midX, y: rect.maxY))
    }
    
    // Helper methods for manual cursor drawing (used by swizzled draw method)
    private func getInsertionPointRect() -> NSRect? {
        guard let layoutManager = layoutManager,
              let textContainer = textContainer else { return nil }
        
        let selectedRange = selectedRange()
        guard selectedRange.length == 0 else { return nil }
        
        // Handle empty text - return a rect at the start of the text container
        if string.isEmpty {
            let lineHeight = font?.pointSize ?? 14.0
            let origin = textContainerOrigin
            return NSRect(x: origin.x, y: origin.y, width: 2, height: lineHeight * 1.2)
        }
        
        // For non-empty text, get the rect from layout manager
        let location = min(selectedRange.location, string.count)
        if location >= string.count {
            // Cursor at end - get rect after last character
            let glyphRange = layoutManager.glyphRange(forCharacterRange: NSRange(location: max(0, string.count - 1), length: 1), actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            return NSRect(x: rect.maxX, y: rect.origin.y, width: 2, height: rect.height)
        } else {
            let characterRange = NSRange(location: location, length: 1)
            let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
            let rect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
            return NSRect(x: rect.origin.x, y: rect.origin.y, width: 2, height: rect.height)
        }
    }
    
    private func expandedRectUsingFont(from rect: NSRect) -> NSRect {
        let width: CGFloat
        if let font = font {
            width = max(rect.width, font.maximumAdvancement.width)
        } else {
            width = max(rect.width, 8)
        }
        return NSRect(x: rect.origin.x, y: rect.origin.y, width: width, height: rect.height)
    }
    
    private func drawCustomCursor(style: TerminalVisualSettings.CursorStyle, in rect: NSRect) {
        let fullRect = expandedRectUsingFont(from: rect)
        guard let color = insertionPointColor else { return }
        color.set()
        
        switch style {
        case .bar:
            // Vertical line (default)
            NSBezierPath.strokeLine(from: NSPoint(x: rect.midX, y: rect.minY), to: NSPoint(x: rect.midX, y: rect.maxY))
            
        case .block:
            // Solid block - use full character width
            if let layoutManager = layoutManager, let textContainer = textContainer {
                let selectedRange = selectedRange()
                let characterRange = NSRange(location: selectedRange.location, length: 1)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
                let charRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let rectToDraw = charRect.width > 0 ? charRect : fullRect
                NSBezierPath(rect: rectToDraw).fill()
            } else {
                NSBezierPath(rect: fullRect).fill()
            }
            
        case .underline:
            // Underline
            let underlineRect = NSRect(x: fullRect.origin.x, y: fullRect.origin.y, width: fullRect.width, height: 2)
            NSBezierPath(rect: underlineRect).fill()
            
        case .hollowBlock:
            // Hollow block (outline)
            if let layoutManager = layoutManager, let textContainer = textContainer {
                let selectedRange = selectedRange()
                let characterRange = NSRange(location: selectedRange.location, length: 1)
                let glyphRange = layoutManager.glyphRange(forCharacterRange: characterRange, actualCharacterRange: nil)
                let charRect = layoutManager.boundingRect(forGlyphRange: glyphRange, in: textContainer)
                let rectToDraw = charRect.width > 0 ? charRect : fullRect
                let path = NSBezierPath(rect: rectToDraw)
                path.lineWidth = 1.0
                path.stroke()
            } else {
                let path = NSBezierPath(rect: fullRect)
                path.lineWidth = 1.0
                path.stroke()
            }
        }
    }
    
    // Swizzled draw method to manually draw cursor
    @objc dynamic func customDraw(_ dirtyRect: NSRect) {
        // Call original draw first
        if let originalDrawIMP = NSTextView.originalDrawIMP {
            let originalFunc = unsafeBitCast(originalDrawIMP, to: NSViewDrawFunc.self)
            originalFunc(self, #selector(NSView.draw(_:)), dirtyRect)
        }
        
        // Manually draw the cursor if we have a stored style
        if let storedStyle = objc_getAssociatedObject(self, &cursorStyleKey) as? TerminalVisualSettings.CursorStyle {
            // Check if this is the first responder and cursor should be visible
            if window?.firstResponder === self {
                // Get insertion point rect
                if let insertionRect = getInsertionPointRect() {
                    drawCustomCursor(style: storedStyle, in: insertionRect)
                }
            }
        }
    }
    
    // Swizzle the drawInsertionPoint method
    static func swizzleDrawInsertionPoint() {
        guard !swizzled else { 
            return 
        }
        swizzled = true
        
        let originalSelector = #selector(NSTextView.drawInsertionPoint(in:color:turnedOn:))
        let swizzledSelector = #selector(NSTextView.customDrawInsertionPoint(in:color:turnedOn:))
        
        guard let originalMethod = class_getInstanceMethod(self, originalSelector) else {
            return
        }
        
        guard let swizzledMethod = class_getInstanceMethod(self, swizzledSelector) else {
            return
        }
        
        // Store the original implementation
        originalDrawInsertionPointIMP = method_getImplementation(originalMethod)
        
        // Swap implementations
        method_exchangeImplementations(originalMethod, swizzledMethod)
        
        // Also swizzle the draw method to manually draw cursor
        swizzleDraw()
    }
    
    // Swizzle the draw method to manually draw cursor
    static func swizzleDraw() {
        guard !swizzledDraw else {
            return
        }
        swizzledDraw = true
        
        let originalSelector = #selector(NSView.draw(_:))
        let swizzledSelector = #selector(NSTextView.customDraw(_:))
        
        guard let originalMethod = class_getInstanceMethod(NSView.self, originalSelector) else {
            print("⚠️ CustomTextField: Failed to get original draw method")
            return
        }
        
        guard let swizzledMethod = class_getInstanceMethod(self, swizzledSelector) else {
            print("⚠️ CustomTextField: Failed to get customDraw method")
            return
        }
        
        // Store the original implementation
        originalDrawIMP = method_getImplementation(originalMethod)
        
        // Add the custom method if it doesn't exist, then exchange
        if !class_addMethod(self, originalSelector, method_getImplementation(swizzledMethod), method_getTypeEncoding(swizzledMethod)) {
            method_exchangeImplementations(originalMethod, swizzledMethod)
        }
    }
}
