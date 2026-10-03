import SwiftUI
import AppKit

extension Notification.Name {
    static let proTermSplitPane = Notification.Name("ProTermSplitPane")
    static let proTermClosePane = Notification.Name("ProTermClosePane")
    static let proTermCyclePane = Notification.Name("ProTermCyclePane")
}

/// Renders a tab's split layout: one `TerminalView` per pane with draggable dividers.
struct PaneTreeView: View {
    let node: PaneNode
    let tabID: UUID

    var body: some View {
        switch node {
        case .leaf(let sessionID):
            PaneLeafView(sessionID: sessionID, tabID: tabID)
        case .split(_, let axis, let first, let second):
            PaneSplitView(axis: axis, tabID: tabID, first: first, second: second)
        }
    }
}

private struct PaneLeafView: View {
    let sessionID: UUID
    let tabID: UUID
    @EnvironmentObject private var terminalManager: TerminalManager

    var body: some View {
        if let session = terminalManager.session(forPane: sessionID) {
            let isActive = (terminalManager.activePane[tabID] ?? tabID) == sessionID
            TerminalView(session: session)
                .id(session.id)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .overlay(
                    RoundedRectangle(cornerRadius: 4)
                        .stroke(isActive ? Color.accentColor.opacity(0.7) : Color.clear, lineWidth: 2)
                        .allowsHitTesting(false)
                )
                // Clicking anywhere in a pane makes it the active one and moves keyboard focus there.
                .simultaneousGesture(TapGesture().onEnded {
                    terminalManager.setActivePane(session.id)
                    CommandInputFocusController.shared.setActiveSession(session.id)
                    NotificationCenter.default.post(name: .focusCommandInput, object: session.id)
                    CommandInputFocusController.shared.requestFocus(for: session.id, reason: .manual)
                })
        } else {
            Color.clear
        }
    }
}

private struct PaneSplitView: View {
    let axis: PaneAxis
    let tabID: UUID
    let first: PaneNode
    let second: PaneNode

    @State private var ratio: CGFloat = 0.5
    @State private var dragStartRatio: CGFloat?
    private let dividerThickness: CGFloat = 6

    var body: some View {
        GeometryReader { geo in
            let total = axis == .horizontal ? geo.size.width : geo.size.height
            let usable = max(total - dividerThickness, 1)
            let firstSize = usable * ratio
            let secondSize = usable - firstSize
            if axis == .horizontal {
                HStack(spacing: 0) {
                    PaneTreeView(node: first, tabID: tabID).frame(width: firstSize)
                    divider(total: usable)
                    PaneTreeView(node: second, tabID: tabID).frame(width: secondSize)
                }
            } else {
                VStack(spacing: 0) {
                    PaneTreeView(node: first, tabID: tabID).frame(height: firstSize)
                    divider(total: usable)
                    PaneTreeView(node: second, tabID: tabID).frame(height: secondSize)
                }
            }
        }
    }

    private func divider(total: CGFloat) -> some View {
        Rectangle()
            .fill(Color.secondary.opacity(0.25))
            .frame(width: axis == .horizontal ? dividerThickness : nil,
                   height: axis == .vertical ? dividerThickness : nil)
            .contentShape(Rectangle())
            .onHover { inside in
                if inside {
                    (axis == .horizontal ? NSCursor.resizeLeftRight : NSCursor.resizeUpDown).push()
                } else {
                    NSCursor.pop()
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1, coordinateSpace: .global)
                    .onChanged { value in
                        let start = dragStartRatio ?? ratio
                        dragStartRatio = start
                        let delta = axis == .horizontal ? value.translation.width : value.translation.height
                        ratio = min(0.85, max(0.15, start + delta / total))
                    }
                    .onEnded { _ in dragStartRatio = nil }
            )
    }
}
