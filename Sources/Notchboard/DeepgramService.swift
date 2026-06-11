import Foundation

/// One timestamped chunk of speech.
struct Utterance {
    let start: Double
    let text: String
}

/// Pre-recorded (batch) transcription via Deepgram.
enum DeepgramService {
    static func transcribe(fileURL: URL) async throws -> [Utterance] {
        guard let key = DeepgramConfig.apiKey else {
            throw DriveError.message("Add your Deepgram API key to the Notchboard support folder (file “deepgram-api-key”).")
        }
        guard let fileSize = try? FileManager.default.attributesOfItem(atPath: fileURL.path)[.size] as? Int,
              fileSize > 1024 else {
            return []   // empty/near-empty stream (e.g. nobody spoke)
        }

        var comps = URLComponents(string: "https://api.deepgram.com/v1/listen")!
        comps.queryItems = [
            URLQueryItem(name: "model", value: DeepgramConfig.model),
            URLQueryItem(name: "smart_format", value: "true"),
            URLQueryItem(name: "punctuate", value: "true"),
            URLQueryItem(name: "utterances", value: "true"),
        ]
        var req = URLRequest(url: comps.url!)
        req.httpMethod = "POST"
        req.setValue("Token \(key)", forHTTPHeaderField: "Authorization")
        req.setValue("audio/wav", forHTTPHeaderField: "Content-Type")

        let (data, resp) = try await URLSession.shared.upload(for: req, fromFile: fileURL)
        guard let http = resp as? HTTPURLResponse else {
            throw DriveError.message("Deepgram: no response.")
        }
        guard http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DriveError.message("Deepgram request failed (\(http.statusCode)). \(body)")
        }
        let decoded = try JSONDecoder().decode(DeepgramResponse.self, from: data)
        return (decoded.results.utterances ?? []).map { Utterance(start: $0.start, text: $0.transcript) }
    }
}

private struct DeepgramResponse: Decodable {
    struct Results: Decodable { let utterances: [Utt]? }
    struct Utt: Decodable { let start: Double; let transcript: String }
    let results: Results
}
