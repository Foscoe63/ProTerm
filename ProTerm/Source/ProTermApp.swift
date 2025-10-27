import SwiftUI

@main
struct ProTermApp: App {
    @StateObject private var terminalManager = TerminalManager()
    @StateObject private var themeManager   = ThemeManager()
    @StateObject private var shellManager   = ShellManager()
    @StateObject private var lineNumbersManager = LineNumbersManager()
    @StateObject private var keyboardShortcutsManager = KeyboardShortcutsManager()
    @StateObject private var advancedTextSelection = AdvancedTextSelection()
    @StateObject private var visualEnhancements = VisualEnhancements()
    @StateObject private var advancedFeatures = AdvancedFeatures()
    @StateObject private var productivityTools = ProductivityTools()
    @StateObject private var integrationFeatures = IntegrationFeatures()

    // Initialize crash reporter and notification helper early
    init() {
        _ = CrashReporter.shared
        _ = NotificationHelper.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(terminalManager)
                .environmentObject(themeManager)
                .environmentObject(shellManager)
                .environmentObject(lineNumbersManager)
                .environmentObject(keyboardShortcutsManager)
                .environmentObject(advancedTextSelection)
                .environmentObject(visualEnhancements)
                .environmentObject(advancedFeatures)
                .environmentObject(productivityTools)
                .environmentObject(integrationFeatures)
                .frame(minWidth: 800, minHeight: 600)
        }
        // ------------------------------------------------------------
        // ❌ Removed the built‑in Settings scene – it was creating the
        //    unwanted vertical split view.
        // ------------------------------------------------------------

        // Optional: add a menu command that opens the same sheet
        .commands {
            CommandGroup(replacing: .appSettings) {   // replaces the default “Preferences…” menu item
                Button("Preferences…") {
                    // Post a notification that the button bar is listening for.
                    NotificationCenter.default.post(name: .showPreferences, object: nil)
                }
                .keyboardShortcut(",", modifiers: [.command])
            }
        }
    }
}

// MARK: – Notification used by the gear‑button sheet

extension Notification.Name {
    static let showPreferences = Notification.Name("ProTermShowPreferences")
}
