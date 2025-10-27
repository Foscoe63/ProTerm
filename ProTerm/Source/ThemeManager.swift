import SwiftUI          // Color, ObservableObject (re‑exports Combine)
import Combine           // needed for @Published’s synthesized initializer
import AppKit            // NSColor – used to extract RGBA components from a SwiftUI Color

/* ---------- Helper that makes `Color` codable ---------- */
private struct CodableColor: Codable {
    let red: Double
    let green: Double
    let blue: Double
    let alpha: Double

    init(_ color: Color) {
        // Convert SwiftUI `Color` → `NSColor` to read its component values.
        let ns = NSColor(color)
        self.red   = ns.redComponent
        self.green = ns.greenComponent
        self.blue  = ns.blueComponent
        self.alpha = ns.alphaComponent
    }

    var color: Color { Color(red: red, green: green, blue: blue, opacity: alpha) }
}

/* ---------- Theme model (now truly Codable) ---------- */
struct Theme: Codable {
    var background: Color = .black
    var foreground: Color = .green
    var cursor:     Color = .white

    // Custom coding to translate `Color` ↔︎ `CodableColor`.
    enum CodingKeys: String, CodingKey {
        case background, foreground, cursor
    }

    init(background: Color = .black,
         foreground: Color = .green,
         cursor: Color = .white) {
        self.background = background
        self.foreground = foreground
        self.cursor     = cursor
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let bg  = try container.decode(CodableColor.self, forKey: .background).color
        let fg  = try container.decode(CodableColor.self, forKey: .foreground).color
        let cur = try container.decode(CodableColor.self, forKey: .cursor).color
        self.background = bg
        self.foreground = fg
        self.cursor     = cur
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(CodableColor(background), forKey: .background)
        try container.encode(CodableColor(foreground), forKey: .foreground)
        try container.encode(CodableColor(cursor),    forKey: .cursor)
    }
}

/* ---------- Manager that the UI observes ---------- */
final class ThemeManager: ObservableObject {
    // Stored, published property – changes now correctly propagate.
    @Published var current: Theme = Theme() {
        didSet { save() }
    }

    private let defaultsKey = "ProTermSelectedTheme"

    init() {
        if let data = UserDefaults.standard.data(forKey: defaultsKey),
           let decoded = try? JSONDecoder().decode(Theme.self, from: data) {
            current = decoded
        }   // otherwise keep the default Theme()
    }

    private func save() {
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: defaultsKey)
        }
    }
}
