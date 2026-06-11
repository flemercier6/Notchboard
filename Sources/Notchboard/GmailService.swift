import Foundation

/// A single Gmail message (metadata only).
struct GmailMessage: Identifiable {
    let id: String
    let from: String
    let subject: String
    let snippet: String
}

private struct GmailListResponse: Decodable {
    struct Ref: Decodable { let id: String }
    let messages: [Ref]?
}

private struct GmailMessageResponse: Decodable {
    let snippet: String?
    let payload: Payload?
    struct Payload: Decodable { let headers: [Header]? }
    struct Header: Decodable { let name: String; let value: String }
}

/// Lists and searches the connected account's Gmail. Clicking a result opens it
/// in the browser (handled by the view).
@MainActor
final class GmailService: ObservableObject {
    @Published private(set) var messages: [GmailMessage] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let auth: GoogleDriveAuth
    private var queryTask: Task<Void, Never>?

    init(auth: GoogleDriveAuth) { self.auth = auth }

    /// Default view: the 10 most recent inbox emails.
    func loadRecent() { run(query: "in:inbox", maxResults: 10) }

    /// Searching is not capped to the recent 10 — find any email across the
    /// whole mailbox (Gmail search syntax supported).
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { loadRecent(); return }
        run(query: trimmed, maxResults: 50)
    }

    private func run(query: String, maxResults: Int) {
        queryTask?.cancel()
        queryTask = Task { @MainActor in
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            isLoading = true
            defer { isLoading = false }
            do {
                let token = try await auth.accessToken()
                guard !Task.isCancelled else { return }

                var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
                comps.queryItems = [
                    URLQueryItem(name: "maxResults", value: String(maxResults)),
                    URLQueryItem(name: "q", value: query),
                ]
                var req = URLRequest(url: comps.url!)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, resp) = try await URLSession.shared.data(for: req)
                try Self.check(resp)
                let ids = (try JSONDecoder().decode(GmailListResponse.self, from: data).messages ?? []).map(\.id)
                guard !Task.isCancelled else { return }

                // Fetch each message's headers concurrently, then restore order.
                var fetched: [GmailMessage] = []
                try await withThrowingTaskGroup(of: GmailMessage?.self) { group in
                    for id in ids {
                        group.addTask { try await Self.fetchMessage(id: id, token: token) }
                    }
                    for try await message in group {
                        if let message { fetched.append(message) }
                    }
                }
                guard !Task.isCancelled else { return }

                let order = Dictionary(uniqueKeysWithValues: ids.enumerated().map { ($1, $0) })
                messages = fetched.sorted { (order[$0.id] ?? 0) < (order[$1.id] ?? 0) }
                errorMessage = nil
            } catch is CancellationError {
                // Superseded by a newer query.
            } catch {
                errorMessage = (error as? DriveError)?.text ?? error.localizedDescription
            }
        }
    }

    private nonisolated static func fetchMessage(id: String, token: String) async throws -> GmailMessage? {
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        try check(resp)

        let detail = try JSONDecoder().decode(GmailMessageResponse.self, from: data)
        let headers = detail.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        let subject = header("Subject")
        return GmailMessage(
            id: id,
            from: displayName(from: header("From")),
            subject: subject.isEmpty ? "(no subject)" : subject,
            snippet: (detail.snippet ?? "").decodedHTMLEntities()
        )
    }

    /// "Jane Doe <jane@x.com>" → "Jane Doe"; bare addresses pass through.
    private nonisolated static func displayName(from raw: String) -> String {
        if let bracket = raw.firstIndex(of: "<") {
            let name = raw[..<bracket]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
        }
        return raw
    }

    private nonisolated static func check(_ resp: URLResponse) throws {
        guard let http = resp as? HTTPURLResponse else { return }
        switch http.statusCode {
        case 200:
            return
        case 403:
            throw DriveError.message("Gmail access denied. Enable the Gmail API in Google Cloud Console and reconnect your account (Settings → Disconnect, then Connect).")
        default:
            throw DriveError.message("Gmail request failed (\(http.statusCode)).")
        }
    }
}

private extension String {
    /// Gmail snippets arrive with a few HTML entities (e.g. &amp;, &#39;).
    func decodedHTMLEntities() -> String {
        replacingOccurrences(of: "&amp;", with: "&")
            .replacingOccurrences(of: "&#39;", with: "'")
            .replacingOccurrences(of: "&quot;", with: "\"")
            .replacingOccurrences(of: "&lt;", with: "<")
            .replacingOccurrences(of: "&gt;", with: ">")
            .replacingOccurrences(of: "&nbsp;", with: " ")
    }
}
