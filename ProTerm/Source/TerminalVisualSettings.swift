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
    @Published var scrollbackLimit: Int = 1000000 { // Increased to 1MB default
        didSet { save() }
    }
    
    @Published var scrollbackEnabled: Bool = true {
        didSet { save() }
    }
    
    @Published var autoScroll: Bool = true {
        didSet { save() }
    }
    
    // MARK: - IO Behaviour
    @Published var enableBracketedPaste: Bool = true {
        didSet { save() }
    }
    
    @Published var enableMouseReporting: Bool = false {
        didSet { save() }
    }
    
    // MARK: - Command Box Outline Settings
    @Published var showCommandBoxOutline: Bool = false {
        didSet { save() }
    }
    
    @Published var commandBoxOutlineColor: Color = .blue {
        didSet { save() }
    }
    
    @Published var commandBoxOutlineWidth: CGFloat = 1.0 {
        didSet { save() }
    }
    
    @Published var commandBoxOutlineCornerRadius: CGFloat = 4.0 {
        didSet { save() }
    }
    
    // MARK: - Line Numbering
    @Published var showLineNumbers: Bool = true {
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
    private let bracketedPasteKey = "ProTermBracketedPaste"
    private let mouseReportingKey = "ProTermMouseReporting"
    private let showCommandBoxOutlineKey = "ProTermShowCommandBoxOutline"
    private let commandBoxOutlineColorKey = "ProTermCommandBoxOutlineColor"
    private let commandBoxOutlineWidthKey = "ProTermCommandBoxOutlineWidth"
    private let commandBoxOutlineCornerRadiusKey = "ProTermCommandBoxOutlineCornerRadius"
    private let showLineNumbersKey = "ProTermShowLineNumbers"
    
    /// Flag to prevent saving during initial load
    private var isLoading = false
    
    init() {
        load()
    }
    
    private func load() {
        isLoading = true
        defer { isLoading = false }
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
        if scrollbackLimit == 0 { scrollbackLimit = 1000000 } // Default 1MB
        scrollbackEnabled = UserDefaults.standard.object(forKey: scrollbackEnabledKey) as? Bool ?? true
        autoScroll = UserDefaults.standard.object(forKey: autoScrollKey) as? Bool ?? true
        
        // Load IO settings
        if let storedBracketed = UserDefaults.standard.object(forKey: bracketedPasteKey) as? Bool {
            enableBracketedPaste = storedBracketed
        }
        if let storedMouse = UserDefaults.standard.object(forKey: mouseReportingKey) as? Bool {
            enableMouseReporting = storedMouse
        }
        
        // Load command box outline settings
        showCommandBoxOutline = UserDefaults.standard.object(forKey: showCommandBoxOutlineKey) as? Bool ?? false
        
        // Load line numbering settings
        showLineNumbers = UserDefaults.standard.object(forKey: showLineNumbersKey) as? Bool ?? true
        
        // Load color components
        let red = UserDefaults.standard.double(forKey: "\(commandBoxOutlineColorKey).red")
        let green = UserDefaults.standard.double(forKey: "\(commandBoxOutlineColorKey).green")
        let blue = UserDefaults.standard.double(forKey: "\(commandBoxOutlineColorKey).blue")
        let alpha = UserDefaults.standard.double(forKey: "\(commandBoxOutlineColorKey).alpha")
        
        if red != 0.0 || green != 0.0 || blue != 0.0 || alpha != 0.0 {
            commandBoxOutlineColor = Color(red: red, green: green, blue: blue, opacity: alpha)
        }
        
        // Load outline width and corner radius
        let width = UserDefaults.standard.double(forKey: commandBoxOutlineWidthKey)
        if width > 0.0 {
            commandBoxOutlineWidth = width
        }
        
        let radius = UserDefaults.standard.double(forKey: commandBoxOutlineCornerRadiusKey)
        if radius > 0.0 {
            commandBoxOutlineCornerRadius = radius
        }
    }
    
    private func save() {
        // Don't save during initial load - this prevents overwriting saved values with defaults
        guard !isLoading else { return }
        
        UserDefaults.standard.set(cursorStyle.rawValue, forKey: cursorStyleKey)
        UserDefaults.standard.set(cursorBlinking, forKey: cursorBlinkingKey)
        UserDefaults.standard.set(bellAction.rawValue, forKey: bellActionKey)
        UserDefaults.standard.set(bellSoundVolume, forKey: bellVolumeKey)
        UserDefaults.standard.set(scrollbackLimit, forKey: scrollbackLimitKey)
        UserDefaults.standard.set(scrollbackEnabled, forKey: scrollbackEnabledKey)
        UserDefaults.standard.set(autoScroll, forKey: autoScrollKey)
        UserDefaults.standard.set(enableBracketedPaste, forKey: bracketedPasteKey)
        UserDefaults.standard.set(enableMouseReporting, forKey: mouseReportingKey)
        UserDefaults.standard.set(showCommandBoxOutline, forKey: showCommandBoxOutlineKey)
        UserDefaults.standard.set(showLineNumbers, forKey: showLineNumbersKey)
        
        // Save color components
        let nsColor = NSColor(commandBoxOutlineColor)
        let rgb = nsColor.usingColorSpace(.sRGB) ?? nsColor.usingColorSpace(.deviceRGB) ?? NSColor(red: 0, green: 0, blue: 1, alpha: 1)
        UserDefaults.standard.set(rgb.redComponent, forKey: "\(commandBoxOutlineColorKey).red")
        UserDefaults.standard.set(rgb.greenComponent, forKey: "\(commandBoxOutlineColorKey).green")
        UserDefaults.standard.set(rgb.blueComponent, forKey: "\(commandBoxOutlineColorKey).blue")
        UserDefaults.standard.set(rgb.alphaComponent, forKey: "\(commandBoxOutlineColorKey).alpha")
        UserDefaults.standard.set(commandBoxOutlineWidth, forKey: commandBoxOutlineWidthKey)
        UserDefaults.standard.set(commandBoxOutlineCornerRadius, forKey: commandBoxOutlineCornerRadiusKey)
        
        NotificationCenter.default.post(name: .proTermIOSettingsDidChange, object: nil)
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


