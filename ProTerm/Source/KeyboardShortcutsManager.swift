import SwiftUI
import AppKit
import Combine

/// Manages keyboard shortcuts for ProTerm
@MainActor
class KeyboardShortcutsManager: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isEnabled: Bool = true
    @Published var lastAction: Action?
    
    // MARK: - Initialization
    override init() {
        super.init()
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
        Shortcut(key: KeyEquivalent("f"), modifiers: [.command, .shift], action: .find, description: "Find & Replace"),
        Shortcut(key: KeyEquivalent("r"), modifiers: [.command, .shift], action: .replace, description: "Find & Replace"),
        
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
    
    // MARK: - Handle Key Press
    func handleKeyPress(_ key: KeyEquivalent, modifiers: EventModifiers) -> Bool {
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
            .onReceive(NotificationCenter.default.publisher(for: .searchInTerminal)) { _ in
                manager.onFind?()
            }
            .onReceive(NotificationCenter.default.publisher(for: .replaceInTerminal)) { _ in
                manager.onReplace?()
            }
    }
}
