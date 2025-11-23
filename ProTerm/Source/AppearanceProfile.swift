import SwiftUI

/// Describes a reusable appearance preset that mirrors macOS Terminal profiles.
struct AppearanceProfile: Identifiable, Codable, Equatable {
    enum Kind: String, Codable {
        case builtIn
        case custom
    }
    
    enum BackgroundMaterial: String, CaseIterable, Codable, Identifiable {
        case solid
        case translucent
        case vibrantLight
        case vibrantDark
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .solid: return "Solid Color"
            case .translucent: return "Glass"
            case .vibrantLight: return "Vibrant Light"
            case .vibrantDark: return "Vibrant Dark"
            }
        }
        
        var material: Material? {
            switch self {
            case .solid:
                return nil
            case .translucent:
                return .ultraThinMaterial
            case .vibrantLight:
                return .thinMaterial
            case .vibrantDark:
                return .thickMaterial
            }
        }
    }
    
    var id: UUID
    var name: String
    var theme: Theme
    var fontName: String
    var fontSize: Double
    var backgroundMaterial: BackgroundMaterial
    var backgroundOpacity: Double
    var cornerRadius: Double
    var horizontalPadding: Double
    var verticalPadding: Double
    var kind: Kind
    
    init(
        id: UUID = UUID(),
        name: String,
        theme: Theme,
        fontName: String = "Menlo",
        fontSize: Double = 13,
        backgroundMaterial: BackgroundMaterial = .solid,
        backgroundOpacity: Double = 1.0,
        cornerRadius: Double = 12,
        horizontalPadding: Double = 18,
        verticalPadding: Double = 14,
        kind: Kind = .custom
    ) {
        self.id = id
        self.name = name
        self.theme = theme
        self.fontName = fontName
        self.fontSize = fontSize
        self.backgroundMaterial = backgroundMaterial
        self.backgroundOpacity = backgroundOpacity
        self.cornerRadius = cornerRadius
        self.horizontalPadding = horizontalPadding
        self.verticalPadding = verticalPadding
        self.kind = kind
    }
    
    var isCustom: Bool { kind == .custom }
    
    var paddingInsets: EdgeInsets {
        EdgeInsets(top: verticalPadding, leading: horizontalPadding, bottom: verticalPadding, trailing: horizontalPadding)
    }
    static func == (lhs: AppearanceProfile, rhs: AppearanceProfile) -> Bool {
        lhs.id == rhs.id &&
        lhs.name == rhs.name &&
        lhs.theme == rhs.theme &&
        lhs.fontName == rhs.fontName &&
        lhs.fontSize == rhs.fontSize &&
        lhs.backgroundMaterial == rhs.backgroundMaterial &&
        lhs.backgroundOpacity == rhs.backgroundOpacity &&
        lhs.cornerRadius == rhs.cornerRadius &&
        lhs.horizontalPadding == rhs.horizontalPadding &&
        lhs.verticalPadding == rhs.verticalPadding &&
        lhs.kind == rhs.kind
    }
}

extension AppearanceProfile {
    static let builtIn: [AppearanceProfile] = [
        AppearanceProfile(
            name: "Basic",
            theme: Theme(background: .white, foreground: .black, cursor: .black),
            fontName: "Menlo",
            fontSize: 13,
            backgroundMaterial: .solid,
            backgroundOpacity: 1.0,
            cornerRadius: 8,
            horizontalPadding: 16,
            verticalPadding: 12,
            kind: .builtIn
        ),
        AppearanceProfile(
            name: "Pro",
            theme: Theme(
                background: .black,
                foreground: Color(red: 0.0, green: 0.9, blue: 0.0),
                cursor: .white
            ),
            fontName: "SF Mono",
            fontSize: 13,
            backgroundMaterial: .vibrantDark,
            backgroundOpacity: 0.75,
            cornerRadius: 14,
            horizontalPadding: 20,
            verticalPadding: 16,
            kind: .builtIn
        ),
        AppearanceProfile(
            name: "Midnight",
            theme: Theme(
                background: Color(red: 0.05, green: 0.07, blue: 0.12),
                foreground: Color(red: 0.62, green: 0.78, blue: 1.0),
                cursor: Color(red: 0.39, green: 0.86, blue: 1.0)
            ),
            fontName: "SF Mono",
            fontSize: 13,
            backgroundMaterial: .vibrantDark,
            backgroundOpacity: 0.8,
            cornerRadius: 18,
            horizontalPadding: 22,
            verticalPadding: 18,
            kind: .builtIn
        ),
        AppearanceProfile(
            name: "Sunset",
            theme: Theme(
                background: Color(red: 0.18, green: 0.03, blue: 0.12),
                foreground: Color(red: 1.0, green: 0.74, blue: 0.53),
                cursor: Color(red: 1.0, green: 0.54, blue: 0.4)
            ),
            fontName: "Fira Code",
            fontSize: 13,
            backgroundMaterial: .translucent,
            backgroundOpacity: 0.9,
            cornerRadius: 16,
            horizontalPadding: 22,
            verticalPadding: 16,
            kind: .builtIn
        ),
        AppearanceProfile(
            name: "Nord",
            theme: Theme(
                background: Color(red: 0.14, green: 0.18, blue: 0.23),
                foreground: Color(red: 0.76, green: 0.84, blue: 0.89),
                cursor: Color(red: 0.52, green: 0.72, blue: 0.82)
            ),
            fontName: "Menlo",
            fontSize: 12,
            backgroundMaterial: .solid,
            backgroundOpacity: 0.95,
            cornerRadius: 14,
            horizontalPadding: 20,
            verticalPadding: 16,
            kind: .builtIn
        ),
        AppearanceProfile(
            name: "Ocean",
            theme: Theme(
                background: Color(red: 0.0, green: 0.17, blue: 0.21),
                foreground: Color(red: 0.72, green: 0.82, blue: 0.82),
                cursor: .white
            ),
            fontName: "Menlo",
            fontSize: 12,
            backgroundMaterial: .translucent,
            backgroundOpacity: 0.85,
            cornerRadius: 18,
            horizontalPadding: 24,
            verticalPadding: 18,
            kind: .builtIn
        ),
        AppearanceProfile(
            name: "Man Page",
            theme: Theme(
                background: Color(red: 0.98, green: 0.98, blue: 0.94),
                foreground: Color(red: 0.2, green: 0.2, blue: 0.2),
                cursor: .black
            ),
            fontName: "SF Mono",
            fontSize: 14,
            backgroundMaterial: .solid,
            backgroundOpacity: 1.0,
            cornerRadius: 12,
            horizontalPadding: 18,
            verticalPadding: 12,
            kind: .builtIn
        ),
        AppearanceProfile(
            name: "Novel",
            theme: Theme(
                background: Color(red: 1.0, green: 0.99, blue: 0.95),
                foreground: Color(red: 0.15, green: 0.15, blue: 0.15),
                cursor: .black
            ),
            fontName: "Georgia",
            fontSize: 13,
            backgroundMaterial: .translucent,
            backgroundOpacity: 0.92,
            cornerRadius: 20,
            horizontalPadding: 26,
            verticalPadding: 18,
            kind: .builtIn
        )
    ]
}

