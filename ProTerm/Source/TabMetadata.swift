import SwiftUI
import Foundation

/// Metadata for terminal tabs (name, color, etc.)
struct TabMetadata: Identifiable, Codable {
    let id: UUID
    var name: String
    var color: TabColor
    var createdAt: Date
    var scrollPosition: Double = 0.0 // Saved scroll position
    
    init(id: UUID = UUID(), name: String, color: TabColor = .default, createdAt: Date = Date(), scrollPosition: Double = 0.0) {
        self.id = id
        self.name = name
        self.color = color
        self.createdAt = createdAt
        self.scrollPosition = scrollPosition
    }
}

enum TabColor: String, Codable, CaseIterable, Equatable {
    case `default` = "Default"
    case red = "Red"
    case orange = "Orange"
    case yellow = "Yellow"
    case green = "Green"
    case blue = "Blue"
    case purple = "Purple"
    case pink = "Pink"
    case gray = "Gray"
    
    var color: Color {
        switch self {
        case .default: return .primary
        case .red: return .red
        case .orange: return .orange
        case .yellow: return .yellow
        case .green: return .green
        case .blue: return .blue
        case .purple: return .purple
        case .pink: return .pink
        case .gray: return .gray
        }
    }
}

