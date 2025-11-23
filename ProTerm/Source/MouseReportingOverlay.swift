import SwiftUI
import AppKit

/// Transparent overlay that captures mouse events and forwards them to the PTY when
/// mouse reporting is enabled. Coordinates are converted to terminal cells so TUIs
/// that rely on xterm-style reporting behave correctly.
struct MouseReportingOverlay: NSViewRepresentable {
    var isEnabled: Bool
    var cellSize: CGSize
    var contentInsets: EdgeInsets
    var sendSequence: (String) -> Void
    
    func makeNSView(context: Context) -> MouseReportingNSView {
        let view = MouseReportingNSView()
        view.sendSequence = sendSequence
        view.cellSize = cellSize
        view.contentInsets = NSEdgeInsets(top: contentInsets.top,
                                          left: contentInsets.leading,
                                          bottom: contentInsets.bottom,
                                          right: contentInsets.trailing)
        view.isReportingEnabled = isEnabled
        return view
    }
    
    func updateNSView(_ nsView: MouseReportingNSView, context: Context) {
        nsView.sendSequence = sendSequence
        nsView.cellSize = cellSize
        nsView.contentInsets = NSEdgeInsets(top: contentInsets.top,
                                            left: contentInsets.leading,
                                            bottom: contentInsets.bottom,
                                            right: contentInsets.trailing)
        nsView.isReportingEnabled = isEnabled
    }
}

final class MouseReportingNSView: NSView {
    var isReportingEnabled: Bool = false {
        didSet {
            needsDisplay = true
            updateTrackingAreas()
        }
    }
    var cellSize: CGSize = CGSize(width: 8, height: 16)
    var contentInsets: NSEdgeInsets = NSEdgeInsets(top: 0, left: 0, bottom: 0, right: 0)
    var sendSequence: ((String) -> Void)?
    
    private var trackingArea: NSTrackingArea?
    private var pressedButtonCode: Int?
    
    override init(frame frameRect: NSRect) {
        super.init(frame: frameRect)
        wantsLayer = false
        translatesAutoresizingMaskIntoConstraints = false
    }
    
    required init?(coder: NSCoder) {
        nil
    }
    
    override var isOpaque: Bool { false }
    
    override func hitTest(_ point: NSPoint) -> NSView? {
        return isReportingEnabled ? self : nil
    }
    
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool {
        return true
    }
    
    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let trackingArea {
            removeTrackingArea(trackingArea)
        }
        let options: NSTrackingArea.Options = [.mouseMoved, .activeInKeyWindow, .inVisibleRect]
        let area = NSTrackingArea(rect: bounds, options: options, owner: self, userInfo: nil)
        addTrackingArea(area)
        trackingArea = area
    }
    
    override func mouseDown(with event: NSEvent) {
        guard isReportingEnabled else { return }
        pressedButtonCode = 0
        sendMouseEvent(buttonCode: 0, event: event, isRelease: false)
    }
    
    override func mouseDragged(with event: NSEvent) {
        guard isReportingEnabled, let button = pressedButtonCode else { return }
        sendMouseEvent(buttonCode: button + 32, event: event, isRelease: false)
    }
    
    override func mouseUp(with event: NSEvent) {
        guard isReportingEnabled, let button = pressedButtonCode else { return }
        sendMouseEvent(buttonCode: button, event: event, isRelease: true)
        pressedButtonCode = nil
    }
    
    override func rightMouseDown(with event: NSEvent) {
        guard isReportingEnabled else { return }
        pressedButtonCode = 2
        sendMouseEvent(buttonCode: 2, event: event, isRelease: false)
    }
    
    override func rightMouseDragged(with event: NSEvent) {
        guard isReportingEnabled, let button = pressedButtonCode else { return }
        sendMouseEvent(buttonCode: button + 32, event: event, isRelease: false)
    }
    
    override func rightMouseUp(with event: NSEvent) {
        guard isReportingEnabled, let button = pressedButtonCode else { return }
        sendMouseEvent(buttonCode: button, event: event, isRelease: true)
        pressedButtonCode = nil
    }
    
    override func scrollWheel(with event: NSEvent) {
        guard isReportingEnabled else { return }
        let deltaY = event.scrollingDeltaY
        let buttonCode = deltaY > 0 ? 64 : 65
        sendMouseEvent(buttonCode: buttonCode, event: event, isRelease: false, useReleaseSuffix: false)
    }
    
    private func sendMouseEvent(buttonCode: Int, event: NSEvent, isRelease: Bool, useReleaseSuffix: Bool = true) {
        guard let sendSequence else { return }
        guard let coords = gridPosition(for: event) else { return }
        let suffix = (isRelease && useReleaseSuffix) ? "m" : "M"
        let sequence = "\u{001B}[<\(buttonCode);\(coords.column);\(coords.row)\(suffix)"
        sendSequence(sequence)
    }
    
    private func gridPosition(for event: NSEvent) -> (column: Int, row: Int)? {
        guard cellSize.width > 0, cellSize.height > 0 else { return nil }
        let location = convert(event.locationInWindow, from: nil)
        let contentRect = NSRect(
            x: bounds.minX + contentInsets.left,
            y: bounds.minY + contentInsets.bottom,
            width: max(0, bounds.width - (contentInsets.left + contentInsets.right)),
            height: max(0, bounds.height - (contentInsets.top + contentInsets.bottom))
        )
        guard contentRect.contains(location) else { return nil }
        let x = max(0, location.x - contentRect.minX)
        let y = max(0, contentRect.maxY - location.y)
        let column = Int(x / cellSize.width) + 1
        let row = Int(y / cellSize.height) + 1
        return (column, row)
    }
}

