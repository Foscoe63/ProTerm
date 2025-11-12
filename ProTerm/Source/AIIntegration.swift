import Foundation
import SwiftUI

/*
   Placeholder for macOS 26 built‑in AI (Apple Intelligence).
   The real API is expected to expose a class like `AIAssistant` with a
   `perform(prompt:completion:)` method. Until the SDK ships, this stub mimics
   that behavior using a local mock implementation.
*/

final class AIIntegration {
    static let shared = AIIntegration()

    private init() {}

    /// Sends a prompt to the system‑wide AI and returns the result asynchronously.
    ///
    /// The `completion` closure is marked **@Sendable** so it can be captured by
    /// the `DispatchQueue.global().asyncAfter` closure, which is itself a
    /// `@Sendable` context in Swift 6.2.
    func ask(
        _ prompt: String,
        completion: @escaping @Sendable (Result<String, any Error>) -> Void
    ) {
        // MARK: –‑ Future real implementation
        // Example (hypothetical):
        // AIAssistant.shared.perform(prompt: prompt) { result in
        //     completion(result)
        // }
        // ---------------------------------------------------
        // Temporary mock implementation:
        DispatchQueue.global().asyncAfter(deadline: .now() + 0.5) {
            let mock = "[AI] You asked: \(prompt). This is a placeholder response."
            completion(.success(mock))
        }
    }
}
