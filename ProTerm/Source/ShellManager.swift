import Foundation
import SwiftUI
import Combine

/// Manages shell preferences and settings
@MainActor
class ShellManager: ObservableObject {
    @Published var selectedShell: ShellType = .bash
    
    enum ShellType: String, CaseIterable, Identifiable {
        case bash = "bash"
        case zsh = "zsh"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .bash: return "Bash"
            case .zsh: return "Zsh"
            }
        }
        
        var executablePath: String {
            switch self {
            case .bash: return "/bin/bash"
            case .zsh: return "/bin/zsh"
            }
        }
        
        var description: String {
            switch self {
            case .bash: return "Bourne Again Shell - Default macOS shell"
            case .zsh: return "Z Shell - Modern shell with advanced features"
            }
        }
    }
    
    init() {
        loadPreferences()
    }
    
    private func loadPreferences() {
        if let savedShell = UserDefaults.standard.string(forKey: "selectedShell"),
           let shellType = ShellType(rawValue: savedShell) {
            selectedShell = shellType
        }
    }
    
    func setShell(_ shell: ShellType) {
        selectedShell = shell
        UserDefaults.standard.set(shell.rawValue, forKey: "selectedShell")
    }
}
