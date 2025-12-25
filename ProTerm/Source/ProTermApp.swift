import SwiftUI

@main
struct ProTermApp: App {
    @StateObject private var terminalManager: TerminalManager
    @StateObject private var themeManager: ThemeManager
    @StateObject private var shellManager: ShellManager
    @StateObject private var keyboardShortcutsManager: KeyboardShortcutsManager
    @StateObject private var fontManager: FontManager
    @StateObject private var advancedTextSelection: AdvancedTextSelection
    @StateObject private var visualEnhancements: VisualEnhancements
    @StateObject private var advancedFeatures: AdvancedFeatures
    @StateObject private var productivityTools: ProductivityTools
    @StateObject private var integrationFeatures: IntegrationFeatures
    @StateObject private var terminalVisualSettings: TerminalVisualSettings
    @StateObject private var aiManager: AIManager
    
    init() {
        let terminalManager = TerminalManager()
        let fontManager = FontManager()
        let themeManager = ThemeManager()
        themeManager.attachFontManager(fontManager)
        
        _terminalManager = StateObject(wrappedValue: terminalManager)
        _themeManager = StateObject(wrappedValue: themeManager)
        _shellManager = StateObject(wrappedValue: ShellManager())
        _keyboardShortcutsManager = StateObject(wrappedValue: KeyboardShortcutsManager())
        _fontManager = StateObject(wrappedValue: fontManager)
        _advancedTextSelection = StateObject(wrappedValue: AdvancedTextSelection())
        _visualEnhancements = StateObject(wrappedValue: VisualEnhancements())
        _advancedFeatures = StateObject(wrappedValue: AdvancedFeatures())
        _productivityTools = StateObject(wrappedValue: ProductivityTools())
        _integrationFeatures = StateObject(wrappedValue: IntegrationFeatures())
        _terminalVisualSettings = StateObject(wrappedValue: TerminalVisualSettings())
        _aiManager = StateObject(wrappedValue: AIManager())
    }

    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(terminalManager)
                .environmentObject(themeManager)
                .environmentObject(shellManager)
                .environmentObject(keyboardShortcutsManager)
                .environmentObject(fontManager)
                .environmentObject(advancedTextSelection)
                .environmentObject(visualEnhancements)
                .environmentObject(advancedFeatures)
                .environmentObject(productivityTools)
                .environmentObject(integrationFeatures)
                .environmentObject(terminalVisualSettings)
                .environmentObject(aiManager)
                .frame(minWidth: 800, minHeight: 600)
        }
        // ------------------------------------------------------------
        // ❌ Removed the built‑in Settings scene – it was creating the
        //    unwanted vertical split view.
        // ------------------------------------------------------------

        // Optional: add a menu command that opens the same sheet
        .commands {
            CommandGroup(replacing: .appSettings) {   // replaces the default "Preferences…" menu item
                Button("Preferences…") {
                    // Post a notification that the button bar is listening for.
                    NotificationCenter.default.post(name: Notification.Name("ProTermShowPreferences"), object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

@MainActor
class AppDelegate: NSObject, NSApplicationDelegate {
    
    func applicationWillFinishLaunching(_ notification: Notification) {
        // This is called BEFORE the window is shown - perfect time to set initial focus
        // Schedule a task to find and set the initial first responder
        Task { @MainActor in
            // Give SwiftUI a tiny moment to create the window
            try? await Task.sleep(nanoseconds: 10_000_000) // 0.01s
            
            if let window = NSApp.windows.first {
                // CRITICAL: Make window key immediately
                NSApp.activate(ignoringOtherApps: true)
                window.makeKeyAndOrderFront(nil)
                
                // Try to find the text field
                if let textField = findTextField(in: window.contentView) {
                    window.initialFirstResponder = textField
                }
            }
        }
    }
    
    func applicationDidFinishLaunching(_ notification: Notification) {
        // Initialize crash reporter and notification helper early
        _ = CrashReporter.shared
        _ = NotificationHelper.shared
        
        // CRITICAL: Force app activation immediately
        NSApp.activate(ignoringOtherApps: true)
        
        // Ensure window is key immediately
        if let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            if !window.isKeyWindow {
                window.makeKey()
            }
        }
        
        // Start aggressive focus polling
        startFocusPolling()
    }
    
    func applicationDidBecomeActive(_ notification: Notification) {
        // When app becomes active, ensure window is key and focus is set
        NSApp.activate(ignoringOtherApps: true)
        if let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first {
            window.makeKeyAndOrderFront(nil)
            if !window.isKeyWindow {
                window.makeKey()
            }
            // Post focus notification
            NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: nil)
        }
    }
    
    private var focusAttemptCount = 0
    
    private func startFocusPolling() {
        focusAttemptCount = 0
        
        // Use Task-based polling instead of Timer to avoid sendable issues
        Task { @MainActor in
            for _ in 1...50 {
                // Check if focus succeeded (text field is first responder or its editor is)
                if let window = NSApp.windows.first(where: { $0.isVisible }),
                   let firstResponder = window.firstResponder {
                    // If first responder is a text view (field editor) or text field, focus succeeded
                    if firstResponder is NSTextView || firstResponder is NSTextField {
                        return
                    }
                }
                
                self.attemptFocus()
                
                // Wait 0.1 seconds before next attempt
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
    }
    
    private func attemptFocus() {
        // Force app activation
        NSApp.activate(ignoringOtherApps: true)
        
        // Find the window
        guard let window = NSApp.windows.first(where: { $0.isVisible }) ?? NSApp.windows.first else {
            return
        }
        
        // CRITICAL: Make window key - this is essential for focus to work
        if !window.isKeyWindow {
            window.makeKeyAndOrderFront(nil)
            window.makeKey()
            return // Will be retried by the polling loop
        }
        
        // Find and focus the text field
        if let textField = findTextField(in: window.contentView) {
            window.initialFirstResponder = textField
            
            // Use selectText(nil) - the ONLY proper way to start editing
            // It makes the field first responder AND properly attaches the field editor
            textField.selectText(nil)
            
            // Defer cursor setup to next run loop
            DispatchQueue.main.async {
                if let editor = textField.currentEditor() as? NSTextView {
                    // Position cursor at end
                    editor.selectedRange = NSRange(location: editor.string.count, length: 0)
                    // Force cursor to be visible
                    editor.updateInsertionPointStateAndRestartTimer(true)
                    editor.needsDisplay = true
                    // Also set cursorVisible on CustomFieldEditor
                    if let customEditor = editor as? CustomFieldEditor {
                        customEditor.cursorVisible = true
                        customEditor.needsDisplay = true
                    }
                }
            }
        } else {
            // Text field not found yet - post notification as fallback
            NotificationCenter.default.post(name: Notification.Name("ProTermFocusCommandInput"), object: nil)
        }
    }
    
    private func findTextField(in view: NSView?) -> NSTextField? {
        guard let view = view else { return nil }
        
        // Check if this view is an editable text field
        if let textField = view as? NSTextField, textField.isEditable {
            // Ensure it's actually in the view hierarchy and ready
            if textField.window != nil && textField.superview != nil && !textField.isHidden {
                return textField
            }
        }
        
        // Recursively search subviews
        for subview in view.subviews {
            if let found = findTextField(in: subview) {
                return found
            }
        }
        
        return nil
    }
}

// MARK: – Notification used by the gear‑button sheet

extension Notification.Name {
    static let closePreferences = Notification.Name("ProTermClosePreferences")
}
