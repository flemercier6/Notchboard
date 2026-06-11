import Foundation

/// A batch of newly-received emails worth flashing a notification for.
struct IncomingEmail: Identifiable, Equatable {
    /// The latest message id (used for view identity / uniqueness).
    let id: String
    /// How many new inbox messages arrived since the last check.
    let count: Int
}

/// Polls Gmail for newly-arrived inbox messages and publishes how many showed up
/// so the UI can flash a notification. One list request per tick, only while
/// connected with the Gmail scope.
@MainActor
final class GmailNotifier: ObservableObject {
    @Published var incoming: IncomingEmail?
    /// Recent email notifications for the Dash "Notifications" section.
    @Published private(set) var feed: [AppNotification] = []

    private let auth: GoogleDriveAuth
    private var pollTask: Task<Void, Never>?
    private var lastSeenId: String?
    private let interval: UInt64 = 20_000_000_000   // 20s

    init(auth: GoogleDriveAuth) { self.auth = auth }

    func start() {
        guard pollTask == nil else { return }
        pollTask = Task { @MainActor in
            while !Task.isCancelled {
                await poll()
                try? await Task.sleep(nanoseconds: interval)
            }
        }
    }

    func stop() {
        pollTask?.cancel()
        pollTask = nil
    }

    private func poll() async {
        guard auth.isConnected, auth.hasScope(GoogleScopes.gmail) else {
            // Reset baseline so a later (re)connect doesn't flash a backlog.
            lastSeenId = nil
            return
        }
        do {
            let token = try await auth.accessToken()
            let ids = try await latestInboxIds(token: token)
            guard let latestId = ids.first else { return }
            guard latestId != lastSeenId else { return }

            let previous = lastSeenId
            lastSeenId = latestId
            // Don't notify on the very first observation — that's just the baseline.
            guard let previous else { return }

            // New messages = those ahead of the previously-seen one in the list.
            let newIds: [String]
            if let index = ids.firstIndex(of: previous) {
                newIds = Array(ids.prefix(max(index, 1)))
            } else {
                newIds = ids   // more new than we fetched
            }
            incoming = IncomingEmail(id: latestId, count: newIds.count)

            // Enrich the newest few for the notifications feed (oldest first so
            // the newest ends up on top after prepending).
            for id in newIds.prefix(8).reversed() {
                guard let meta = await fetchMeta(id: id, token: token) else { continue }
                let note = AppNotification(
                    id: "gmail-\(id)",
                    source: .gmail,
                    sender: meta.from,
                    preview: meta.subject,
                    avatarURL: nil,
                    date: Date()
                )
                feed.removeAll { $0.id == note.id }
                feed.insert(note, at: 0)
            }
            if feed.count > 50 { feed = Array(feed.prefix(50)) }
        } catch {
            // Transient error — try again next tick.
        }
    }

    /// Fetches a message's sender + subject for the notifications feed.
    private func fetchMeta(id: String, token: String) async -> (from: String, subject: String)? {
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages/\(id)")!
        comps.queryItems = [
            URLQueryItem(name: "format", value: "metadata"),
            URLQueryItem(name: "metadataHeaders", value: "Subject"),
            URLQueryItem(name: "metadataHeaders", value: "From"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        guard let (data, resp) = try? await URLSession.shared.data(for: req),
              (resp as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        struct Detail: Decodable {
            struct Payload: Decodable {
                struct Header: Decodable { let name: String; let value: String }
                let headers: [Header]?
            }
            let payload: Payload?
        }
        guard let detail = try? JSONDecoder().decode(Detail.self, from: data) else { return nil }
        let headers = detail.payload?.headers ?? []
        func header(_ name: String) -> String {
            headers.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }?.value ?? ""
        }
        let subject = header("Subject")
        return (from: Self.displayName(from: header("From")),
                subject: subject.isEmpty ? "(no subject)" : subject)
    }

    /// "Jane Doe <jane@x.com>" → "Jane Doe"; bare addresses pass through.
    private static func displayName(from raw: String) -> String {
        if let bracket = raw.firstIndex(of: "<") {
            let name = raw[..<bracket]
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            if !name.isEmpty { return name }
        }
        return raw
    }

    private func latestInboxIds(token: String) async throws -> [String] {
        var comps = URLComponents(string: "https://gmail.googleapis.com/gmail/v1/users/me/messages")!
        comps.queryItems = [
            URLQueryItem(name: "maxResults", value: "20"),
            URLQueryItem(name: "q", value: "in:inbox"),
        ]
        var req = URLRequest(url: comps.url!)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard (resp as? HTTPURLResponse)?.statusCode == 200 else { return [] }
        struct List: Decodable {
            struct Ref: Decodable { let id: String }
            let messages: [Ref]?
        }
        return ((try? JSONDecoder().decode(List.self, from: data))?.messages ?? []).map(\.id)
    }
}
