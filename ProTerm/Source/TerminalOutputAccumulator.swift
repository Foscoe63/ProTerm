import Foundation

/// Accumulates terminal output text with a maximum scrollback limit and takes
/// care of UTF‑8 boundary handling. This is a simplified, testable unit that
/// can replace ad‑hoc string appends spread across the codebase.
final class TerminalOutputAccumulator {
    private(set) var text: String = ""
    private var utf8Remainder = Data()
    private let maxCharacters: Int

    init(maxCharacters: Int = 200_000) {
        self.maxCharacters = max(10_000, maxCharacters)
    }

    func append(_ data: Data) {
        // Append to remainder and try to decode as UTF‑8 safely
        var buffer = utf8Remainder
        buffer.append(data)
        if let decoded = String(data: buffer, encoding: .utf8) {
            utf8Remainder = Data()
            append(decoded)
        } else {
            // Find a safe split point near the end
            // Keep up to the last 3 bytes in remainder (max UTF‑8 sequence length - 1)
            let keep = min(3, buffer.count)
            let splitIndex = buffer.count - keep
            let head = buffer.prefix(splitIndex)
            let tail = buffer.suffix(keep)
            head.withUnsafeBytes { ptr in
                if let str = String(bytes: ptr, encoding: .utf8) {
                    append(str)
                }
            }
            utf8Remainder = Data(tail)
        }
    }

    func append(_ string: String) {
        text.append(string)
        enforceLimit()
    }

    private func enforceLimit() {
        if text.count > maxCharacters {
            let overflow = text.count - maxCharacters
            let index = text.index(text.startIndex, offsetBy: overflow)
            text.removeSubrange(text.startIndex..<index)
        }
    }
}
