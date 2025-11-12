import SwiftUI
import Combine

/// Manages font preferences for the terminal
@MainActor
final class FontManager: ObservableObject {
    @Published var fontName: String = "Menlo" {
        didSet { saveFont() }
    }
    
    @Published var fontSize: Double = 12 {
        didSet { saveFont() }
    }
    
    private let fontNameKey = "ProTermFontName"
    private let fontSizeKey = "ProTermFontSize"
    
    init() {
        // Load saved font preferences
        if let name = UserDefaults.standard.string(forKey: fontNameKey) {
            fontName = name
        }
        let savedSize = UserDefaults.standard.integer(forKey: fontSizeKey)
        if savedSize != 0 {
            fontSize = Double(savedSize)
        }
    }
    
    private func saveFont() {
        UserDefaults.standard.set(fontName, forKey: fontNameKey)
        UserDefaults.standard.set(Int(fontSize), forKey: fontSizeKey)
    }
    
    /// Returns a Font configured with the current settings
    var font: Font {
        .custom(fontName, size: fontSize)
    }
}

