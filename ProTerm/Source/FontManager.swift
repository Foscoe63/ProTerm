import SwiftUI
import Combine
import AppKit

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
    
    /// Returns an NSFont for precise layout metrics
    var nsFont: NSFont {
        if let custom = NSFont(name: fontName, size: fontSize) {
            return custom
        }
        return NSFont.monospacedSystemFont(ofSize: fontSize, weight: .regular)
    }
    
    /// Approximate character cell size used for mouse-coordinate conversions.
    var characterCellSize: CGSize {
        let font = nsFont
        let sample = "W" as NSString
        let width = max(6, sample.size(withAttributes: [.font: font]).width)
        let height = max(10, CGFloat(font.ascender - font.descender + font.leading))
        return CGSize(width: width, height: height)
    }
}

