import SwiftUI
import Foundation

/// Parses ANSI escape codes and converts them to SwiftUI Text attributes
struct ANSIParser {
    
    /// Parse ANSI escape codes and return attributed text
    static func parse(_ text: String) -> AttributedString {
        var attributedString = AttributedString()
        var currentAttributes = AttributeContainer()
        
        let components = text.components(separatedBy: "\u{001B}[")
        
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
            let remainingText = String(component[component.index(after: endIndex)...])
            
            // Parse the escape code
            currentAttributes = parseEscapeCode(escapeCode, currentAttributes: currentAttributes)
            
            // Add the remaining text with current attributes
            if !remainingText.isEmpty {
                attributedString.append(AttributedString(remainingText, attributes: currentAttributes))
            }
        }
        
        return attributedString
    }
    
    /// Parse a single ANSI escape code
    private static func parseEscapeCode(_ code: String, currentAttributes: AttributeContainer) -> AttributeContainer {
        var attributes = currentAttributes
        
        // Split by semicolon to handle multiple codes
        let codes = code.components(separatedBy: ";").compactMap { Int($0) }
        
        for code in codes {
            switch code {
            case 0: // Reset
                attributes = AttributeContainer()
            case 1: // Bold
                attributes.font = .system(.body, design: .monospaced).bold()
            case 2: // Dim
                attributes.foregroundColor = attributes.foregroundColor?.opacity(0.6)
            case 3: // Italic
                attributes.font = .system(.body, design: .monospaced).italic()
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
