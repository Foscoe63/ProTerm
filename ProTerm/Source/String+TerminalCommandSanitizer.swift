import Foundation

extension String {
    func sanitizedTerminalCommand() -> String {
        if isEmpty { return self }
        let replacements: [Character: Character] = [
            "“": "\"",
            "”": "\"",
            "„": "\"",
            "‟": "\"",
            "«": "\"",
            "»": "\"",
            "‘": "'",
            "’": "'",
            "‚": "'",
            "‛": "'",
            "‹": "'",
            "›": "'",
            "–": "-",
            "—": "-",
            "−": "-",
            "\u{00A0}": " ",
            "\u{202F}": " "
        ]

        var sanitized = String()
        sanitized.reserveCapacity(count)
        for character in self {
            if let replacement = replacements[character] {
                sanitized.append(replacement)
            } else {
                sanitized.append(character)
            }
        }
        return sanitized
    }
}

