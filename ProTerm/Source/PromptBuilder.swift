import Foundation

/// Builds the terminal prompt string from basic context. This is deliberately
/// minimal and independent; owners can extend with git or other integrations.
struct PromptBuilder {
    struct Context {
        var user: String?
        var host: String?
        var cwd: String?
        var promptSymbol: String = "$"
    }

    func build(_ ctx: Context) -> String {
        let user = ctx.user ?? NSUserName()
        let host = ctx.host ?? Host.current().localizedName ?? "localhost"
        let dir = ctx.cwd.map { URL(fileURLWithPath: $0).lastPathComponent } ?? "~"
        return "\(user)@\(host) \(dir) \(ctx.promptSymbol) "
    }

    /// Shells may redraw the prompt with `\r` without erasing prior bytes in our log buffer.
    /// Keep only the last prompt occurrence on the trailing line.
    static func collapseRepeatedPrompts(in text: String) -> String {
        guard let lastNewline = text.lastIndex(of: "\n") else {
            return collapseRepeatedPrompts(onLine: text)
        }
        let head = text[..<lastNewline]
        let tailStart = text.index(after: lastNewline)
        let tail = String(text[tailStart...])
        return head + "\n" + collapseRepeatedPrompts(onLine: tail)
    }

    static func collapseRepeatedPrompts(onLine line: String) -> String {
        guard !line.isEmpty else { return line }
        guard let regex = promptTokenRegex else { return line }

        let visible = visibleTerminalText(line)
        let nsLine = visible as NSString
        let fullRange = NSRange(location: 0, length: nsLine.length)
        let matches = regex.matches(in: visible, range: fullRange)

        // `\r` stacking can leave many prompts then command output on one line (`…% spplications…`).
        if let last = matches.last, last.range.upperBound < nsLine.length {
            let tail = nsLine.substring(from: last.range.upperBound)
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !tail.isEmpty, !isShellPromptLine(tail), !isPromptPaddingLine(tail) {
                return tail
            }
        }

        guard matches.count > 1, let last = matches.last else {
            if matches.count == 1, let only = matches.first, only.range.location > 0 {
                let tail = nsLine.substring(from: only.range.upperBound)
                    .trimmingCharacters(in: .whitespacesAndNewlines)
                if !tail.isEmpty, !isShellPromptLine(tail), !isPromptPaddingLine(tail) {
                    return tail
                }
                return extractPromptSuffix(from: line, visible: visible, match: only)
            }
            return line
        }
        let tailAfterLast = nsLine.substring(from: last.range.upperBound)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if !tailAfterLast.isEmpty {
            return tailAfterLast
        }
        return extractPromptSuffix(from: line, visible: visible, match: last)
    }

    /// Map a match in visible text back to the original line (keeps trailing ANSI/spaces).
    private static func extractPromptSuffix(
        from line: String,
        visible: String,
        match: NSTextCheckingResult
    ) -> String {
        let nsVisible = visible as NSString
        let promptVisible = nsVisible.substring(from: match.range.location)
        if let range = line.range(of: promptVisible, options: .backwards) {
            return String(line[range.lowerBound...])
        }
        return promptVisible
    }

    /// Collapse stacked prompts on every line (zsh `\r` redraws often leave one line per redraw).
    static func collapseRepeatedPromptsInAllLines(_ text: String) -> String {
        guard text.contains("\n") else {
            return collapseRepeatedPrompts(onLine: text)
        }
        let hadTrailingNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var rebuilt = lines.map { collapseRepeatedPrompts(onLine: String($0)) }.joined(separator: "\n")
        if hadTrailingNewline, !rebuilt.hasSuffix("\n") {
            rebuilt.append("\n")
        }
        return rebuilt
    }

    /// Terminal.app shows raw PTY output without special prompt filtering.
    /// This simplified version only removes empty lines and doesn't filter prompts.
    /// Use this for Terminal.app-compatible behavior.
    static func terminalAppStyleScrollback(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let hadTrailingNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [String] = []
        for line in lines {
            let collapsed = collapseRepeatedPrompts(onLine: String(line))
            let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
            // Only skip truly empty lines, keep everything else including prompts
            if trimmed.isEmpty { continue }
            kept.append(collapsed)
        }
        var rebuilt = kept.joined(separator: "\n")
        if hadTrailingNewline, !kept.isEmpty || text.trimmingCharacters(in: .newlines).isEmpty {
            rebuilt.append("\n")
        }
        return rebuilt
    }
    
    /// Original prompt-only line filtering for users who prefer the ProTerm-style filtering
    static func scrollbackRemovingPromptOnlyLines(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        let hadTrailingNewline = text.hasSuffix("\n")
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        var kept: [String] = []
        for line in lines {
            let collapsed = collapseRepeatedPrompts(onLine: String(line))
            let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if isShellPromptLine(trimmed) { continue }
            if isPromptPaddingLine(trimmed) { continue }
            kept.append(collapsed)
        }
        var rebuilt = kept.joined(separator: "\n")
        if hadTrailingNewline, !kept.isEmpty || text.trimmingCharacters(in: .newlines).isEmpty {
            rebuilt.append("\n")
        }
        return rebuilt
    }

    /// zsh pads the row with `%` before redrawing the prompt.
    static func isPromptPaddingLine(_ line: String) -> Bool {
        let trimmed = visibleTerminalText(line).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0 == "%" || $0 == " " }
    }

    /// Whole PTY chunk is zsh row-clear noise (do not append to scrollback).
    static func isPromptPaddingOnlyChunk(_ chunk: String) -> Bool {
        let trimmed = visibleTerminalText(chunk).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return false }
        return trimmed.allSatisfy { $0 == "%" || $0 == " " }
    }

    /// Line count for scrollback display (matches `LineNumbersView` / command-input gutter).
    static func visibleLineCount(in text: String) -> Int {
        guard !text.isEmpty else { return 0 }
        let normalized = text.replacingOccurrences(of: "\r\n", with: "\n")
        let segments = normalized.components(separatedBy: "\n")
        if normalized.hasSuffix("\n") {
            return max(0, segments.count - 1)
        }
        return segments.count
    }

    /// Prevent stacked blank rows from duplicate PTY newline echoes.
    static func capTrailingNewlines(_ text: String, maxTrailing: Int = 2) -> String {
        guard maxTrailing >= 0 else { return text }
        var newlineCount = 0
        var base = text
        while base.hasSuffix("\n") {
            newlineCount += 1
            base.removeLast()
        }
        let keep = min(newlineCount, maxTrailing)
        return base + String(repeating: "\n", count: keep)
    }

    /// Chunk is only line breaks / whitespace (shell newline echo).
    static func isNewlineOnlyChunk(_ chunk: String) -> Bool {
        guard !chunk.isEmpty else { return false }
        return chunk.trimmingCharacters(in: .whitespaces).allSatisfy { $0 == "\n" || $0 == "\r" }
    }

    /// PTY chunk is only a PS1 redraw (after `\r`), not command output.
    static func isShellPromptOnlyChunk(_ chunk: String) -> Bool {
        if isLoginShellPromptNoiseChunk(chunk) {
            return true
        }
        let peeled = splitTrailingPromptFromChunk(chunk)
        guard peeled.scrollback.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
            return false
        }
        return !peeled.prompt.isEmpty
    }

    /// Every non-empty line in the chunk is a PS1 redraw or zsh `%` padding (WINCH / startup noise).
    static func isLoginShellPromptNoiseChunk(_ chunk: String) -> Bool {
        let cleaned = stripIncompleteCSITail(stripBracketedPasteModeSequences(chunk))
        guard !cleaned.isEmpty else { return false }
        let normalized = cleaned
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        var sawContent = false
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false) {
            let collapsed = collapseRepeatedPrompts(onLine: String(line))
            let trimmed = stripBracketedPasteModeSequences(visibleTerminalText(collapsed))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            sawContent = true
            if !isShellPromptLine(trimmed), !isPromptPaddingLine(trimmed) {
                return false
            }
        }
        return sawContent
    }

    /// Last PS1 in a chunk (for inline prompt display).
    static func lastShellPrompt(in chunk: String) -> String {
        let cleaned = stripIncompleteCSITail(stripBracketedPasteModeSequences(chunk))
        guard !cleaned.isEmpty else { return "" }
        let normalized = cleaned
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        for line in normalized.split(separator: "\n", omittingEmptySubsequences: false).reversed() {
            let collapsed = collapseRepeatedPrompts(onLine: String(line))
            let trimmed = promptDetectionLine(collapsed)
            if isShellPromptLine(trimmed) {
                return normalizedPromptLine(trimmed)
            }
            if !trimmed.isEmpty, !isPromptPaddingLine(trimmed) {
                break
            }
        }
        return ""
    }

    /// Remove PS1 / padding rows from the end of scrollback only (never touches command output above).
    static func stripTrailingPromptOnlyLines(_ text: String, matchingPrompt: String = "") -> String {
        guard !text.isEmpty else { return text }
        let hadTrailingNewline = text.hasSuffix("\n")
        let inlinePrompt = normalizedPromptLine(matchingPrompt)
        var lines = text.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while let last = lines.last {
            let collapsed = collapseRepeatedPrompts(onLine: last)
            let trimmed = stripBracketedPasteModeSequences(visibleTerminalText(collapsed))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty {
                lines.removeLast()
                continue
            }
            if isShellPromptLine(trimmed) || isPromptPaddingLine(trimmed) {
                lines.removeLast()
                continue
            }
            if !inlinePrompt.isEmpty, normalizedPromptLine(trimmed) == inlinePrompt {
                lines.removeLast()
                continue
            }
            break
        }
        var rebuilt = lines.joined(separator: "\n")
        if hadTrailingNewline, !rebuilt.isEmpty {
            rebuilt.append("\n")
        }
        return rebuilt
    }

    /// Normalized PS1 for inline display (no ANSI / bracketed-paste mode toggles).
    static func normalizedPromptLine(_ line: String) -> String {
        let visible = stripBracketedPasteModeSequences(visibleTerminalText(line))
        return collapseRepeatedPrompts(onLine: visible).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split scrollback from the active PS1 on the last line only (no full-buffer compaction).
    static func splitTrailingPromptFromChunk(_ text: String) -> (scrollback: String, prompt: String) {
        let cleaned = stripIncompleteCSITail(stripBracketedPasteModeSequences(text))
        guard !cleaned.isEmpty else { return ("", "") }

        guard let lastNewline = cleaned.lastIndex(of: "\n") else {
            let line = promptDetectionLine(cleaned)
            if isShellPromptLine(line) {
                return ("", normalizedPromptLine(line))
            }
            if isPromptPaddingLine(line) {
                return ("", "")
            }
            return (loginShellScrollbackToAppend(from: cleaned), "")
        }

        var head = String(cleaned[..<lastNewline])
        let tail = promptDetectionLine(String(cleaned[cleaned.index(after: lastNewline)...]))

        // `prompt\n` — tail is empty but the prompt is the last line of head.
        if tail.isEmpty, !head.isEmpty {
            if let prevNewline = head.lastIndex(of: "\n") {
                let lastLine = promptDetectionLine(String(head[head.index(after: prevNewline)...]))
                if isShellPromptLine(lastLine) {
                    head = String(head[..<prevNewline])
                    if !head.isEmpty, !head.hasSuffix("\n") { head += "\n" }
                    return (loginShellScrollbackToAppend(from: head), normalizedPromptLine(lastLine))
                }
                if isPromptPaddingLine(lastLine) {
                    head = String(head[..<prevNewline])
                    if !head.isEmpty, !head.hasSuffix("\n") { head += "\n" }
                    return (loginShellScrollbackToAppend(from: head), "")
                }
            } else {
                let onlyLine = promptDetectionLine(head)
                if isShellPromptLine(onlyLine) {
                    return ("", normalizedPromptLine(onlyLine))
                }
                if isPromptPaddingLine(onlyLine) {
                    return ("", "")
                }
            }
            return (loginShellScrollbackToAppend(from: head), "")
        }

        if isShellPromptLine(tail) {
            if !head.isEmpty, !head.hasSuffix("\n") { head += "\n" }
            return (loginShellScrollbackToAppend(from: head), normalizedPromptLine(tail))
        }

        if isPromptPaddingLine(tail) {
            if !head.isEmpty, !head.hasSuffix("\n") { head += "\n" }
            return (loginShellScrollbackToAppend(from: head), "")
        }

        return (loginShellScrollbackToAppend(from: cleaned), "")
    }

    /// Split scrollback from the active PS1. Only removes the last line when it is a prompt/padding row.
    static func peelTrailingPrompt(from text: String) -> (scrollback: String, prompt: String) {
        splitTrailingPromptFromChunk(text)
    }

    /// Lines to append from a new login-shell chunk — skip prompt rows only, never collapse command output.
    static func loginShellScrollbackToAppend(from chunk: String) -> String {
        let normalized = chunk.replacingOccurrences(of: "\r\n", with: "\n")
        let cleaned = stripIncompleteCSITail(stripBracketedPasteModeSequences(normalized))
        guard !cleaned.isEmpty else { return "" }

        let hadTrailingNewline = cleaned.hasSuffix("\n")
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        for line in lines {
            let normalizedLine = collapseRepeatedPrompts(onLine: line)
            let trimmed = stripBracketedPasteModeSequences(visibleTerminalText(normalizedLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if isPromptPaddingLine(trimmed) { continue }
            if isShellPromptLine(trimmed) { continue }
            kept.append(normalizedLine)
        }
        var rebuilt = kept.joined(separator: "\n")
        if hadTrailingNewline, !rebuilt.isEmpty {
            rebuilt.append("\n")
        }
        return rebuilt
    }

    /// Bracketed-paste mode toggles (zsh echoes these beside the prompt).
    static func stripBracketedPasteModeSequences(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        var s = text
        if let regex = bracketedPasteCSIRemoveRegex {
            let ns = s as NSString
            s = regex.stringByReplacingMatches(
                in: s,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }
        s = s.replacingOccurrences(of: "\u{0007}", with: "")
        if let regex = bracketedPasteVisibleRemnantRegex {
            let ns = s as NSString
            s = regex.stringByReplacingMatches(
                in: s,
                range: NSRange(location: 0, length: ns.length),
                withTemplate: ""
            )
        }
        return s
    }

    /// PTY chunk is only bracketed-paste mode on/off noise (do not append to scrollback).
    static func isBracketedPasteModeOnlyChunk(_ chunk: String) -> Bool {
        let stripped = stripBracketedPasteModeSequences(visibleTerminalText(chunk))
        return stripped.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// Drop a trailing incomplete CSI (e.g. `\e[?` before `2004h` arrives in the next read).
    static func stripIncompleteCSITail(_ text: String) -> String {
        guard !text.isEmpty else { return text }
        guard let regex = incompleteCSITailRegex else { return text }
        let ns = text as NSString
        return regex.stringByReplacingMatches(
            in: text,
            range: NSRange(location: 0, length: ns.length),
            withTemplate: ""
        )
    }

    /// Lines to append from a new PTY chunk only — never re-filter existing scrollback.
    static func appendableScrollbackLines(from chunk: String) -> String {
        let normalized = chunk
            .replacingOccurrences(of: "\r\n", with: "\n")
            .replacingOccurrences(of: "\r", with: "\n")
        let cleaned = stripIncompleteCSITail(stripBracketedPasteModeSequences(normalized))
        guard !cleaned.isEmpty else { return "" }

        let hadTrailingNewline = cleaned.hasSuffix("\n")
        let lines = cleaned.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []
        for line in lines {
            let normalizedLine = collapseRepeatedPrompts(onLine: line)
            let trimmed = stripBracketedPasteModeSequences(visibleTerminalText(normalizedLine))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if isPromptPaddingLine(trimmed) { continue }
            if isShellPromptLine(trimmed) { continue }
            kept.append(normalizedLine)
        }
        var rebuilt = kept.joined(separator: "\n")
        if hadTrailingNewline, !rebuilt.isEmpty {
            rebuilt.append("\n")
        }
        return rebuilt
    }

    /// Remove shell prompt text from PTY output. ProTerm renders the prompt inline beside the field.
    static func stripTrailingShellPrompt(from text: String) -> String {
        guard !text.isEmpty else { return text }

        if let lastNewline = text.lastIndex(of: "\n") {
            let headEnd = lastNewline
            let head = String(text[..<headEnd])
            var tail = String(text[text.index(after: lastNewline)...])
            tail = collapseRepeatedPrompts(onLine: tail)

            if isShellPromptLine(tail) {
                return head.hasSuffix("\n") ? head : head + "\n"
            }

            let strippedTail = stripShellPromptSuffix(from: tail)
            if strippedTail != tail {
                if strippedTail.isEmpty {
                    return head.hasSuffix("\n") ? head : head + "\n"
                }
                return head + "\n" + strippedTail
            }
            return text
        }

        let collapsed = collapseRepeatedPrompts(onLine: text)
        if isShellPromptLine(collapsed) { return "" }
        return stripShellPromptSuffix(from: collapsed)
    }

    /// Visible text with CSI/OSC sequences removed (for prompt detection only).
    static func visibleTerminalText(_ text: String) -> String {
        guard !text.isEmpty, let regex = ansiStripRegex else { return text }
        let ns = text as NSString
        let range = NSRange(location: 0, length: ns.length)
        return regex.stringByReplacingMatches(in: text, range: range, withTemplate: "")
    }

    /// Line text used for PS1 detection — strips ANSI, bracketed-paste toggles, and trailing partial CSI.
    static func promptDetectionLine(_ text: String) -> String {
        stripIncompleteCSITail(
            stripBracketedPasteModeSequences(visibleTerminalText(text))
        ).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func isShellPromptLine(_ line: String) -> Bool {
        let trimmed = promptDetectionLine(line)
        guard !trimmed.isEmpty, let regex = shellPromptLineRegex else { return false }
        let ns = trimmed as NSString
        guard let match = regex.firstMatch(in: trimmed, range: NSRange(location: 0, length: ns.length)) else {
            return false
        }
        return match.range.location == 0 && match.range.length >= ns.length - 1
    }

    static func stripShellPromptSuffix(from line: String) -> String {
        guard !line.isEmpty else { return line }
        let collapsed = collapseRepeatedPrompts(onLine: line)
        let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
        if isShellPromptLine(trimmed) { return "" }
        guard let regex = shellPromptLineRegex else { return collapsed }
        let ns = collapsed as NSString
        guard let match = regex.firstMatch(in: collapsed, range: NSRange(location: 0, length: ns.length)) else {
            return collapsed
        }
        if match.range.location > 0 {
            let prefix = ns.substring(to: match.range.location)
            return prefix.trimmingCharacters(in: .whitespaces)
        }
        return collapsed
    }

    /// Host must contain a letter so `ls -la` lines like `drwxr-xr-x@` are not treated as prompts.
    private static let shellHostPattern = "[A-Za-z0-9._-]*[A-Za-z][A-Za-z0-9._-]*"

    /// Matches zsh-style `user@host path %` (host segment is non-greedy so stacked `\r` redraws collapse).
    private static let shellPromptLineRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"^(?:[A-Za-z0-9._-]+@(?:#shellHostPattern#) \S+(?:\s+\[[^\]]+\])?|[A-Za-z0-9._-]+:\S+(?:\s+\[[^\]]+\])?\s+[A-Za-z0-9._-]+|[A-Za-z0-9._-]+@(?:#shellHostPattern#):\S+(?:\s+\[[^\]]+\])?)\s?[%#$]\s?$"#
                .replacingOccurrences(of: "#shellHostPattern#", with: shellHostPattern),
            options: []
        )
    }()

    private static let promptTokenRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?:[A-Za-z0-9._-]+@(?:#shellHostPattern#) \S+(?:\s+\[[^\]]+\])?|[A-Za-z0-9._-]+:\S+(?:\s+\[[^\]]+\])?\s+[A-Za-z0-9._-]+|[A-Za-z0-9._-]+@(?:#shellHostPattern#):\S+(?:\s+\[[^\]]+\])?)\s?[%#$]\s?"#
                .replacingOccurrences(of: "#shellHostPattern#", with: shellHostPattern),
            options: []
        )
    }()

    /// Collapse stacked PS1 lines in scrollback; prompts live inline only (`shellPromptLine`).
    static func compactLoginShellScrollback(_ text: String, shellPromptLine: inout String) -> String {
        let collapsed = collapseRepeatedPromptsInAllLines(text)
        guard !collapsed.isEmpty else { return "" }

        let hadTrailingNewline = collapsed.hasSuffix("\n")
        let lines = collapsed.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        var kept: [String] = []

        for line in lines {
            let normalized = collapseRepeatedPrompts(onLine: line)
            let trimmed = stripBracketedPasteModeSequences(visibleTerminalText(normalized))
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty { continue }
            if isPromptPaddingLine(trimmed) { continue }
            if isShellPromptLine(trimmed) {
                shellPromptLine = normalizedPromptLine(normalized)
                continue
            }
            kept.append(normalized)
        }

        var rebuilt = kept.joined(separator: "\n")
        if hadTrailingNewline, !rebuilt.isEmpty {
            rebuilt.append("\n")
        }
        return rebuilt
    }

    private static let ansiStripRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"\u{001B}(?:\[[0-?]*[ -/]*[@-~]|\][^\u{0007}\u{001B}]*(?:\u{0007}|\u{001B}\\))"#,
            options: []
        )
    }()

    private static let bracketedPasteCSIRemoveRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"\u{001B}\[\??2004[hl]"#, options: [])
    }()

    private static let bracketedPasteVisibleRemnantRegex: NSRegularExpression? = {
        try? NSRegularExpression(pattern: #"2004[hl]"#, options: [])
    }()

    private static let incompleteCSITailRegex: NSRegularExpression? = {
        try? NSRegularExpression(
            pattern: #"(?:\u{001B}\[[\?0-9;]*|\[[\?0-9;]*)$"#,
            options: []
        )
    }()
}
