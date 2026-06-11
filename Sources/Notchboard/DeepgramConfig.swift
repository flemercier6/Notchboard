import Foundation

/// Configuration for meeting transcription (Deepgram).
///
/// The API key is read from a local file (never in source/git):
///   ~/Library/Application Support/Notchboard/deepgram-api-key   (one line)
/// or from the DEEPGRAM_API_KEY environment variable.
enum DeepgramConfig {
    /// Deepgram model. Change if you prefer another (e.g. "nova-3").
    static let model = "nova-2"

    static var apiKeyFileURL: URL {
        ShelfPersistence.directory.appendingPathComponent("deepgram-api-key")
    }

    static var apiKey: String? {
        if let raw = try? String(contentsOf: apiKeyFileURL, encoding: .utf8) {
            let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if !trimmed.isEmpty { return trimmed }
        }
        if let env = ProcessInfo.processInfo.environment["DEEPGRAM_API_KEY"], !env.isEmpty {
            return env
        }
        return nil
    }

    static var isConfigured: Bool { apiKey != nil }
}
