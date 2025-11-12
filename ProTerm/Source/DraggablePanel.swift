import SwiftUI
import AppKit

/// A view modifier that makes a panel draggable by its header
struct DraggablePanelModifier: ViewModifier {
    @State private var dragOffset: CGSize = .zero
    @State private var isDragging: Bool = false
    
    func body(content: Content) -> some View {
        content
            .offset(dragOffset)
            .gesture(
                DragGesture()
                    .onChanged { value in
                        isDragging = true
                        dragOffset = value.translation
                    }
                    .onEnded { _ in
                        isDragging = false
                        // Keep the offset so panel stays in new position
                    }
            )
    }
}

extension View {
    func draggablePanel() -> some View {
        modifier(DraggablePanelModifier())
    }
}

/// A draggable header view for panels
struct DraggableHeader: View {
    let title: String
    let onClose: (() -> Void)?
    
    @State private var dragOffset: CGSize = .zero
    @State private var panelPosition: CGPoint = .zero
    
    init(title: String, onClose: (() -> Void)? = nil) {
        self.title = title
        self.onClose = onClose
    }
    
    var body: some View {
        HStack {
            Text(title)
                .font(.headline)
            Spacer()
            if let onClose = onClose {
                Button(action: onClose) {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding()
        .background(Color(NSColor.controlBackgroundColor))
        .contentShape(Rectangle())
        .gesture(
            DragGesture()
                .onChanged { value in
                    dragOffset = value.translation
                }
                .onEnded { value in
                    panelPosition.x += value.translation.width
                    panelPosition.y += value.translation.height
                    dragOffset = .zero
                }
        )
    }
}

/// A moveable panel container
struct MoveablePanel<Content: View>: View {
    let title: String
    let content: Content
    let onClose: (() -> Void)?
    
    @State private var panelOffset: CGSize = .zero
    
    init(title: String, onClose: (() -> Void)? = nil, @ViewBuilder content: () -> Content) {
        self.title = title
        self.onClose = onClose
        self.content = content()
    }
    
    var body: some View {
        VStack(spacing: 0) {
            // Draggable header
            HStack {
                Text(title)
                    .font(.headline)
                Spacer()
                if let onClose = onClose {
                    Button(action: onClose) {
                        Image(systemName: "xmark.circle.fill")
                            .foregroundColor(.secondary)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding()
            .background(Color(NSColor.controlBackgroundColor))
            .contentShape(Rectangle())
            .gesture(
                DragGesture()
                    .onChanged { value in
                        panelOffset = value.translation
                    }
                    .onEnded { value in
                        // Update position permanently
                        panelOffset.width += value.translation.width
                        panelOffset.height += value.translation.height
                    }
            )
            
            Divider()
            
            // Content
            content
        }
        .background(Color(NSColor.windowBackgroundColor))
        .cornerRadius(12)
        .shadow(color: .black.opacity(0.3), radius: 20, x: 0, y: 10)
        .offset(panelOffset)
    }
}

