import Foundation
import Combine

@MainActor
final class TerminalInputViewModel: ObservableObject {
    // Current input line
    @Published var commandText: String = ""
    // Command history navigation
    @Published private(set) var history: [String] = []
    @Published private(set) var historyIndex: Int = -1 // -1 = not navigating

    // Callbacks to integrate with TerminalSession without hard coupling
    var onSubmit: ((String) -> Void)?

    func submit() {
        let trimmed = commandText.trimmingCharacters(in: .whitespacesAndNewlines)
        onSubmit?(commandText)
        if !trimmed.isEmpty {
            history.append(commandText)
            historyIndex = -1
        }
        commandText = ""
    }

    func navigateHistory(up: Bool) {
        guard !history.isEmpty else { return }
        if up {
            if historyIndex < 0 {
                historyIndex = history.count - 1
            } else {
                historyIndex = max(0, historyIndex - 1)
            }
        } else {
            if historyIndex >= 0 {
                historyIndex += 1
                if historyIndex >= history.count {
                    historyIndex = -1
                    commandText = ""
                    return
                }
            }
        }
        if historyIndex >= 0 { commandText = history[historyIndex] }
    }
}
