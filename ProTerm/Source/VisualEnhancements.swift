import SwiftUI
import AppKit
import Combine

/// Visual enhancements for terminal including cursor, scroll indicators, and bracket matching
@MainActor
class VisualEnhancements: NSObject, ObservableObject {
    
    // MARK: - Published Properties
    @Published var isEnabled: Bool = true
    
    // MARK: - Initialization
    override init() {
        super.init()
    }
    
    // MARK: - Cursor Animation
    @Published var cursorBlinking: Bool = true
    @Published var cursorVisible: Bool = true
    @Published var cursorPosition: CGPoint = .zero
    
    private var cursorTimer: Timer?
    
    // MARK: - Scroll Indicators
    @Published var showScrollIndicators: Bool = true
    @Published var scrollPosition: Double = 0.0
    @Published var scrollDirection: ScrollDirection = .none
    
    enum ScrollDirection {
        case up, down, left, right, none
    }
    
    // MARK: - Bracket Matching
    @Published var showBracketMatching: Bool = true
    @Published var matchedBrackets: [BracketMatch] = []
    
    struct BracketMatch {
        let openRange: NSRange
        let closeRange: NSRange
        let type: BracketType
    }
    
    enum BracketType {
        case parentheses
        case square
        case curly
        case angle
    }
    
    // MARK: - Minimap
    @Published var showMinimap: Bool = false
    @Published var minimapScale: Double = 0.1
    @Published var minimapPosition: Double = 0.0
    
    // MARK: - Cursor Management
    
    func startCursorBlinking() {
        guard cursorBlinking else { return }
        
        cursorTimer?.invalidate()
        cursorTimer = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { _ in
            DispatchQueue.main.async {
                self.cursorVisible.toggle()
            }
        }
    }
    
    func stopCursorBlinking() {
        cursorTimer?.invalidate()
        cursorTimer = nil
        cursorVisible = true
    }
    
    func updateCursorPosition(_ position: CGPoint) {
        cursorPosition = position
    }
    
    // MARK: - Scroll Management
    
    func updateScrollPosition(_ position: Double, direction: ScrollDirection) {
        scrollPosition = position
        scrollDirection = direction
        
        // Auto-hide scroll indicators after a delay
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            if self.scrollDirection == .none {
                self.showScrollIndicators = false
            }
        }
    }
    
    func showScrollIndicatorsTemporarily() {
        showScrollIndicators = true
        DispatchQueue.main.asyncAfter(deadline: .now() + 2.0) {
            self.showScrollIndicators = false
        }
    }
    
    // MARK: - Bracket Matching
    
    func findMatchingBrackets(in text: String, at position: Int) -> [BracketMatch] {
        var matches: [BracketMatch] = []
        
        let bracketPairs: [(String, String, BracketType)] = [
            ("(", ")", .parentheses),
            ("[", "]", .square),
            ("{", "}", .curly),
            ("<", ">", .angle)
        ]
        
        for (open, close, type) in bracketPairs {
            if let match = findBracketMatch(in: text, at: position, open: open, close: close, type: type) {
                matches.append(match)
            }
        }
        
        return matches
    }
    
    private func findBracketMatch(in text: String, at position: Int, open: String, close: String, type: BracketType) -> BracketMatch? {
        let textArray = Array(text)
        var depth = 0
        var openIndex: Int?
        
        // Find the opening bracket
        for i in 0..<min(position, textArray.count) {
            if String(textArray[i]) == open {
                if depth == 0 {
                    openIndex = i
                }
                depth += 1
            } else if String(textArray[i]) == close {
                depth -= 1
                if depth == 0 && openIndex != nil {
                    return BracketMatch(
                        openRange: NSRange(location: openIndex!, length: 1),
                        closeRange: NSRange(location: i, length: 1),
                        type: type
                    )
                }
            }
        }
        
        return nil
    }
    
    // MARK: - Minimap Management
    
    func updateMinimapPosition(_ position: Double) {
        minimapPosition = position
    }
    
    func toggleMinimap() {
        showMinimap.toggle()
    }
}

// MARK: - Cursor View
struct BlinkingCursor: View {
    @ObservedObject var enhancements: VisualEnhancements
    let color: Color
    
    var body: some View {
        Rectangle()
            .fill(color)
            .frame(width: 2, height: 16)
            .opacity(enhancements.cursorVisible ? 1.0 : 0.0)
            .animation(.easeInOut(duration: 0.5).repeatForever(autoreverses: true), value: enhancements.cursorVisible)
    }
}

// MARK: - Scroll Indicators
struct ScrollIndicators: View {
    @ObservedObject var enhancements: VisualEnhancements
    
    var body: some View {
        VStack {
            // Top scroll indicator
            if enhancements.scrollDirection == .up {
                HStack {
                    Spacer()
                    VStack {
                        Image(systemName: "chevron.up")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Scroll Up")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
                    Spacer()
                }
                .padding(.top, 8)
            }
            
            Spacer()
            
            // Bottom scroll indicator
            if enhancements.scrollDirection == .down {
                HStack {
                    Spacer()
                    VStack {
                        Image(systemName: "chevron.down")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        Text("Scroll Down")
                            .font(.caption2)
                            .foregroundColor(.secondary)
                    }
                    .padding(4)
                    .background(Color.gray.opacity(0.2))
                    .cornerRadius(4)
                    Spacer()
                }
                .padding(.bottom, 8)
            }
        }
        .opacity(enhancements.showScrollIndicators ? 1.0 : 0.0)
        .animation(.easeInOut(duration: 0.3), value: enhancements.showScrollIndicators)
    }
}

// MARK: - Bracket Highlighting
struct BracketHighlighting: View {
    @ObservedObject var enhancements: VisualEnhancements
    let text: String
    
    var body: some View {
        Text(text)
            .overlay(
                ForEach(Array(enhancements.matchedBrackets.enumerated()), id: \.offset) { index, match in
                    Rectangle()
                        .fill(Color.yellow.opacity(0.3))
                        .frame(width: 8, height: 16)
                        .position(x: CGFloat(match.openRange.location * 8), y: 8) // Approximate positioning
                }
            )
    }
}

// MARK: - Minimap View
struct MinimapView: View {
    @ObservedObject var enhancements: VisualEnhancements
    let content: String
    
    var body: some View {
        if enhancements.showMinimap {
            VStack {
                Text("Minimap")
                    .font(.caption2)
                    .foregroundColor(.secondary)
                
                ScrollView {
                    Text(content)
                        .font(.system(.caption2, design: .monospaced))
                        .scaleEffect(enhancements.minimapScale)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(width: 100, height: 200)
                .background(Color.gray.opacity(0.1))
                .cornerRadius(4)
            }
            .padding(4)
        }
    }
}
