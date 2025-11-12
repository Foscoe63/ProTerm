import SwiftUI
import AppKit
import Combine

/// Manages keyboard shortcuts for ProTerm
@MainActor
class KeyboardShortcutsManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isEnabled: Bool = true
    @Published var lastAction: Action?
    
    // MARK: - Event Monitor
    nonisolated(unsafe) private var eventMonitor: Any?
    
    // MARK: - Initialization
    override init() {
        super.init()
        setupEventMonitor()
    }
    
    deinit {
        if let monitor = eventMonitor {
            NSEvent.removeMonitor(monitor)
        }
    }
    
    private func setupEventMonitor() {
        eventMonitor = NSEvent.addLocalMonitorForEvents(matching: [.keyDown]) { [weak self] event in
            guard let self = self, self.isEnabled else { return event }
            
            let modifiers = event.modifierFlags
            var eventModifiers: EventModifiers = []
            if modifiers.contains(.command) { eventModifiers.insert(.command) }
            if modifiers.contains(.shift) { eventModifiers.insert(.shift) }
            if modifiers.contains(.option) { eventModifiers.insert(.option) }
            if modifiers.contains(.control) { eventModifiers.insert(.control) }
            
            // Get the key character, handling special cases
            let keyChar: Character?
            if let chars = event.charactersIgnoringModifiers?.lowercased(), !chars.isEmpty {
                keyChar = chars.first
            } else {
                // Handle special keys
                switch event.keyCode {
                case 0: keyChar = "a"
                case 1: keyChar = "s"
                case 2: keyChar = "d"
                case 3: keyChar = "f"
                case 4: keyChar = "h"
                case 5: keyChar = "g"
                case 6: keyChar = "z"
                case 7: keyChar = "x"
                case 8: keyChar = "c"
                case 9: keyChar = "v"
                case 11: keyChar = "b"
                case 12: keyChar = "q"
                case 13: keyChar = "w"
                case 14: keyChar = "e"
                case 15: keyChar = "r"
                case 16: keyChar = "y"
                case 17: keyChar = "t"
                case 31: keyChar = "o"
                case 32: keyChar = "u"
                case 34: keyChar = "i"
                case 35: keyChar = "p"
                case 37: keyChar = "l"
                case 38: keyChar = "j"
                case 40: keyChar = "k"
                case 45: keyChar = "n"
                case 46: keyChar = "m"
                case 18: keyChar = "1"
                case 19: keyChar = "2"
                case 20: keyChar = "3"
                case 21: keyChar = "4"
                case 23: keyChar = "5"
                case 22: keyChar = "6"
                case 26: keyChar = "7"
                case 28: keyChar = "8"
                case 25: keyChar = "9"
                default: keyChar = nil
                }
            }
            
            if let char = keyChar {
                let keyEquivalent = KeyEquivalent(char)
                if self.handleKeyPress(keyEquivalent, modifiers: eventModifiers) {
                    return nil // Consume the event
                }
            }
            
            return event
        }
    }
    
    // MARK: - Shortcut Actions
    enum Action {
        case selectAll
        case quickSearch
        case clearScreen
        case newTab
        case closeTab
        case switchTab(Int)
        case copy
        case paste
        case find
        case replace
        case focusInput
        case commandPalette
    }
    
    // MARK: - Shortcut Definitions
    struct Shortcut {
        let key: KeyEquivalent
        let modifiers: EventModifiers
        let action: Action
        let description: String
    }
    
    static let shortcuts: [Shortcut] = [
        Shortcut(key: KeyEquivalent("a"), modifiers: .command, action: .selectAll, description: "Select All"),
        Shortcut(key: KeyEquivalent("f"), modifiers: .command, action: .quickSearch, description: "Quick Search"),
        Shortcut(key: KeyEquivalent("l"), modifiers: .command, action: .clearScreen, description: "Clear Screen"),
        Shortcut(key: KeyEquivalent("t"), modifiers: .command, action: .newTab, description: "New Tab"),
        Shortcut(key: KeyEquivalent("w"), modifiers: .command, action: .closeTab, description: "Close Tab"),
        Shortcut(key: KeyEquivalent("c"), modifiers: .command, action: .copy, description: "Copy"),
        Shortcut(key: KeyEquivalent("v"), modifiers: .command, action: .paste, description: "Paste"),
        Shortcut(key: KeyEquivalent("f"), modifiers: [.command, .shift], action: .find, description: "Find"),
        Shortcut(key: KeyEquivalent("r"), modifiers: [.command, .shift], action: .replace, description: "Replace"),
        Shortcut(key: KeyEquivalent("i"), modifiers: [.command], action: .focusInput, description: "Focus Command Input"),
        Shortcut(key: KeyEquivalent("p"), modifiers: [.command, .shift], action: .commandPalette, description: "Command Palette"),
        Shortcut(key: KeyEquivalent("p"), modifiers: .command, action: .commandPalette, description: "Command Palette (Cmd+P)"),
        
        // Number keys for tab switching
        Shortcut(key: KeyEquivalent("1"), modifiers: .command, action: .switchTab(0), description: "Switch to Tab 1"),
        Shortcut(key: KeyEquivalent("2"), modifiers: .command, action: .switchTab(1), description: "Switch to Tab 2"),
        Shortcut(key: KeyEquivalent("3"), modifiers: .command, action: .switchTab(2), description: "Switch to Tab 3"),
        Shortcut(key: KeyEquivalent("4"), modifiers: .command, action: .switchTab(3), description: "Switch to Tab 4"),
        Shortcut(key: KeyEquivalent("5"), modifiers: .command, action: .switchTab(4), description: "Switch to Tab 5"),
        Shortcut(key: KeyEquivalent("6"), modifiers: .command, action: .switchTab(5), description: "Switch to Tab 6"),
        Shortcut(key: KeyEquivalent("7"), modifiers: .command, action: .switchTab(6), description: "Switch to Tab 7"),
        Shortcut(key: KeyEquivalent("8"), modifiers: .command, action: .switchTab(7), description: "Switch to Tab 8"),
        Shortcut(key: KeyEquivalent("9"), modifiers: .command, action: .switchTab(8), description: "Switch to Tab 9"),
    ]
    
    // MARK: - Action Handlers
    var onSelectAll: (() -> Void)?
    var onQuickSearch: (() -> Void)?
    var onClearScreen: (() -> Void)?
    var onNewTab: (() -> Void)?
    var onCloseTab: (() -> Void)?
    var onSwitchTab: ((Int) -> Void)?
    var onCopy: (() -> Void)?
    var onPaste: (() -> Void)?
    var onFind: (() -> Void)?
    var onReplace: (() -> Void)?
    var onFocusInput: (() -> Void)?
    var onCommandPalette: (() -> Void)?
    
    // MARK: - Handle Key Press
    func handleKeyPress(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
        // Check if a text field is currently focused - if so, let native copy/paste work
        if modifiers.contains(.command) && (key == KeyEquivalent("v") || key == KeyEquivalent("c")) {
            if let window = NSApplication.shared.keyWindow,
               let firstResponder = window.firstResponder {
                // Check if first responder is a text field or text view
                if firstResponder is NSTextView || firstResponder is NSTextField {
                    // Let native paste/copy behavior work
                    return false
                }
            }
        }
        
        for shortcut in Self.shortcuts {
            if shortcut.key == key && shortcut.modifiers == modifiers {
                handleAction(shortcut.action)
                return true
            }
        }
        return false
    }
    
    private func handleAction(_ action: Action) {
        switch action {
        case .selectAll:
            onSelectAll?()
        case .quickSearch:
            onQuickSearch?()
        case .clearScreen:
            onClearScreen?()
        case .newTab:
            onNewTab?()
        case .closeTab:
            onCloseTab?()
        case .switchTab(let index):
            onSwitchTab?(index)
        case .copy:
            onCopy?()
        case .paste:
            onPaste?()
        case .find:
            onFind?()
        case .replace:
            onReplace?()
        case .focusInput:
            onFocusInput?()
        case .commandPalette:
            onCommandPalette?()
        }
    }
}

// MARK: - SwiftUI View Extension for Keyboard Shortcuts
extension View {
    func keyboardShortcuts(_ manager: KeyboardShortcutsManager) -> some View {
        self
            .onReceive(NotificationCenter.default.publisher(for: .quickSearch)) { _ in
                manager.onQuickSearch?()
            }
            .onReceive(NotificationCenter.default.publisher(for: .pasteToInput)) { _ in
                manager.onPaste?()
            }
    }
}
