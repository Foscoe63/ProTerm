import Foundation
import SwiftUI
import Combine

/// Manages AI preferences and settings
@MainActor
class AIManager: ObservableObject {
    @Published var selectedAI: AIType = .siri
    @Published var lmStudioURL: String = "http://localhost:1234"
    @Published var lmStudioModel: String = ""
    
    enum AIType: String, CaseIterable, Identifiable {
        case siri = "siri"
        case lmStudio = "lmstudio"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .siri: return "Siri"
            case .lmStudio: return "LM Studio"
            }
        }
        
        var description: String {
            switch self {
            case .siri: return "Apple's Siri - Built-in voice assistant"
            case .lmStudio: return "LM Studio - Local AI model server"
            }
        }
        
        var icon: String {
            switch self {
            case .siri: return "mic.fill"
            case .lmStudio: return "cpu"
            }
        }
    }
    
    init() {
        loadPreferences()
    }
    
    private func loadPreferences() {
        if let savedAI = UserDefaults.standard.string(forKey: "selectedAI"),
           let aiType = AIType(rawValue: savedAI) {
            selectedAI = aiType
        }
        
        if let savedURL = UserDefaults.standard.string(forKey: "lmStudioURL") {
            lmStudioURL = savedURL
        }
        
        if let savedModel = UserDefaults.standard.string(forKey: "lmStudioModel") {
            lmStudioModel = savedModel
        }
    }
    
    func setAI(_ ai: AIType) {
        guard selectedAI != ai else { return }
        selectedAI = ai
        UserDefaults.standard.set(ai.rawValue, forKey: "selectedAI")
    }
    
    func setLMStudioURL(_ url: String) {
        guard lmStudioURL != url else { return }
        lmStudioURL = url
        UserDefaults.standard.set(url, forKey: "lmStudioURL")
    }
    
    func setLMStudioModel(_ model: String) {
        guard lmStudioModel != model else { return }
        lmStudioModel = model
        UserDefaults.standard.set(model, forKey: "lmStudioModel")
    }
}

