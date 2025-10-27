import Foundation
import SwiftUI

/// Handles terminal control sequences and cursor positioning
struct TerminalControls {
    
    /// Process terminal control sequences in text
    static func processControlSequences(_ text: String) -> String {
        var processedText = text
        
        // Handle common control sequences
        processedText = processedText.replacingOccurrences(of: "\u{001B}[2J", with: "") // Clear screen
        processedText = processedText.replacingOccurrences(of: "\u{001B}[H", with: "") // Home cursor
        processedText = processedText.replacingOccurrences(of: "\u{001B}[K", with: "") // Clear line
        processedText = processedText.replacingOccurrences(of: "\u{001B}[0K", with: "") // Clear line from cursor
        processedText = processedText.replacingOccurrences(of: "\u{001B}[1K", with: "") // Clear line to cursor
        processedText = processedText.replacingOccurrences(of: "\u{001B}[2K", with: "") // Clear entire line
        
        // Handle cursor movement sequences (simplified - just remove them)
        processedText = processedText.replacingOccurrences(of: #"\u{001B}\[\d+;\d+H"#, with: "", options: .regularExpression) // Cursor position
        processedText = processedText.replacingOccurrences(of: #"\u{001B}\[\d+A"#, with: "", options: .regularExpression) // Cursor up
        processedText = processedText.replacingOccurrences(of: #"\u{001B}\[\d+B"#, with: "", options: .regularExpression) // Cursor down
        processedText = processedText.replacingOccurrences(of: #"\u{001B}\[\d+C"#, with: "", options: .regularExpression) // Cursor right
        processedText = processedText.replacingOccurrences(of: #"\u{001B}\[\d+D"#, with: "", options: .regularExpression) // Cursor left
        
        // Handle other common sequences
        processedText = processedText.replacingOccurrences(of: "\u{001B}[?25h", with: "") // Show cursor
        processedText = processedText.replacingOccurrences(of: "\u{001B}[?25l", with: "") // Hide cursor
        processedText = processedText.replacingOccurrences(of: "\u{001B}[?7h", with: "") // Enable line wrap
        processedText = processedText.replacingOccurrences(of: "\u{001B}[?7l", with: "") // Disable line wrap
        
        // Handle carriage return and line feed combinations
        processedText = processedText.replacingOccurrences(of: "\r\n", with: "\n") // Normalize line endings
        processedText = processedText.replacingOccurrences(of: "\r", with: "\n") // Convert CR to LF
        
        return processedText
    }
    
    /// Check if text contains control sequences that need special handling
    static func hasControlSequences(_ text: String) -> Bool {
        return text.contains("\u{001B}[") || text.contains("\r")
    }
    
    /// Clean up text for display by removing control sequences
    static func cleanForDisplay(_ text: String) -> String {
        return processControlSequences(text)
    }
}

