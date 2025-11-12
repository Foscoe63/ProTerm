import SwiftUI
import Foundation

/// Advanced syntax highlighter for terminal output with color coding
class TerminalSyntaxHighlighter {
    
    // MARK: - Color Definitions
    struct Colors {
        static let prompt = Color.blue
        static let command = Color.green
        static let error = Color.red
        static let warning = Color.orange
        static let success = Color.green
        static let info = Color.cyan
        static let directory = Color.purple
        static let file = Color.primary
        static let link = Color.blue
        static let number = Color.yellow
        static let string = Color.green
        static let keyword = Color.pink
        static let comment = Color.gray
        static let background = Color.gray.opacity(0.1)
    }
    
    // MARK: - Syntax Highlighting
    static func highlight(_ text: String) -> AttributedString {
        var attributedString = AttributedString(text)
        
        // Apply different highlighting patterns
        attributedString = highlightPrompts(attributedString)
        attributedString = highlightCommands(attributedString)
        attributedString = highlightPaths(attributedString)
        attributedString = highlightErrors(attributedString)
        attributedString = highlightWarnings(attributedString)
        attributedString = highlightSuccess(attributedString)
        attributedString = highlightNumbers(attributedString)
        attributedString = highlightStrings(attributedString)
        attributedString = highlightKeywords(attributedString)
        attributedString = highlightComments(attributedString)
        
        return attributedString
    }
    
    // MARK: - Specific Highlighting Methods
    
    private static func highlightPrompts(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        // Find prompt patterns (user@host path %)
        let promptPattern = #"([a-zA-Z0-9_-]+@[a-zA-Z0-9_-]+\s+[^\s]+\s+%)"#
        if let regex = try? NSRegularExpression(pattern: promptPattern) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.prompt
                result[range].font = .system(.body, design: .monospaced).weight(.semibold)
            }
        }
        
        return result
    }
    
    private static func highlightCommands(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        let commandPattern = #"\b(ls|cd|pwd|mkdir|rmdir|rm|cp|mv|cat|grep|find|chmod|chown|sudo|npm|git|docker|kubectl|aws|terraform|make|cmake|gcc|clang|python|node|java|go|rust|cargo|yarn|brew|apt|yum|dnf|pacman|zypper|port|fink|macports)\b"#
        if let regex = try? NSRegularExpression(pattern: commandPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.command
                result[range].font = .system(.body, design: .monospaced).weight(.medium)
            }
        }
        
        return result
    }
    
    private static func highlightPaths(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        // Highlight directory paths
        let dirPattern = #"([/~][a-zA-Z0-9_./-]+/)"#
        if let regex = try? NSRegularExpression(pattern: dirPattern) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.directory
            }
        }
        
        // Highlight file paths
        let filePattern = #"([/~][a-zA-Z0-9_./-]+\.[a-zA-Z0-9]+)"#
        if let regex = try? NSRegularExpression(pattern: filePattern) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.file
            }
        }
        
        return result
    }
    
    private static func highlightErrors(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        let errorPattern = #"(error|Error|ERROR|failed|Failed|FAILED|exception|Exception|EXCEPTION|fatal|Fatal|FATAL|cannot|Cannot|CANNOT|permission denied|Permission denied|PERMISSION DENIED)"#
        if let regex = try? NSRegularExpression(pattern: errorPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.error
                result[range].font = .system(.body, design: .monospaced).weight(.semibold)
            }
        }
        
        return result
    }
    
    private static func highlightWarnings(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        let warningPattern = #"(warning|Warning|WARNING|warn|Warn|WARN|deprecated|Deprecated|DEPRECATED|obsolete|Obsolete|OBSOLETE)"#
        if let regex = try? NSRegularExpression(pattern: warningPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.warning
                result[range].font = .system(.body, design: .monospaced).weight(.medium)
            }
        }
        
        return result
    }
    
    private static func highlightSuccess(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        let successPattern = #"(success|Success|SUCCESS|completed|Completed|COMPLETED|done|Done|DONE|ok|OK|OKAY|okay)"#
        if let regex = try? NSRegularExpression(pattern: successPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.success
            }
        }
        
        return result
    }
    
    private static func highlightNumbers(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        let numberPattern = #"\b(\d+\.?\d*)\b"#
        if let regex = try? NSRegularExpression(pattern: numberPattern) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.number
            }
        }
        
        return result
    }
    
    private static func highlightStrings(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        let stringPattern = #"(\"[^\"]*\"|'[^']*')"#
        if let regex = try? NSRegularExpression(pattern: stringPattern) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.string
            }
        }
        
        return result
    }
    
    private static func highlightKeywords(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        let keywordPattern = #"\b(if|else|elif|fi|for|while|do|done|case|esac|function|return|break|continue|exit|export|local|readonly|declare|typeset|unset|alias|unalias|set|unset|shift|getopts|eval|exec|trap|wait|jobs|fg|bg|disown|kill|killall|pkill|pgrep|ps|top|htop|df|du|free|uptime|whoami|id|groups|passwd|su|sudo|visudo|chsh|chfn|usermod|useradd|userdel|groupadd|groupdel|groupmod)\b"#
        if let regex = try? NSRegularExpression(pattern: keywordPattern, options: .caseInsensitive) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.keyword
                result[range].font = .system(.body, design: .monospaced).weight(.medium)
            }
        }
        
        return result
    }
    
    private static func highlightComments(_ attributedString: AttributedString) -> AttributedString {
        var result = attributedString
        
        let commentPattern = #"(#.*$)"#
        if let regex = try? NSRegularExpression(pattern: commentPattern, options: .anchorsMatchLines) {
            let matches = regex.matches(in: String(attributedString.characters), options: [], range: NSRange(location: 0, length: attributedString.characters.count))
            
            for match in matches.reversed() {
                let range = Range(match.range, in: attributedString)!
                result[range].foregroundColor = Colors.comment
                result[range].font = .system(.body, design: .monospaced).italic()
            }
        }
        
        return result
    }
}

// MARK: - AttributedString Extension for Rich Text
extension AttributedString {
    static func fromTerminalOutput(_ text: String) -> AttributedString {
        return TerminalSyntaxHighlighter.highlight(text)
    }
}
