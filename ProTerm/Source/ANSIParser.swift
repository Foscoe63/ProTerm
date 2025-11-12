import SwiftUI
import Foundation
import Combine

/// Parses ANSI escape codes and converts them to SwiftUI Text attributes
struct ANSIParser {
    
    /// Parse ANSI escape codes and return attributed text
    static func parse(_ text: String, baseFont: Font = .custom("Menlo", size: 12)) -> AttributedString {
        // Normalize common terminal control characters (\r, \b, CRLF) before styling
        let normalized = normalizeControlCharacters(text)
        var attributedString = AttributedString()
        var currentAttributes = AttributeContainer()
        // Set the base font (from FontManager)
        currentAttributes.font = baseFont
        
        let components = normalized.components(separatedBy: "\u{001B}[")
        
        for (index, component) in components.enumerated() {
            if index == 0 {
                // First component has no escape code
                if !component.isEmpty {
                    attributedString.append(AttributedString(component, attributes: currentAttributes))
                }
                continue
            }
            
            // Find the end of the escape sequence
            let endIndex = component.firstIndex { $0 == "m" } ?? component.endIndex
            let escapeCode = String(component[..<endIndex])
            let remainingText = endIndex < component.endIndex ? String(component[component.index(after: endIndex)...]) : ""
            
            // Parse the escape code
            currentAttributes = parseEscapeCode(escapeCode, currentAttributes: currentAttributes, baseFont: baseFont)
            
            // Add the remaining text with current attributes
            if !remainingText.isEmpty {
                attributedString.append(AttributedString(remainingText, attributes: currentAttributes))
            }
        }
        
        return attributedString
    }
    
    /// Normalize carriage return (\r), backspace (\b) and CRLF sequences to approximate macOS Terminal rendering
    /// - Behavior:
    ///   - "\r" moves the cursor to the start of the current line; following text overwrites that line
    ///   - "\b" removes the previous character (if any)
    ///   - CRLF ("\r\n") is normalized to a single newline to avoid introducing blank lines
    static func normalizeControlCharacters(_ text: String) -> String {
        var buffer = String()
        buffer.reserveCapacity(text.count)
        var i = text.startIndex
        while i < text.endIndex {
            let ch = text[i]
            if ch == "\r" {
                // If next is \n, treat as newline and consume both
                let nextIndex = text.index(after: i)
                if nextIndex < text.endIndex, text[nextIndex] == "\n" {
                    buffer.append("\n")
                    i = text.index(after: nextIndex)
                    continue
                }
                // Carriage return: erase current line content from its start
                if let lastNewline = buffer.lastIndex(of: "\n") {
                    buffer.removeSubrange(buffer.index(after: lastNewline)..<buffer.endIndex)
                } else {
                    buffer.removeAll(keepingCapacity: true)
                }
                i = text.index(after: i)
                continue
            } else if ch == "\u{0008}" { // backspace
                if !buffer.isEmpty, buffer.last != "\n" {
                    buffer.removeLast()
                }
                i = text.index(after: i)
                continue
            } else {
                buffer.append(ch)
                i = text.index(after: i)
            }
        }
        return buffer
    }
    
    /// Parse a single ANSI escape code
    private static func parseEscapeCode(_ code: String, currentAttributes: AttributeContainer, baseFont: Font = .custom("Menlo", size: 12)) -> AttributeContainer {
        var attributes = currentAttributes
        
        // Split by semicolon to handle multiple codes
        let codes = code.components(separatedBy: ";").compactMap { Int($0) }
        
        for code in codes {
            switch code {
            case 0: // Reset
                attributes = AttributeContainer()
                attributes.font = baseFont
            case 1: // Bold
                // Apply bold to the base font
                attributes.font = baseFont.bold()
            case 2: // Dim
                attributes.foregroundColor = attributes.foregroundColor?.opacity(0.6)
            case 3: // Italic
                // Apply italic to the base font
                attributes.font = baseFont.italic()
            case 4: // Underline
                attributes.underlineStyle = .single
            case 5: // Blink
                // Not supported in SwiftUI
                break
            case 7: // Reverse
                // Not directly supported, would need custom implementation
                break
            case 8: // Hidden
                attributes.foregroundColor = .clear
            case 9: // Strikethrough
                attributes.strikethroughStyle = .single
            case 30: // Black
                attributes.foregroundColor = .black
            case 31: // Red
                attributes.foregroundColor = .red
            case 32: // Green
                attributes.foregroundColor = .green
            case 33: // Yellow
                attributes.foregroundColor = .yellow
            case 34: // Blue
                attributes.foregroundColor = .blue
            case 35: // Magenta
                attributes.foregroundColor = .purple
            case 36: // Cyan
                attributes.foregroundColor = .cyan
            case 37: // White
                attributes.foregroundColor = .white
            case 39: // Default foreground
                attributes.foregroundColor = nil
            case 40: // Black background
                attributes.backgroundColor = .black
            case 41: // Red background
                attributes.backgroundColor = .red
            case 42: // Green background
                attributes.backgroundColor = .green
            case 43: // Yellow background
                attributes.backgroundColor = .yellow
            case 44: // Blue background
                attributes.backgroundColor = .blue
            case 45: // Magenta background
                attributes.backgroundColor = .purple
            case 46: // Cyan background
                attributes.backgroundColor = .cyan
            case 47: // White background
                attributes.backgroundColor = .white
            case 49: // Default background
                attributes.backgroundColor = nil
            default:
                // Handle 256-color codes (38;5;n or 48;5;n)
                if code == 38 && codes.contains(5) {
                    if let colorIndex = codes.firstIndex(of: 5), colorIndex + 1 < codes.count {
                        let colorCode = codes[colorIndex + 1]
                        attributes.foregroundColor = colorFrom256Index(colorCode)
                    }
                } else if code == 48 && codes.contains(5) {
                    if let colorIndex = codes.firstIndex(of: 5), colorIndex + 1 < codes.count {
                        let colorCode = codes[colorIndex + 1]
                        attributes.backgroundColor = colorFrom256Index(colorCode)
                    }
                }
                break
            }
        }
        
        return attributes
    }
    
    /// Convert 256-color index to SwiftUI Color
    private static func colorFrom256Index(_ index: Int) -> Color {
        if index < 16 {
            // Standard 16 colors
            let colors: [Color] = [
                .black, .red, .green, .yellow, .blue, .purple, .cyan, .white,
                .gray, .red, .green, .yellow, .blue, .purple, .cyan, .white
            ]
            return colors[index]
        } else if index < 232 {
            // 6x6x6 color cube
            let cubeIndex = index - 16
            let r = cubeIndex / 36
            let g = (cubeIndex % 36) / 6
            let b = cubeIndex % 6
            return Color(red: Double(r) / 5, green: Double(g) / 5, blue: Double(b) / 5)
        } else {
            // Grayscale
            let gray = (index - 232) * 10 + 8
            return Color(red: Double(gray) / 255, green: Double(gray) / 255, blue: Double(gray) / 255)
        }
    }
}
