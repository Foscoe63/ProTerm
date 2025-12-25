import Foundation
import Combine

@MainActor
final class TerminalSearchViewModel: ObservableObject {
    @Published var query: String = ""
    @Published var isRegex: Bool = false
    @Published var matchCase: Bool = false

    // Navigation callbacks provided by the owner (view/session)
    var onFindNext: ((String, Bool, Bool) -> Void)?
    var onFindPrevious: ((String, Bool, Bool) -> Void)?

    func findNext() {
        onFindNext?(query, isRegex, matchCase)
    }

    func findPrevious() {
        onFindPrevious?(query, isRegex, matchCase)
    }
}
