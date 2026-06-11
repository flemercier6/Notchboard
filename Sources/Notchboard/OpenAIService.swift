import Foundation

/// Sends a question to OpenAI (ChatGPT) and publishes the answer for the
/// Spotlight-style "Ask AI" mode of the search bar.
@MainActor
final class OpenAIService: ObservableObject {
    @Published private(set) var answer = ""
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private var task: Task<Void, Never>?

    func reset() {
        task?.cancel()
        task = nil
        answer = ""
        errorMessage = nil
        isLoading = false
    }

    func ask(_ prompt: String) {
        let question = prompt.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty else { return }

        task?.cancel()
        answer = ""
        errorMessage = nil
        isLoading = true
        task = Task { @MainActor in
            defer { isLoading = false }
            do {
                guard let key = OpenAIConfig.apiKey else {
                    throw DriveError.message("Add your OpenAI API key to the Notchboard support folder (file named “openai-api-key”).")
                }
                var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
                req.httpMethod = "POST"
                req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
                req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                let body: [String: Any] = [
                    "model": OpenAIConfig.model,
                    "messages": [["role": "user", "content": question]],
                ]
                req.httpBody = try JSONSerialization.data(withJSONObject: body)

                let (data, resp) = try await URLSession.shared.data(for: req)
                guard !Task.isCancelled else { return }
                guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
                    throw DriveError.message(Self.apiError(from: data) ?? "OpenAI request failed.")
                }
                let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
                answer = decoded.choices.first?.message.content ?? "(no answer)"
                errorMessage = nil
            } catch is CancellationError {
                // Superseded.
            } catch {
                errorMessage = (error as? DriveError)?.text ?? error.localizedDescription
            }
        }
    }

    /// One-shot completion that returns the answer (used for meeting summaries).
    /// `reasoningEffort` ("minimal"/"low"/…) and `maxTokens` cut latency on
    /// gpt-5-family models; they're omitted when nil.
    static func complete(
        _ prompt: String,
        reasoningEffort: String? = nil,
        maxTokens: Int? = nil
    ) async throws -> String {
        guard let key = OpenAIConfig.apiKey else {
            throw DriveError.message("Add your OpenAI API key to summarize (file “openai-api-key”).")
        }
        var req = URLRequest(url: URL(string: "https://api.openai.com/v1/chat/completions")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        var body: [String: Any] = [
            "model": OpenAIConfig.model,
            "messages": [["role": "user", "content": prompt]],
        ]
        if let reasoningEffort { body["reasoning_effort"] = reasoningEffort }
        if let maxTokens { body["max_completion_tokens"] = maxTokens }
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else {
            throw DriveError.message(apiError(from: data) ?? "OpenAI request failed.")
        }
        let decoded = try JSONDecoder().decode(ChatResponse.self, from: data)
        return decoded.choices.first?.message.content ?? ""
    }

    private static func apiError(from data: Data) -> String? {
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let err = obj["error"] as? [String: Any],
              let message = err["message"] as? String else { return nil }
        return message
    }
}

private struct ChatResponse: Decodable {
    struct Choice: Decodable { let message: Message }
    struct Message: Decodable { let content: String }
    let choices: [Choice]
}
