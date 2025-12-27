import SwiftUI
import AppKit

/// A view that accesses the NSWindow and sets up focus handling on app startup
@MainActor
struct WindowAccessor: NSViewRepresentable {
    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        view.frame = .zero
        view.isHidden = true
        
        // Initialize coordinator
        context.coordinator.setup()
        
        // Start waiting for window attachment
        DispatchQueue.main.async {
            Task { @MainActor in
                await context.coordinator.waitForWindowAttachment(view: view)
            }
        }
        
        return view
    }
    
    func updateNSView(_ nsView: NSView, context: Context) {
        // Ensure focus is set whenever the view updates
        Task { @MainActor in
            if let window = nsView.window ?? NSApplication.shared.mainWindow {
                context.coordinator.focusCommandInput(in: window, retryCount: 0)
            }
        }
    }
    
    func makeCoordinator() -> Coordinator {
        Coordinator()
    }
    
    @MainActor
    class Coordinator {
        weak var window: NSWindow?
        nonisolated(unsafe) var keyObserver: NSObjectProtocol?
        nonisolated(unsafe) var launchObserver: NSObjectProtocol?
        nonisolated(unsafe) var visibleObserver: NSObjectProtocol?
        private var hasSetupFocus = false
        private let focusController = CommandInputFocusController.shared
        
        deinit {
            // NotificationCenter.removeObserver is thread-safe, so we can call it from deinit
            if let observer = keyObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = launchObserver {
                NotificationCenter.default.removeObserver(observer)
            }
            if let observer = visibleObserver {
                NotificationCenter.default.removeObserver(observer)
            }
        }
        
        func setup() {
            // Listen for app launch completion (important when running outside Xcode)
            launchObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didFinishLaunchingNotification,
                object: nil,
                queue: .main
            ) { [weak self] _ in
                Task { @MainActor in
                    // Give the app a moment to finish launching, then try to find window
                    try? await Task.sleep(nanoseconds: 200_000_000) // 0.2 seconds
                    if let window = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow {
                        self?.setupWindowFocus(window)
                    }
                }
            }
            
            // Listen for when windows become visible - ensure they become key
            visibleObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeMainNotification,
                object: nil,
                queue: .main
            ) { [weak self] notification in
                // Extract window before entering Task to avoid sendable issues
                guard let window = notification.object as? NSWindow else { return }
                Task { @MainActor [weak self] in
                    guard let self,
                          let trackedWindow = self.window,
                          trackedWindow === window else { return }
                    // Check visibility inside MainActor context
                    guard window.isVisible else { return }
                    // Ensure window becomes key when it becomes main
                    NSApp.activate(ignoringOtherApps: true)
                    if !window.isKeyWindow {
                        window.makeKeyAndOrderFront(nil)
                        window.makeKey()
                    }
                    // Post focus notification
                    NotificationCenter.default.post(
                        name: .focusCommandInput,
                        object: nil
                    )
                }
            }
        }
        
        func waitForWindowAttachment(view: NSView) async {
            // Try for up to 3 seconds (60 attempts * 50ms)
            for _ in 0..<60 {
                // Check multiple ways to find the window
                let foundWindow = view.window ?? 
                                 NSApplication.shared.mainWindow ?? 
                                 NSApplication.shared.keyWindow ??
                                 NSApplication.shared.windows.first { $0.isVisible && $0.isKeyWindow }
                
                if let window = foundWindow, window.isVisible {
                    setupWindowFocus(window)
                    return
                }
                
                // Wait before next attempt
                try? await Task.sleep(nanoseconds: 50_000_000) // 50 ms
            }
            
            // Fallback: try one more time after a longer delay
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 500_000_000) // 0.5 seconds
                if let window = NSApplication.shared.mainWindow ?? NSApplication.shared.keyWindow {
                    self.setupWindowFocus(window)
                }
            }
        }

        private func setupWindowFocus(_ window: NSWindow) {
            guard !hasSetupFocus else { return }
            hasSetupFocus = true
            
            self.window = window
            
            // CRITICAL: Force the window to become key and visible
            // This is what makes focus work when clicking away and back
            NSApp.activate(ignoringOtherApps: true)
            window.makeKeyAndOrderFront(nil)
            
            // CRITICAL: Ensure window is actually key - sometimes makeKeyAndOrderFront doesn't work immediately
            // This is especially important when running outside Xcode
            if !window.isKeyWindow {
                window.makeKey()
                // Sometimes we need to order front again after makeKey
                window.makeKeyAndOrderFront(nil)
            }
            
            // Broadcast a focus request so any TerminalView that's already mounted can focus its input
            NotificationCenter.default.post(
                name: .focusCommandInput,
                object: nil
            )

            // Immediately attempt to focus the command input once on setup to avoid races
            // where the later scheduled attempts might miss the initial mount timing.
            Task { @MainActor in
                self.focusCommandInput(in: window, retryCount: 0)
            }

            // Set up observer for when window becomes key - this is the most reliable
            // The closure runs on .main queue, so we're already on MainActor
            keyObserver = NotificationCenter.default.addObserver(
                forName: NSWindow.didBecomeKeyNotification,
                object: window,
                queue: .main
            ) { [weak self] notification in
                // Extract window from notification
                if let window = notification.object as? NSWindow {
                    // We're already on main queue, so safe to call directly
                    // When window becomes key (like when clicking back), focus immediately
                    // Also broadcast a focus request so the active TerminalView can enforce focus
                    NotificationCenter.default.post(
                        name: .focusCommandInput,
                        object: nil
                    )
                    // Ensure MainActor isolation when calling a @MainActor method
                    Task { @MainActor in
                        self?.focusCommandInput(in: window, retryCount: 0)
                    }
                }
            }
            
            // Wait a moment for window to fully become key, then start focusing
            Task { @MainActor in
                // Give window time to become key
                try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                
                // Force window to be key one more time
                if !window.isKeyWindow {
                    NSApp.activate(ignoringOtherApps: true)
                    window.makeKey()
                    window.makeKeyAndOrderFront(nil)
                }
                
                // Now start aggressive focus attempts
                // Post one more broadcast in case the TerminalView mounted slightly later
                NotificationCenter.default.post(
                    name: .focusCommandInput,
                    object: nil
                )
                self.focusCommandInput(in: window, retryCount: 0)
            }
        }
        
        func focusCommandInput(in window: NSWindow, retryCount: Int) {
            guard retryCount < 80 else { return } // Stop after 80 attempts (8 seconds)
            
            // CRITICAL: Ensure window is visible, on screen, and KEY before trying to focus
            // This is what makes the difference between startup (no focus) and clicking back (has focus)
            guard window.isVisible else {
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    self.focusCommandInput(in: window, retryCount: retryCount + 1)
                }
                return
            }
            
            guard let contentView = window.contentView else {
                // Content view not ready, retry
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                    self.focusCommandInput(in: window, retryCount: retryCount + 1)
                }
                return
            }
            
            // Never steal focus from other windows or apps; only proceed when we're active and key
            guard NSApp.isActive else { return }
            guard window.isKeyWindow else { return }
            
            // Recursively find CustomNSTextField or any editable NSTextField
            func findTextField(in view: NSView) -> NSTextField? {
                if let textField = view as? NSTextField, textField.isEditable {
                    // Make sure it's actually in the view hierarchy and ready
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
            
            // Try to find the text field
            guard let textField = findTextField(in: contentView) else {
                // Text field not ready yet - retry with exponential backoff for first few attempts
                let delay = retryCount < 5 ? 50_000_000 : 100_000_000 // nanoseconds
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: UInt64(delay))
                    self.focusCommandInput(in: window, retryCount: retryCount + 1)
                }
                return
            }
            // Ensure the found text field belongs to the same window; otherwise, do not attempt to focus it
            guard textField.window === window else {
                // Retry later; the correct field may not be attached yet
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 100_000_000)
                    self.focusCommandInput(in: window, retryCount: retryCount + 1)
                }
                return
            }
            
            // Found the text field! Set it as initial first responder
            window.initialFirstResponder = textField
            
            // Also post notification as fallback for TerminalView to handle
            // This ensures TerminalView's onReceive handler also gets triggered
            NotificationCenter.default.post(
                name: .focusCommandInput,
                object: nil // TerminalView will handle focus for the current session
            )
            
            // Try to make it first responder - but ensure window stays key
            Task { @MainActor in
                // Small delay to ensure window is fully key
                try? await Task.sleep(nanoseconds: 30_000_000) // 0.03 seconds
                
                // Re-check: if the window lost key status, abort and retry later without stealing focus
                guard window.isKeyWindow else {
                    self.focusCommandInput(in: window, retryCount: retryCount + 1)
                    return
                }
                
                // Now try to make the text field first responder
                let success = window.makeFirstResponder(textField)
                if success {
                    // Success! Also focus the editor
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 10_000_000) // 0.01 seconds
                        if let editor = textField.currentEditor() {
                            window.makeFirstResponder(editor)
                        }
                    }
                } else {
                    // Failed - window might not be key, retry
                    Task { @MainActor in
                        try? await Task.sleep(nanoseconds: 100_000_000) // 0.1 seconds
                        self.focusCommandInput(in: window, retryCount: retryCount + 1)
                    }
                }
            }
        }
    }
}

