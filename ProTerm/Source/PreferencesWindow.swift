import SwiftUI
import AppKit

/// A custom window wrapper for Preferences that is resizable and moveable
@MainActor
class PreferencesWindowController: NSWindowController, NSWindowDelegate {
    static var shared: PreferencesWindowController?
    
    var isPresented: Bool = false {
        didSet {
            if isPresented && !oldValue {
                showWindow()
            } else if !isPresented && oldValue {
                closeWindow()
            }
        }
    }
    
    private var hostingView: NSHostingView<AnyView>?
    private var contentView: AnyView?
    private var onClose: (() -> Void)?
    
    override init(window: NSWindow?) {
        super.init(window: window)
    }
    
    required init?(coder: NSCoder) {
        fatalError("init(coder:) has not been implemented")
    }
    
    func setContent(_ content: AnyView, onClose: @escaping () -> Void) {
        self.contentView = content
        self.onClose = onClose
        if window != nil {
            updateWindowContent()
        }
    }
    
    func showWindow() {
        if window == nil {
            createWindow()
        }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
    }
    
    func closeWindow() {
        window?.close()
    }
    
    private func createWindow() {
        // Ensure we have content before creating window
        guard let content = contentView else {
            // If no content, create a minimal window that will be updated
            let placeholder = AnyView(
                VStack {
                    ProgressView()
                    Text("Loading Preferences...")
                        .padding()
                }
                .frame(width: 800, height: 600)
            )
            let hostingView = NSHostingView(rootView: placeholder)
            hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
            
            let window = NSWindow(
                contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
                styleMask: [.titled, .closable, .miniaturizable, .resizable],
                backing: .buffered,
                defer: false
            )
            
            window.title = "Preferences"
            window.contentView = hostingView
            window.center()
            window.setFrameAutosaveName("PreferencesWindow")
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.isMovableByWindowBackground = true
            window.minSize = NSSize(width: 700, height: 500)
            window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
            
            self.window = window
            self.hostingView = hostingView
            return
        }
        
        // Create hosting view with the actual content
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = NSRect(x: 0, y: 0, width: 800, height: 600)
        
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 800, height: 600),
            styleMask: [.titled, .closable, .miniaturizable, .resizable],
            backing: .buffered,
            defer: false
        )
        
        window.title = "Preferences"
        window.contentView = hostingView
        window.center()
        window.setFrameAutosaveName("PreferencesWindow")
        window.isReleasedWhenClosed = false
        window.delegate = self
        window.isMovableByWindowBackground = true
        window.minSize = NSSize(width: 700, height: 500)
        window.maxSize = NSSize(width: CGFloat.greatestFiniteMagnitude, height: CGFloat.greatestFiniteMagnitude)
        
        self.window = window
        self.hostingView = hostingView
    }
    
    private func updateWindowContent() {
        guard let content = contentView, let window = window else { return }
        let hostingView = NSHostingView(rootView: content)
        hostingView.frame = window.contentView?.bounds ?? NSRect(x: 0, y: 0, width: 800, height: 600)
        window.contentView = hostingView
        self.hostingView = hostingView
    }
    
    func windowWillClose(_ notification: Notification) {
        // Notify the binding that window is closing
        onClose?()
        // Clean up - but don't set shared to nil immediately to avoid crashes
        // Let it be cleaned up when a new window is created
    }
}

/// A view modifier to present preferences in a resizable window
struct PreferencesWindowModifier: ViewModifier {
    @Binding var isPresented: Bool
    let content: () -> AnyView
    
    func body(content: Content) -> some View {
        content
            .onChange(of: isPresented) { oldValue, newValue in
                if newValue {
                    // Create content and controller on main thread
                    // Use a small delay to ensure environment objects are ready
                    DispatchQueue.main.async {
                        // Close existing window if any
                        if let existing = PreferencesWindowController.shared {
                            existing.window?.close()
                            PreferencesWindowController.shared = nil
                        }
                        
                        // Create new controller and set content
                        let controller = PreferencesWindowController(window: nil)
                        // Create content view - this should capture environment objects from the closure
                        let contentView = self.content()
                        controller.setContent(contentView) {
                            // Update binding when window closes
                            DispatchQueue.main.async {
                                isPresented = false
                            }
                        }
                        // Show window after content is set
                        controller.isPresented = true
                        PreferencesWindowController.shared = controller
                    }
                } else {
                    // Only close if window exists and is actually presented
                    DispatchQueue.main.async {
                        if let controller = PreferencesWindowController.shared, controller.isPresented {
                            controller.closeWindow()
                        }
                    }
                }
            }
            .onAppear {
                if isPresented {
                    DispatchQueue.main.async {
                        // Close existing window if any
                        if let existing = PreferencesWindowController.shared {
                            existing.window?.close()
                            PreferencesWindowController.shared = nil
                        }
                        
                        // Create new controller and set content
                        let controller = PreferencesWindowController(window: nil)
                        // Create content view - this should capture environment objects from the closure
                        let contentView = self.content()
                        controller.setContent(contentView) {
                            // Update binding when window closes
                            DispatchQueue.main.async {
                                isPresented = false
                            }
                        }
                        // Show window after content is set
                        controller.isPresented = true
                        PreferencesWindowController.shared = controller
                    }
                }
            }
    }
}

extension View {
    func preferencesWindow(isPresented: Binding<Bool>, @ViewBuilder content: @escaping () -> some View) -> some View {
        modifier(PreferencesWindowModifier(isPresented: isPresented, content: { AnyView(content()) }))
    }
}

