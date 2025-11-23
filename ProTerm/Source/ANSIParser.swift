import SwiftUI
import Foundation
import Combine

/// Parses ANSI escape codes and converts them to SwiftUI Text attributes
struct ANSIParser {
    
    /// Parse ANSI escape codes and return attributed text
    static func parse(_ text: String, baseFont: Font = .custom("Menlo", size: 12)) -> AttributedString {
        let normalized = normalizeControlCharacters(text)
        var attributedString = AttributedString()
        var currentAttributes = AttributeContainer()
        currentAttributes.font = baseFont
        var cursor = normalized.startIndex
        var activeLink: URL?
        
        while cursor < normalized.endIndex {
            let scalar = normalized[cursor]
            if scalar == "\u{001B}" {
                let next = normalized.index(after: cursor)
                guard next < normalized.endIndex else { break }
                let indicator = normalized[next]
                switch indicator {
                case "[":
                    if let result = readCSISequence(in: normalized, start: next) {
                        if result.finalChar == "m" {
                            currentAttributes = parseEscapeCode(result.parameters, currentAttributes: currentAttributes, baseFont: baseFont)
                        }
                        cursor = normalized.index(after: result.endIndex)
                    } else {
                        cursor = normalized.endIndex
                    }
                case "]":
                    if let newIndex = readOSCSequence(in: normalized, start: next, activeLink: &activeLink) {
                        cursor = newIndex
                    } else {
                        cursor = normalized.endIndex
                    }
                default:
                    cursor = normalized.index(after: next)
                }
                continue
            }
            
            let segmentStart = cursor
            while cursor < normalized.endIndex, normalized[cursor] != "\u{001B}" {
                cursor = normalized.index(after: cursor)
            }
            var slice = AttributedString(String(normalized[segmentStart..<cursor]), attributes: currentAttributes)
            if let link = activeLink {
                slice.link = link
                slice.underlineStyle = .single
            }
            attributedString.append(slice)
        }
        
        return attributedString
    }
    
    private static func readCSISequence(in text: String, start: String.Index) -> (parameters: String, finalChar: Character, endIndex: String.Index)? {
        var parameters = ""
        var index = text.index(after: start)
        while index < text.endIndex {
            let char = text[index]
            if char.isLetter || char == "~" {
                return (parameters, char, index)
            } else {
                parameters.append(char)
                index = text.index(after: index)
            }
        }
        return nil
    }
    
    private static func readOSCSequence(in text: String, start: String.Index, activeLink: inout URL?) -> String.Index? {
        var payload = ""
        var index = text.index(after: start)
        while index < text.endIndex {
            let char = text[index]
            if char == "\u{0007}" {
                handleOSCCommand(payload, activeLink: &activeLink)
                return text.index(after: index)
            } else if char == "\u{001B}" {
                let lookAhead = text.index(after: index)
                if lookAhead < text.endIndex && text[lookAhead] == "\\" {
                    handleOSCCommand(payload, activeLink: &activeLink)
                    return text.index(after: lookAhead)
                }
            }
            payload.append(char)
            index = text.index(after: index)
        }
        return nil
    }
    
    private static func handleOSCCommand(_ payload: String, activeLink: inout URL?) {
        guard !payload.isEmpty else { return }
        let components = payload.split(separator: ";", omittingEmptySubsequences: false)
        guard let command = components.first else { return }
        if command == "8" {
            // Hyperlink start/end
            if components.count >= 3 {
                let urlToken = components[2]
                if urlToken.isEmpty {
                    activeLink = nil
                } else if let url = URL(string: String(urlToken)) {
                    activeLink = url
                }
            } else if components.count == 2 && components[1].isEmpty {
                activeLink = nil
            }
        }
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
        
        let tokens = code.split(separator: ";")
        var index = 0
        
        while index < tokens.count {
            let token = tokens[index]
            guard let value = Int(token) else {
                index += 1
                continue
            }
            
            switch value {
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
                let fg = attributes.foregroundColor ?? .black
                let bg = attributes.backgroundColor ?? Color.white.opacity(0.2)
                attributes.foregroundColor = bg
                attributes.backgroundColor = fg
            case 8: // Hidden
                attributes.foregroundColor = .clear
            case 9: // Strikethrough
                attributes.strikethroughStyle = .single
            case 21, 22: // Normal intensity
                attributes.font = baseFont
            case 23: // Not italic
                attributes.font = baseFont
            case 24: // Not underline
                attributes.underlineStyle = nil
            case 27: // Exit reverse
                attributes.backgroundColor = nil
                attributes.foregroundColor = nil
            case 29: // Remove strikethrough
                attributes.strikethroughStyle = nil
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
            case 38:
                if index + 1 < tokens.count {
                    let modeToken = tokens[index + 1]
                    if modeToken == "5", index + 2 < tokens.count, let colorIndex = Int(tokens[index + 2]) {
                        attributes.foregroundColor = colorFrom256Index(colorIndex)
                        index += 2
                    } else if modeToken == "2", index + 4 < tokens.count,
                              let r = Int(tokens[index + 2]),
                              let g = Int(tokens[index + 3]),
                              let b = Int(tokens[index + 4]) {
                        attributes.foregroundColor = colorFromTrueColor(r, g, b)
                        index += 4
                    }
                }
            case 48:
                if index + 1 < tokens.count {
                    let modeToken = tokens[index + 1]
                    if modeToken == "5", index + 2 < tokens.count, let colorIndex = Int(tokens[index + 2]) {
                        attributes.backgroundColor = colorFrom256Index(colorIndex)
                        index += 2
                    } else if modeToken == "2", index + 4 < tokens.count,
                              let r = Int(tokens[index + 2]),
                              let g = Int(tokens[index + 3]),
                              let b = Int(tokens[index + 4]) {
                        attributes.backgroundColor = colorFromTrueColor(r, g, b)
                        index += 4
                    }
                }
            case 90...97:
                attributes.foregroundColor = brightColor(for: value - 90)
            case 100...107:
                attributes.backgroundColor = brightColor(for: value - 100)
            default:
                break
            }
            
            index += 1
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
    
    private static func colorFromTrueColor(_ r: Int, _ g: Int, _ b: Int) -> Color {
        Color(red: Double(max(0, min(255, r))) / 255.0,
              green: Double(max(0, min(255, g))) / 255.0,
              blue: Double(max(0, min(255, b))) / 255.0)
    }
    
    private static func brightColor(for index: Int) -> Color {
        let palette: [Color] = [
            Color(red: 0.5, green: 0.5, blue: 0.5),
            Color(red: 1.0, green: 0.4, blue: 0.4),
            Color(red: 0.6, green: 1.0, blue: 0.6),
            Color(red: 1.0, green: 1.0, blue: 0.6),
            Color(red: 0.6, green: 0.8, blue: 1.0),
            Color(red: 1.0, green: 0.6, blue: 1.0),
            Color(red: 0.6, green: 1.0, blue: 1.0),
            Color(red: 1.0, green: 1.0, blue: 1.0)
        ]
        return palette[max(0, min(palette.count - 1, index))]
    }
}
