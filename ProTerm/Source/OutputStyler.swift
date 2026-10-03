import AppKit
import SwiftUI

/// Applies user output filters and built-in color coding to parsed terminal output.
///
/// Line filters (hide / extract / replace) only touch *complete* lines, so the trailing partial
/// line (the live prompt or an in-progress pagination prompt) is never removed or rewritten.
enum OutputStyler {
    struct Rule {
        let filter: ProductivityTools.OutputFilter
        let regex: NSRegularExpression
    }

    static func compile(_ filters: [ProductivityTools.OutputFilter]) -> [Rule] {
        filters.compactMap { filter in
            guard filter.isEnabled, !filter.pattern.isEmpty else { return nil }
            let pattern = filter.isRegex ? filter.pattern : NSRegularExpression.escapedPattern(for: filter.pattern)
            guard let regex = try? NSRegularExpression(pattern: pattern, options: .caseInsensitive) else { return nil }
            return Rule(filter: filter, regex: regex)
        }
    }

    static func apply(rules: [Rule], colorCode: Bool, to input: AttributedString) -> AttributedString {
        guard !rules.isEmpty || colorCode else { return input }
        var result = input

        let lineRules = rules.filter { [.hide, .extract, .replace].contains($0.filter.action) }
        if !lineRules.isEmpty {
            result = applyLineRules(lineRules, to: result)
        }
        for rule in rules where rule.filter.action == .highlight {
            highlight(rule, in: &result)
        }
        if colorCode {
            applyColorCoding(to: &result)
        }
        return result
    }

    // MARK: - Line rules

    private static func applyLineRules(_ rules: [Rule], to input: AttributedString) -> AttributedString {
        let hide = rules.filter { $0.filter.action == .hide }
        let extract = rules.filter { $0.filter.action == .extract }
        let replace = rules.filter { $0.filter.action == .replace }

        var output = AttributedString()
        var lineStart = input.startIndex
        var index = input.startIndex
        let chars = input.characters

        while index < input.endIndex {
            let next = chars.index(after: index)
            if chars[index].isNewline {
                var line = AttributedString(input[lineStart..<next])
                let text = String(line.characters)
                let keep = !matches(hide, text) && (extract.isEmpty || matches(extract, text))
                if keep {
                    for rule in replace { replaceMatches(rule, in: &line) }
                    output.append(line)
                }
                lineStart = next
            }
            index = next
        }
        if lineStart < input.endIndex {
            output.append(AttributedString(input[lineStart..<input.endIndex]))
        }
        return output
    }

    private static func matches(_ rules: [Rule], _ text: String) -> Bool {
        let range = NSRange(text.startIndex..., in: text)
        return rules.contains { $0.regex.firstMatch(in: text, range: range) != nil }
    }

    private static func replaceMatches(_ rule: Rule, in line: inout AttributedString) {
        let text = String(line.characters)
        let range = NSRange(text.startIndex..., in: text)
        let template = rule.filter.isRegex
            ? (rule.filter.replacement ?? "")
            : NSRegularExpression.escapedTemplate(for: rule.filter.replacement ?? "")
        for match in rule.regex.matches(in: text, range: range).reversed() {
            guard let target = Range(match.range, in: line) else { continue }
            let replacement = rule.regex.replacementString(for: match, in: text, offset: 0, template: template)
            let attributes = line[target].runs.first?.attributes ?? AttributeContainer()
            line.replaceSubrange(target, with: AttributedString(replacement, attributes: attributes))
        }
    }

    // MARK: - Highlight

    private static func highlight(_ rule: Rule, in text: inout AttributedString) {
        let string = String(text.characters)
        let range = NSRange(string.startIndex..., in: string)
        let color = Color(hexString: rule.filter.color) ?? .yellow
        for match in rule.regex.matches(in: string, range: range) where match.range.length > 0 {
            guard let target = Range(match.range, in: text) else { continue }
            text[target].backgroundColor = color.opacity(0.35)
        }
    }

    // MARK: - Built-in color coding

    private static let colorRules: [(NSRegularExpression, Color)] = {
        let specs: [(String, Color)] = [
            (#"\b(error|errors|failed|failure|fatal|exception|denied|panic|traceback)\b"#, Color(nsColor: .systemRed)),
            (#"\b(warning|warnings|warn|deprecated)\b"#, Color(nsColor: .systemOrange)),
            (#"\b(success|succeeded|passed|completed)\b"#, Color(nsColor: .systemGreen))
        ]
        return specs.compactMap { pattern, color in
            (try? NSRegularExpression(pattern: pattern, options: .caseInsensitive)).map { ($0, color) }
        }
    }()

    /// Colors keywords only where the program did not already set a color via ANSI.
    private static func applyColorCoding(to text: inout AttributedString) {
        let string = String(text.characters)
        let range = NSRange(string.startIndex..., in: string)
        for (regex, color) in colorRules {
            for match in regex.matches(in: string, range: range) {
                guard let target = Range(match.range, in: text) else { continue }
                if text[target].runs.allSatisfy({ $0.foregroundColor == nil }) {
                    text[target].foregroundColor = color
                }
            }
        }
    }
}

extension Color {
    /// Parses "#RRGGBB" or "RRGGBB".
    init?(hexString: String) {
        var hex = hexString.trimmingCharacters(in: .whitespaces)
        if hex.hasPrefix("#") { hex.removeFirst() }
        guard hex.count == 6, let value = UInt32(hex, radix: 16) else { return nil }
        self.init(
            red: Double((value >> 16) & 0xFF) / 255,
            green: Double((value >> 8) & 0xFF) / 255,
            blue: Double(value & 0xFF) / 255)
    }
}
