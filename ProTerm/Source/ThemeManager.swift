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
        // Convert SwiftUI `Color` → `NSColor` in a safe RGB color space.
        // Accessing NSColor's .redComponent/.greenComponent/.blueComponent on a non-RGB color space
        // can crash. Always convert to sRGB or deviceRGB first.
        let ns = NSColor(color)
        let rgb = ns.usingColorSpace(.sRGB) ?? ns.usingColorSpace(.deviceRGB) ?? NSColor(red: 0, green: 0, blue: 0, alpha: 1)
        self.red   = rgb.redComponent
        self.green = rgb.greenComponent
        self.blue  = rgb.blueComponent
        self.alpha = rgb.alphaComponent
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

/* ---------- macOS Terminal-like Profiles ---------- */
enum TerminalProfile: String, CaseIterable, Identifiable {
    case basic = "Basic"
    case pro = "Pro"
    case ocean = "Ocean"
    case redSands = "Red Sands"
    case grass = "Grass"
    case manPage = "Man Page"
    case novel = "Novel"

    var id: String { rawValue }

    var theme: Theme {
        switch self {
        case .basic:
            // White background, black text
            return Theme(background: .white, foreground: .black, cursor: .black)
        case .pro:
            // Black background, green text
            return Theme(background: .black, foreground: Color(red: 0.0, green: 0.9, blue: 0.0), cursor: .white)
        case .ocean:
            // Dark blue-ish background with light foreground
            return Theme(background: Color(red: 0.0, green: 0.17, blue: 0.21),
                         foreground: Color(red: 0.72, green: 0.82, blue: 0.82),
                         cursor: .white)
        case .redSands:
            return Theme(background: Color(red: 0.24, green: 0.06, blue: 0.0),
                         foreground: Color(red: 1.0, green: 0.76, blue: 0.66),
                         cursor: .white)
        case .grass:
            return Theme(background: Color(red: 0.02, green: 0.15, blue: 0.02),
                         foreground: Color(red: 0.75, green: 1.0, blue: 0.75),
                         cursor: .white)
        case .manPage:
            return Theme(background: Color(red: 0.98, green: 0.98, blue: 0.94),
                         foreground: Color(red: 0.20, green: 0.20, blue: 0.20),
                         cursor: .black)
        case .novel:
            return Theme(background: Color(red: 1.0, green: 0.99, blue: 0.95),
                         foreground: Color(red: 0.15, green: 0.15, blue: 0.15),
                         cursor: .black)
        }
    }
}

/* ---------- Manager that the UI observes ---------- */
final class ThemeManager: ObservableObject {
    // Stored, published property – changes now correctly propagate.
    @Published var current: Theme = Theme() {
        didSet { saveTheme() }
    }

    @Published var selectedProfile: TerminalProfile = .pro {
        didSet { applyProfile(selectedProfile) }
    }

    private let defaultsKeyTheme = "ProTermSelectedTheme"
    private let defaultsKeyProfile = "ProTermSelectedProfile"

    init() {
        // Load profile first
        if let savedProfile = UserDefaults.standard.string(forKey: defaultsKeyProfile),
           let profile = TerminalProfile(rawValue: savedProfile) {
            selectedProfile = profile
            current = profile.theme
        } else if let data = UserDefaults.standard.data(forKey: defaultsKeyTheme),
                  let decoded = try? JSONDecoder().decode(Theme.self, from: data) {
            // Fallback to previously saved custom theme
            current = decoded
        } else {
            // Default to Pro profile
            selectedProfile = .pro
            current = TerminalProfile.pro.theme
        }
    }

    private func applyProfile(_ profile: TerminalProfile) {
        current = profile.theme
        saveProfile(profile)
    }

    private func saveTheme() {
        if let data = try? JSONEncoder().encode(current) {
            UserDefaults.standard.set(data, forKey: defaultsKeyTheme)
        }
    }

    private func saveProfile(_ profile: TerminalProfile) {
        UserDefaults.standard.set(profile.rawValue, forKey: defaultsKeyProfile)
    }
}
