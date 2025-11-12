import SwiftUI
import AppKit
import Combine

/// Advanced text selection system for terminal output
@MainActor
class AdvancedTextSelection: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isEnabled: Bool = true
    @Published var lastSelectionType: SelectionType?
    
    // MARK: - Initialization
    override init() {
        super.init()
    }
    
    // MARK: - Selection Types
    enum SelectionType {
        case word
        case line
        case paragraph
        case all
        case column
        case smart
    }
    
    // MARK: - Selection State
    @Published var selectedText: String = ""
    @Published var selectionRange: NSRange = NSRange(location: 0, length: 0)
    @Published var isSelecting: Bool = false
    @Published var selectionType: SelectionType = .smart
    
    // MARK: - Smart Selection Rules
    private let smartSelectionPatterns = [
        // URLs
        #"https?://[^\s]+"#,
        // Email addresses
        #"[a-zA-Z0-9._%+-]+@[a-zA-Z0-9.-]+\.[a-zA-Z]{2,}"#,
        // File paths
        #"[~/][a-zA-Z0-9_./-]+"#,
        // Git hashes
        #"[a-f0-9]{7,40}"#,
        // IP addresses
        #"\b(?:[0-9]{1,3}\.){3}[0-9]{1,3}\b"#,
        // Port numbers
        #":\d{1,5}"#,
        // JSON keys
        #""[^"]+"\s*:"#,
        // Command arguments
        #"--[a-zA-Z0-9-]+"#,
        #"-[a-zA-Z]"#
    ]
    
    // MARK: - Selection Methods
    
    /// Select word at cursor position
    func selectWord(at position: Int, in text: String) -> NSRange {
        let words = text.components(separatedBy: .whitespacesAndNewlines)
        var currentPos = 0
        
        for word in words {
            if currentPos + word.count >= position {
                let start = currentPos
                let end = currentPos + word.count
                return NSRange(location: start, length: end - start)
            }
            currentPos += word.count + 1 // +1 for separator
        }
        
        return NSRange(location: position, length: 0)
    }
    
    /// Select line at cursor position
    func selectLine(at position: Int, in text: String) -> NSRange {
        let lines = text.components(separatedBy: .newlines)
        var currentPos = 0
        
        for line in lines {
            if currentPos + line.count >= position {
                let start = currentPos
                let end = currentPos + line.count
                return NSRange(location: start, length: end - start)
            }
            currentPos += line.count + 1 // +1 for newline
        }
        
        return NSRange(location: position, length: 0)
    }
    
    /// Select paragraph at cursor position
    func selectParagraph(at position: Int, in text: String) -> NSRange {
        let paragraphs = text.components(separatedBy: "\n\n")
        var currentPos = 0
        
        for paragraph in paragraphs {
            if currentPos + paragraph.count >= position {
                let start = currentPos
                let end = currentPos + paragraph.count
                return NSRange(location: start, length: end - start)
            }
            currentPos += paragraph.count + 2 // +2 for double newline
        }
        
        return NSRange(location: position, length: 0)
    }
    
    /// Select all text
    func selectAll(in text: String) -> NSRange {
        return NSRange(location: 0, length: text.count)
    }
    
    /// Smart selection - intelligently select based on content
    func smartSelect(at position: Int, in text: String) -> NSRange {
        // Try each smart pattern
        for pattern in smartSelectionPatterns {
            if let regex = try? NSRegularExpression(pattern: pattern) {
                let matches = regex.matches(in: text, options: [], range: NSRange(location: 0, length: text.count))
                
                for match in matches {
                    if NSLocationInRange(position, match.range) {
                        return match.range
                    }
                }
            }
        }
        
        // Fallback to word selection
        return selectWord(at: position, in: text)
    }
    
    /// Column selection (block selection)
    func selectColumn(from startPosition: Int, to endPosition: Int, in text: String) -> NSRange {
        let lines = text.components(separatedBy: .newlines)
        var result = ""
        var startLine = 0
        var endLine = 0
        var startCol = 0
        var endCol = 0
        
        // Find start and end lines
        var currentPos = 0
        for (index, line) in lines.enumerated() {
            if currentPos <= startPosition && startPosition < currentPos + line.count {
                startLine = index
                startCol = startPosition - currentPos
            }
            if currentPos <= endPosition && endPosition < currentPos + line.count {
                endLine = index
                endCol = endPosition - currentPos
            }
            currentPos += line.count + 1
        }
        
        // Build column selection
        for i in startLine...endLine {
            if i < lines.count {
                let line = lines[i]
                let start = min(startCol, line.count)
                let end = min(endCol, line.count)
                
                if start < end {
                    let substring = String(line[line.index(line.startIndex, offsetBy: start)..<line.index(line.startIndex, offsetBy: end)])
                    result += substring
                    if i < endLine {
                        result += "\n"
                    }
                }
            }
        }
        
        return NSRange(location: startPosition, length: result.count)
    }
    
    /// Update selection based on type
    func updateSelection(type: SelectionType, at position: Int, in text: String) {
        selectionType = type
        
        switch type {
        case .word:
            selectionRange = selectWord(at: position, in: text)
        case .line:
            selectionRange = selectLine(at: position, in: text)
        case .paragraph:
            selectionRange = selectParagraph(at: position, in: text)
        case .all:
            selectionRange = selectAll(in: text)
        case .smart:
            selectionRange = smartSelect(at: position, in: text)
        case .column:
            // Column selection requires start and end positions
            selectionRange = NSRange(location: position, length: 0)
        }
        
        if selectionRange.length > 0 {
            let startIndex = text.index(text.startIndex, offsetBy: selectionRange.location)
            let endIndex = text.index(startIndex, offsetBy: selectionRange.length)
            selectedText = String(text[startIndex..<endIndex])
        } else {
            selectedText = ""
        }
    }
    
    /// Clear selection
    func clearSelection() {
        selectedText = ""
        selectionRange = NSRange(location: 0, length: 0)
        isSelecting = false
    }
    
    /// Copy selected text to clipboard
    func copySelection() {
        if !selectedText.isEmpty {
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(selectedText, forType: .string)
        }
    }
}

// MARK: - SwiftUI View Extension for Advanced Selection
extension View {
    func advancedTextSelection(_ selection: AdvancedTextSelection) -> some View {
        self
            .onTapGesture(count: 1) { location in
                // Single click - word selection
                selection.updateSelection(type: .word, at: 0, in: "") // Placeholder
            }
            .onTapGesture(count: 2) { location in
                // Double click - smart selection
                selection.updateSelection(type: .smart, at: 0, in: "") // Placeholder
            }
            .onTapGesture(count: 3) { location in
                // Triple click - line selection
                selection.updateSelection(type: .line, at: 0, in: "") // Placeholder
            }
            .gesture(
                DragGesture()
                    .onChanged { value in
                        // Drag selection
                        selection.isSelecting = true
                    }
                    .onEnded { value in
                        // End drag selection
                        selection.isSelecting = false
                    }
            )
    }
}
