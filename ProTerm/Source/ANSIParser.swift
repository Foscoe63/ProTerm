import SwiftUI
import Foundation
import Combine

/// Parses ANSI escape codes and converts them to SwiftUI Text attributes
struct ANSIParser {
    
    /// Parse ANSI escape codes and return attributed text
    static func parse(_ text: String, baseFont: Font = .custom("Menlo", size: 12)) -> AttributedString {
        let (normalized, _, _) = normalizeControlCharacters(text)
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
                        } else if result.finalChar == "J" {
                            // IGNORE ALL Clear Screen commands (CSI J, CSI 2 J, CSI 3 J)
                            // Forces log-mode behavior for Cisco/legacy compatibility.
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
    
    static func normalizeControlCharacters(_ text: String, pendingCR: Bool = false) -> (normalized: String, isCRPending: Bool, remainder: String) {
        var buffer = String()
        buffer.reserveCapacity(text.count)
        var i = text.startIndex
        var isCRPending = pendingCR
        var lineCursor = 0 // Track cursor position in the current line
        
        while i < text.endIndex {
            let ch = text[i]
            
            if ch == "\r" {
                let nextIndex = text.index(after: i)
                if nextIndex < text.endIndex, text[nextIndex] == "\n" {
                    buffer.append("\n")
                    lineCursor = 0
                    isCRPending = false
                    i = text.index(after: nextIndex)
                    continue
                }
                lineCursor = 0
                isCRPending = true
                i = text.index(after: i)
                continue
            } else if ch == "\n" {
                buffer.append("\n")
                lineCursor = 0
                isCRPending = false
                i = text.index(after: i)
            } else if ch == "\u{001B}" {
                let next = text.index(after: i)
                if next == text.endIndex {
                    // ESC at the very end
                    return (buffer, isCRPending, String(text[i...]))
                }
                
                if text[next] == "[" {
                    if let result = ANSIParser.readCSISequence(in: text, start: next) {
                        let sequence = String(text[i...result.endIndex])
                        i = text.index(after: result.endIndex)
                        
                        if result.finalChar == "m" {
                            // SGR (Color/Style): Pass through to buffer, don't move cursor
                            buffer.append(sequence)
                        } else if result.finalChar == "G" {
                            // CHA: Move to column
                            let col = Int(result.parameters) ?? 1
                            lineCursor = max(0, col - 1)
                        } else if result.finalChar == "K" {
                            // EL: Erase in line
                            let mode = Int(result.parameters) ?? 0
                            handleCSI_K(mode, &buffer, lineCursor)
                        } else if result.finalChar == "H" || result.finalChar == "f" {
                            // CUP/HVP: Move to Row;Col
                            let parts = result.parameters.split(separator: ";")
                            if let rStr = parts.first, let r = Int(rStr) {
                                // Simple row simulation: pad with newlines if jumping down
                                let currentRows = buffer.filter { $0 == "\n" }.count
                                if r - 1 > currentRows {
                                    buffer.append(contentsOf: String(repeating: "\n", count: (r - 1) - currentRows))
                                }
                            }
                            lineCursor = 0
                            if parts.count >= 2 {
                                let cParams = parts[1].trimmingCharacters(in: CharacterSet.letters)
                                if let c = Int(cParams) {
                                    lineCursor = max(0, c - 1)
                                }
                            }
                        }
                        continue
                    } else {
                        // Incomplete CSI sequence at the end of chunk
                        return (buffer, isCRPending, String(text[i...]))
                    }
                }
                // If it's a stand-alone ESC or unknown, skip it
                i = text.index(after: i)
                continue
            } else if ch == "\u{0008}" { // backspace
                lineCursor = max(0, lineCursor - 1)
                i = text.index(after: i)
            } else {
                if isCRPending {
                    // Overwrite logic: if we were at start of line, clear it first for simple log-mode compatibility
                    if lineCursor == 0 { ANSIParser.clearCurrentLine(&buffer) }
                    isCRPending = false
                }
                
                // For a real string-based terminal, we overwrite at lineCursor
                // But for log-mode, we just append IF lineCursor is at end
                appendAtCursor(&buffer, ch, &lineCursor)
                i = text.index(after: i)
            }
        }
        return (buffer, isCRPending, "")
    }

    private static func appendAtCursor(_ buffer: inout String, _ ch: Character, _ cursor: inout Int) {
        let lastNewline = buffer.lastIndex(of: "\n")
        let lineStart = (lastNewline == nil) ? buffer.startIndex : buffer.index(after: lastNewline!)
        _ = buffer[lineStart...]
        
        let targetIdx = indexForVisualColumn(lineStart, cursor, in: buffer)
        
        if targetIdx >= buffer.endIndex {
            if cursor > 0 {
                // Approximate distance check (not perfect due to ANSI, but better than nothing)
                let currentVisualCount = visualLength(of: buffer[lineStart...])
                if cursor > currentVisualCount {
                    buffer.append(contentsOf: String(repeating: " ", count: cursor - currentVisualCount))
                }
            }
            buffer.append(ch)
        } else {
            buffer.replaceSubrange(targetIdx...targetIdx, with: String(ch))
        }
        cursor += 1
    }

    private static func visualLength(of segment: Substring) -> Int {
        var count = 0
        var i = segment.startIndex
        while i < segment.endIndex {
            if segment[i] == "\u{001B}" {
                let next = segment.index(after: i)
                if next < segment.endIndex, segment[next] == "[" {
                    if let result = readCSISequence(in: String(segment), start: next) {
                        i = segment.index(after: result.endIndex)
                        continue
                    }
                }
            }
            count += 1
            i = segment.index(after: i)
        }
        return count
    }

    private static func indexForVisualColumn(_ lineStart: String.Index, _ column: Int, in buffer: String) -> String.Index {
        var pos = 0
        var current = lineStart
        
        while current < buffer.endIndex {
            // First, skip any ANSI sequences at this location
            if buffer[current] == "\u{001B}" {
                let next = buffer.index(after: current)
                if next < buffer.endIndex, buffer[next] == "[" {
                    if let result = readCSISequence(in: buffer, start: next) {
                        current = buffer.index(after: result.endIndex)
                        continue
                    }
                }
            }
            
            // If we've reached the desired visual column, stop
            if pos >= column {
                break
            }
            
            current = buffer.index(after: current)
            pos += 1
        }
        return current
    }

    private static func handleCSI_K(_ mode: Int, _ buffer: inout String, _ cursor: Int) {
        let lastNewline = buffer.lastIndex(of: "\n")
        let lineStart = (lastNewline == nil) ? buffer.startIndex : buffer.index(after: lastNewline!)

        if mode == 0 { // Clear from cursor to end
            let targetIdx = indexForVisualColumn(lineStart, cursor, in: buffer)
            if targetIdx < buffer.endIndex {
                buffer.removeSubrange(targetIdx..<buffer.endIndex)
            }
        } else if mode == 1 { // Clear from start to cursor
            let targetIdx = indexForVisualColumn(lineStart, cursor, in: buffer)
            // Replace visual characters with spaces up to cursor
            // This is complex - for now just leave as is or clear entire line
            buffer.removeSubrange(lineStart..<targetIdx)
            buffer.insert(contentsOf: String(repeating: " ", count: cursor), at: lineStart)
        } else if mode == 2 { // Clear entire line
            buffer.removeSubrange(lineStart..<buffer.endIndex)
        }
    }
    
    private static func clearCurrentLine(_ buffer: inout String) {
        if let lastNewline = buffer.lastIndex(of: "\n") {
            buffer.removeSubrange(buffer.index(after: lastNewline)..<buffer.endIndex)
        } else {
            buffer.removeAll()
        }
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
