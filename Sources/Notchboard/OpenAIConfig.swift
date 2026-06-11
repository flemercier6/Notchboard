import Foundation

/// Configuration for the "Ask AI" feature (OpenAI / ChatGPT).
///
/// The API key is read from a local file so it never lives in source/git:
///   ~/Library/Application Support/Notchboard/openai-api-key   (one line)
/// or from the OPENAI_API_KEY environment variable.
enum OpenAIConfig {
    /// The model used for answers. Change this to whatever you want to use.
    static let model = "gpt-5.5"

    static var apiKeyFileURL: URL {
        ShelfPersistence.directory.appendingPathComponent("openai-api-key")
    }

    static var apiKey: String? {
        if let raw = try? String(contentsOf: apiKeyFileURL, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let env = ProcessInfo.processInfo.environment["OPENAI_API_KEY"], !env.isEmpty {
            return env
        }
        return nil
    }

    static var isConfigured: Bool { apiKey != nil }
}
