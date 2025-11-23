import SwiftUI

@main
struct ProTermApp: App {
    @StateObject private var terminalManager: TerminalManager
    @StateObject private var themeManager: ThemeManager
    @StateObject private var shellManager: ShellManager
    @StateObject private var lineNumbersManager: LineNumbersManager
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
        _lineNumbersManager = StateObject(wrappedValue: LineNumbersManager())
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
                .environmentObject(lineNumbersManager)
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
    
    private func startFocusPolling() {
        // Poll for the text field and set focus multiple times with increasing delays
        let delays: [UInt64] = [
            50_000_000,    // 0.05s
            100_000_000,   // 0.1s
            200_000_000,   // 0.2s
            300_000_000,   // 0.3s
            500_000_000,   // 0.5s
            700_000_000,   // 0.7s
            1_000_000_000, // 1.0s
            1_500_000_000, // 1.5s
            2_000_000_000  // 2.0s (final attempt)
        ]
        
        for delay in delays {
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: delay)
                self.attemptFocus()
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
            // Wait a moment for window to become key
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 50_000_000) // 0.05s
                self.attemptFocus() // Retry after window becomes key
            }
            return
        }
        
        // Find and focus the text field
        if let textField = findTextField(in: window.contentView) {
            window.initialFirstResponder = textField
            let success = window.makeFirstResponder(textField)
            
            if success {
                // Also try to focus the field editor
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    if let editor = textField.currentEditor() {
                        window.makeFirstResponder(editor)
                    }
                }
            } else {
                // Failed to set focus - window might not be key yet, retry
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.attemptFocus()
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
