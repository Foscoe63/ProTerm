import SwiftUI
import AppKit

@MainActor
final class BellFeedbackManager {
    static let shared = BellFeedbackManager()
    
    private init() {}
    
    func triggerBell(in window: NSWindow?, sessionName: String, settings: TerminalVisualSettings) {
        if settings.shouldPlayBellSound() {
            playSound(volume: settings.bellSoundVolume)
        }
        
        if settings.shouldFlashVisual() {
            let targetWindow = window ?? NSApplication.shared.mainWindow
            presentFlash(on: targetWindow, color: settings.bellVisualFlashColor, duration: settings.bellVisualFlashDuration)
        }
        
        if settings.shouldShowNotification() {
            NotificationHelper.shared.notify(
                title: "Terminal Bell",
                body: "A terminal bell was triggered in \(sessionName)"
            )
        }
    }
    
    func previewBell(using settings: TerminalVisualSettings) {
        triggerBell(in: NSApplication.shared.keyWindow, sessionName: "Preferences Preview", settings: settings)
    }
    
    private func playSound(volume: Double) {
        if let sound = NSSound(named: "Glass")?.copy() as? NSSound {
            sound.volume = Float(volume)
            sound.play()
        } else {
            NSSound.beep()
        }
    }
    
    private func presentFlash(on window: NSWindow?, color: Color, duration: Double) {
        guard let window else { return }
        guard let baseContentView = window.contentView else { return }
        
        let hostingClass: AnyClass? = NSClassFromString("NSHostingView")
        let hostAwareTarget: NSView
        if let hostingClass,
           baseContentView.isKind(of: hostingClass),
           let hostingSuper = baseContentView.superview {
            hostAwareTarget = hostingSuper
        } else {
            hostAwareTarget = baseContentView
        }
        
        let overlay = NSView(frame: hostAwareTarget.bounds)
        overlay.translatesAutoresizingMaskIntoConstraints = false
        overlay.wantsLayer = true
        let nsColor = NSColor(color)
        overlay.layer?.backgroundColor = nsColor.withAlphaComponent(0.45).cgColor
        overlay.alphaValue = 0.0
        
        hostAwareTarget.addSubview(overlay, positioned: .above, relativeTo: nil)
        NSLayoutConstraint.activate([
            overlay.leadingAnchor.constraint(equalTo: hostAwareTarget.leadingAnchor),
            overlay.trailingAnchor.constraint(equalTo: hostAwareTarget.trailingAnchor),
            overlay.topAnchor.constraint(equalTo: hostAwareTarget.topAnchor),
            overlay.bottomAnchor.constraint(equalTo: hostAwareTarget.bottomAnchor)
        ])
        
        NSAnimationContext.runAnimationGroup { context in
            context.duration = 0.1
            overlay.animator().alphaValue = 1.0
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + duration) {
            NSAnimationContext.runAnimationGroup { context in
                context.duration = 0.15
                overlay.animator().alphaValue = 0.0
            } completionHandler: {
                Task { @MainActor in
                    overlay.removeFromSuperview()
                }
            }
        }
    }
}

