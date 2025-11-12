import Foundation
import SwiftUI
import Combine

@MainActor
class LineNumbersManager: ObservableObject {
    @Published var showLineNumbers: Bool = false
    
    private let lineNumbersKey = "ProTermShowLineNumbers"
    
    init() {
        loadPreferences()
    }
    
    private func loadPreferences() {
        showLineNumbers = UserDefaults.standard.bool(forKey: lineNumbersKey)
    }
    
    func setLineNumbers(_ enabled: Bool) {
        showLineNumbers = enabled
        UserDefaults.standard.set(enabled, forKey: lineNumbersKey)
    }
}
