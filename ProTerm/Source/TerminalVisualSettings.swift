import SwiftUI
import Combine
import AppKit

/// Manages visual terminal settings: cursor styles, bell customization, scrollback control
@MainActor
class TerminalVisualSettings: ObservableObject {
    
    // MARK: - Cursor Settings
    enum CursorStyle: String, CaseIterable, Identifiable {
        case block = "Block"
        case underline = "Underline"
        case bar = "Bar"
        case hollowBlock = "Hollow Block"
        
        var id: String { rawValue }
        
        var description: String {
            switch self {
            case .block: return "Solid block cursor"
            case .underline: return "Underline cursor"
            case .bar: return "Vertical bar cursor"
            case .hollowBlock: return "Hollow block cursor"
            }
        }
    }
    
    @Published var cursorStyle: CursorStyle = .block {
        didSet { save() }
    }
    
    @Published var cursorBlinking: Bool = true {
        didSet { save() }
    }
    
    @Published var cursorColor: Color = .white {
        didSet { save() }
    }
    
    // MARK: - Bell Settings
    enum BellAction: String, CaseIterable, Identifiable {
        case none = "None"
        case sound = "Sound"
        case visual = "Visual Flash"
        case notification = "Notification"
        case soundAndVisual = "Sound + Visual"
        case all = "All"
        
        var id: String { rawValue }
        
        var description: String {
            switch self {
            case .none: return "Disable bell"
            case .sound: return "Play system sound"
            case .visual: return "Flash screen"
            case .notification: return "Show notification"
            case .soundAndVisual: return "Sound and flash"
            case .all: return "Sound, flash, and notification"
            }
        }
    }
    
    @Published var bellAction: BellAction = .sound {
        didSet { save() }
    }
    
    @Published var bellSoundVolume: Double = 0.5 {
        didSet { save() }
    }
    
    @Published var bellVisualFlashColor: Color = .red {
        didSet { save() }
    }
    
    @Published var bellVisualFlashDuration: Double = 0.1 {
        didSet { save() }
    }
    
    // MARK: - Scrollback Settings
    @Published var scrollbackLimit: Int = 10000 {
        didSet { save() }
    }
    
    @Published var scrollbackEnabled: Bool = true {
        didSet { save() }
    }
    
    @Published var autoScroll: Bool = true {
        didSet { save() }
    }
    
    // MARK: - UserDefaults Keys
    private let cursorStyleKey = "ProTermCursorStyle"
    private let cursorBlinkingKey = "ProTermCursorBlinking"
    private let bellActionKey = "ProTermBellAction"
    private let bellVolumeKey = "ProTermBellVolume"
    private let scrollbackLimitKey = "ProTermScrollbackLimit"
    private let scrollbackEnabledKey = "ProTermScrollbackEnabled"
    private let autoScrollKey = "ProTermAutoScroll"
    
    init() {
        load()
    }
    
    private func load() {
        // Load cursor settings
        if let styleString = UserDefaults.standard.string(forKey: cursorStyleKey),
           let style = CursorStyle(rawValue: styleString) {
            cursorStyle = style
        }
        cursorBlinking = UserDefaults.standard.bool(forKey: cursorBlinkingKey)
        
        // Load bell settings
        if let actionString = UserDefaults.standard.string(forKey: bellActionKey),
           let action = BellAction(rawValue: actionString) {
            bellAction = action
        }
        bellSoundVolume = UserDefaults.standard.double(forKey: bellVolumeKey)
        if bellSoundVolume == 0.0 { bellSoundVolume = 0.5 } // Default
        
        // Load scrollback settings
        scrollbackLimit = UserDefaults.standard.integer(forKey: scrollbackLimitKey)
        if scrollbackLimit == 0 { scrollbackLimit = 10000 } // Default
        scrollbackEnabled = UserDefaults.standard.object(forKey: scrollbackEnabledKey) as? Bool ?? true
        autoScroll = UserDefaults.standard.object(forKey: autoScrollKey) as? Bool ?? true
    }
    
    private func save() {
        UserDefaults.standard.set(cursorStyle.rawValue, forKey: cursorStyleKey)
        UserDefaults.standard.set(cursorBlinking, forKey: cursorBlinkingKey)
        UserDefaults.standard.set(bellAction.rawValue, forKey: bellActionKey)
        UserDefaults.standard.set(bellSoundVolume, forKey: bellVolumeKey)
        UserDefaults.standard.set(scrollbackLimit, forKey: scrollbackLimitKey)
        UserDefaults.standard.set(scrollbackEnabled, forKey: scrollbackEnabledKey)
        UserDefaults.standard.set(autoScroll, forKey: autoScrollKey)
    }
    
    // MARK: - Helper Methods
    
    func shouldPlayBellSound() -> Bool {
        return bellAction == .sound || bellAction == .soundAndVisual || bellAction == .all
    }
    
    func shouldFlashVisual() -> Bool {
        return bellAction == .visual || bellAction == .soundAndVisual || bellAction == .all
    }
    
    func shouldShowNotification() -> Bool {
        return bellAction == .notification || bellAction == .all
    }
}

