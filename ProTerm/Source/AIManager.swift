import Foundation
import SwiftUI
import Combine

/// Manages AI provider selection, per-provider settings, and builds the active `AIProvider`.
@MainActor
class AIManager: ObservableObject {
    @Published var selectedAI: AIType = .builtIn
    @Published var lmStudioURL: String = "http://localhost:1234"
    @Published var lmStudioModel: String = ""
    @Published var anthropicModel: String = "claude-sonnet-5-5"
    @Published var openAIBaseURL: String = "https://api.openai.com"
    @Published var openAIModel: String = ""
    /// When on, the last lines of the active terminal are sent to the provider as context.
    @Published var includeTerminalContext: Bool = false
    
    enum AIType: String, CaseIterable, Identifiable {
        case builtIn = "siri"  // raw value kept so saved preferences from older versions still load
        case anthropic = "anthropic"
        case openAICompatible = "openai"
        case lmStudio = "lmstudio"
        
        var id: String { rawValue }
        
        var displayName: String {
            switch self {
            case .builtIn: return "Built-in help"
            case .anthropic: return "Claude"
            case .openAICompatible: return "OpenAI-compatible"
            case .lmStudio: return "LM Studio"
            }
        }
        
        var description: String {
            switch self {
            case .builtIn: return "Offline cheat sheet for common commands. Not an AI model; nothing leaves your Mac."
            case .anthropic: return "Claude via the Anthropic API. Requires an API key; chat messages are sent to Anthropic."
            case .openAICompatible: return "Any OpenAI-compatible endpoint (OpenAI, Ollama, OpenRouter, ...). Messages are sent to that server."
            case .lmStudio: return "LM Studio - local model server on your machine."
            }
        }
        
        var icon: String {
            switch self {
            case .builtIn: return "book.fill"
            case .anthropic: return "sparkles"
            case .openAICompatible: return "network"
            case .lmStudio: return "cpu"
            }
        }
        
        /// Keychain account for this provider's API key, if it uses one.
        var keyAccount: String? {
            switch self {
            case .anthropic: return "anthropic-api-key"
            case .openAICompatible: return "openai-api-key"
            default: return nil
            }
        }
    }
    
    private let defaults = UserDefaults.standard
    
    init() {
        loadPreferences()
    }
    
    private func loadPreferences() {
        if let savedAI = defaults.string(forKey: "selectedAI"), let aiType = AIType(rawValue: savedAI) {
            selectedAI = aiType
        }
        lmStudioURL = defaults.string(forKey: "lmStudioURL") ?? lmStudioURL
        lmStudioModel = defaults.string(forKey: "lmStudioModel") ?? lmStudioModel
        anthropicModel = defaults.string(forKey: "anthropicModel") ?? anthropicModel
        openAIBaseURL = defaults.string(forKey: "openAIBaseURL") ?? openAIBaseURL
        openAIModel = defaults.string(forKey: "openAIModel") ?? openAIModel
        includeTerminalContext = defaults.bool(forKey: "aiIncludeTerminalContext")
    }
    
    func setAI(_ ai: AIType) {
        guard selectedAI != ai else { return }
        selectedAI = ai
        defaults.set(ai.rawValue, forKey: "selectedAI")
    }
    
    func setLMStudioURL(_ url: String) {
        guard lmStudioURL != url else { return }
        lmStudioURL = url
        defaults.set(url, forKey: "lmStudioURL")
    }
    
    func setLMStudioModel(_ model: String) {
        guard lmStudioModel != model else { return }
        lmStudioModel = model
        defaults.set(model, forKey: "lmStudioModel")
    }
    
    /// Persists the text-field settings (called when the settings pane closes or the user taps Save).
    func saveProviderSettings(anthropicModel: String, openAIBaseURL: String, openAIModel: String, includeContext: Bool) {
        self.anthropicModel = anthropicModel
        self.openAIBaseURL = openAIBaseURL
        self.openAIModel = openAIModel
        includeTerminalContext = includeContext
        defaults.set(anthropicModel, forKey: "anthropicModel")
        defaults.set(openAIBaseURL, forKey: "openAIBaseURL")
        defaults.set(openAIModel, forKey: "openAIModel")
        defaults.set(includeContext, forKey: "aiIncludeTerminalContext")
    }
    
    // MARK: - API keys
    
    func apiKey(for type: AIType) -> String? {
        type.keyAccount.flatMap { KeychainHelper.shared.secret(account: $0) }
    }
    
    func hasAPIKey(for type: AIType) -> Bool { apiKey(for: type)?.isEmpty == false }
    
    @discardableResult
    func setAPIKey(_ key: String, for type: AIType) -> Bool {
        guard let account = type.keyAccount else { return false }
        let trimmed = key.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return KeychainHelper.shared.deleteSecret(account: account) }
        return KeychainHelper.shared.saveSecret(trimmed, account: account)
    }
    
    // MARK: - Provider
    
    func makeProvider() throws -> AIProvider {
        switch selectedAI {
        case .builtIn:
            return BuiltInHelpProvider()
        case .anthropic:
            guard let key = apiKey(for: .anthropic) else {
                throw AIError(message: "No Anthropic API key set. Add one in Preferences > AI.")
            }
            let model = anthropicModel.trimmingCharacters(in: .whitespaces)
            return AnthropicProvider(apiKey: key, model: model.isEmpty ? "claude-sonnet-5-5" : model)
        case .openAICompatible:
            return OpenAICompatibleProvider(
                baseURL: openAIBaseURL, apiKey: apiKey(for: .openAICompatible),
                model: openAIModel, displayName: "OpenAI-compatible server")
        case .lmStudio:
            return OpenAICompatibleProvider(
                baseURL: lmStudioURL, apiKey: nil, model: lmStudioModel, displayName: "LM Studio")
        }
    }
}
