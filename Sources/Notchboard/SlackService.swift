import AppKit
import Foundation

/// A newly-received Slack message worth flashing a notification for.
struct SlackMessage: Equatable, Identifiable {
    let id: String
    let title: String   // "Workspace · #channel" or "Workspace · Sender"
    let text: String
    /// How many new messages arrived in this poll cycle (for the badge pastille).
    let count: Int
    /// Where the newest message came from — so the banner can open that channel.
    let teamId: String
    let channelId: String

    /// Deep link that opens this conversation in the Slack app.
    var openURL: URL? { URL(string: "slack://channel?team=\(teamId)&id=\(channelId)") }
}

/// A Slack channel surfaced in universal search; opens the Slack app deep link.
struct SlackChannel: Identifiable, Equatable {
    let id: String
    let teamId: String
    let teamName: String
    let name: String
    var openURL: URL? { URL(string: "slack://channel?team=\(teamId)&id=\(id)") }
}

/// One connected Slack workspace (one OAuth install / user token).
struct SlackWorkspace: Codable, Identifiable, Equatable {
    var teamId: String
    var teamName: String
    var userId: String
    var userToken: String   // xoxp- user token
    var id: String { teamId }
}

/// Lets each user connect their own Slack workspace(s) via OAuth and surfaces new
/// messages from all of them in one place. Slack disables Socket Mode and RTM for
/// distributed apps, so real-time across arbitrary workspaces isn't possible
/// purely client-side — we poll the Web API on an interval instead.
@MainActor
final class SlackService: ObservableObject {
    @Published var incoming: SlackMessage?
    @Published private(set) var workspaces: [SlackWorkspace] = []
    @Published var lastError: String?
    @Published private(set) var isConnecting = false
    /// Recent Slack notifications for the Dash "Notifications" section.
    @Published private(set) var feed: [AppNotification] = []
    /// The user's channels across all workspaces — for universal search.
    @Published private(set) var channels: [SlackChannel] = []

    private let session = URLSession(configuration: .default)
    private var pollTask: Task<Void, Never>?

    /// teamId → (conversationId → most-recent message ts we've already seen).
    private var lastSeen: [String: [String: String]] = [:]
    /// teamId → cached conversation list, refreshed periodically.
    private var convCache: [String: [Conversation]] = [:]
    private var convRefreshedAt: [String: Date] = [:]
    /// teamId → (userId → (name, avatar URL)) cache.
    private var userInfos: [String: [String: (name: String, avatar: URL?)]] = [:]

    private let pollInterval: UInt64 = 30_000_000_000   // 30s
    private let convTTL: TimeInterval = 300              // refresh conv list every 5 min
    private let maxConversationsPerPoll = 40             // bound API calls / rate limits

    private struct Conversation {
        let id: String
        let name: String?    // channel name (nil for IMs)
        let isIM: Bool
        let user: String?    // other user (for IMs)
    }

    var isConfigured: Bool { SlackOAuthConfig.isConfigured }

    private static var storeURL: URL {
        ShelfPersistence.directory.appendingPathComponent("slack-workspaces.json")
    }

    init() { load() }

    func start() {
        guard !workspaces.isEmpty else { return }
        startPolling()
    }

    // MARK: - OAuth connect / disconnect

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }

        do {
            guard SlackOAuthConfig.isConfigured else {
                throw SlackError.message("Slack isn't configured in this build. Set SlackOAuthConfig (client id/secret + hosted redirect URL), then rebuild.")
            }
            let state = Self.randomString(24)
            let server = LoopbackServer()
            _ = try await server.start(port: SlackOAuthConfig.redirectPort)

            var comps = URLComponents(string: "https://slack.com/oauth/v2/authorize")!
            comps.queryItems = [
                .init(name: "client_id", value: SlackOAuthConfig.clientId),
                .init(name: "user_scope", value: SlackOAuthConfig.userScopes.joined(separator: ",")),
                .init(name: "redirect_uri", value: SlackOAuthConfig.redirectURI),
                .init(name: "state", value: state),
            ]
            guard let authURL = comps.url else { throw SlackError.message("Could not build the Slack sign-in URL") }
            NSWorkspace.shared.open(authURL)

            let params = try await server.waitForCallback()
            if let err = params["error"] { throw SlackError.message("Slack authorization denied (\(err))") }
            guard params["state"] == state else { throw SlackError.message("State mismatch — please retry") }
            guard let code = params["code"] else { throw SlackError.message("No authorization code received") }

            try await exchangeCode(code)
        } catch {
            lastError = (error as? SlackError)?.text ?? error.localizedDescription
        }
    }

    func disconnect(_ teamId: String) {
        workspaces.removeAll { $0.teamId == teamId }
        lastSeen[teamId] = nil
        convCache[teamId] = nil
        convRefreshedAt[teamId] = nil
        userInfos[teamId] = nil
        feed.removeAll { $0.id.hasPrefix("slack-\(teamId)-") }
        rebuildChannels()
        save()
        if workspaces.isEmpty { pollTask?.cancel(); pollTask = nil }
    }

    private func exchangeCode(_ code: String) async throws {
        // Token exchange runs server-side (oauth-proxy) so the client secret
        // never ships in the app.
        let (data, _) = try await OAuthProxy.send([
            "provider": "slack",
            "action": "exchange",
            "code": code,
            "redirect_uri": SlackOAuthConfig.redirectURI,
        ])
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw SlackError.message("Couldn't read Slack's response.")
        }
        guard obj["ok"] as? Bool == true else {
            throw SlackError.message("Slack token exchange failed: \(obj["error"] as? String ?? "unknown")")
        }
        guard let authedUser = obj["authed_user"] as? [String: Any],
              let userToken = authedUser["access_token"] as? String,
              let userId = authedUser["id"] as? String,
              let team = obj["team"] as? [String: Any],
              let teamId = team["id"] as? String else {
            throw SlackError.message("Slack didn't return a user token. Make sure user scopes are configured.")
        }
        let teamName = (team["name"] as? String) ?? "Slack"
        let workspace = SlackWorkspace(teamId: teamId, teamName: teamName, userId: userId, userToken: userToken)

        // Replace any existing install for the same team, else append.
        if let idx = workspaces.firstIndex(where: { $0.teamId == teamId }) {
            workspaces[idx] = workspace
        } else {
            workspaces.append(workspace)
        }
        save()
        startPolling()
    }

    // MARK: - Polling

    private func startPolling() {
        pollTask?.cancel()
        pollTask = Task { @MainActor in
            // Prime each workspace so we only notify on messages from now on.
            for ws in workspaces { await prime(ws) }
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: pollInterval)
                guard !Task.isCancelled else { break }
                for ws in workspaces { await poll(ws) }
            }
        }
    }

    /// Load the conversation list and record each one's latest ts without emitting
    /// — so a freshly-connected workspace doesn't flood with old messages.
    private func prime(_ ws: SlackWorkspace) async {
        let convs = await conversations(ws)
        var seen: [String: String] = [:]
        for conv in convs.prefix(maxConversationsPerPoll) {
            if let latest = await latestTs(ws, conversation: conv.id) { seen[conv.id] = latest }
        }
        lastSeen[ws.teamId] = seen
    }

    private func poll(_ ws: SlackWorkspace) async {
        let convs = await conversations(ws)
        var seen = lastSeen[ws.teamId] ?? [:]
        // Collect new qualifying messages first, then resolve senders.
        var collected: [(ts: String, user: String, text: String, conv: Conversation)] = []

        for conv in convs.prefix(maxConversationsPerPoll) {
            let since = seen[conv.id]
            let messages = await history(ws, conversation: conv.id, oldest: since)
            for msg in messages {
                guard let ts = msg["ts"] as? String else { continue }
                if let since, ts <= since { continue }
                if ts > (seen[conv.id] ?? "") { seen[conv.id] = ts }
                // Skip our own messages, bots and non-message subtypes.
                if msg["subtype"] != nil || msg["bot_id"] != nil { continue }
                guard let user = msg["user"] as? String, user != ws.userId else { continue }
                guard let text = msg["text"] as? String, !text.isEmpty else { continue }
                collected.append((ts: ts, user: user, text: text, conv: conv))
            }
            // Spread calls a little to stay under rate limits.
            try? await Task.sleep(nanoseconds: 150_000_000)
        }
        lastSeen[ws.teamId] = seen
        guard !collected.isEmpty else { return }

        collected.sort { $0.ts < $1.ts }   // oldest first → newest ends on top of feed

        var newestTitle = ""
        var newestText = ""
        var newestTs = ""
        var newestChannelId = ""
        for item in collected {
            let info = await userInfo(ws, id: item.user)
            let note = AppNotification(
                id: "slack-\(ws.teamId)-\(item.ts)",
                source: .slack,
                sender: info.name,
                preview: item.text,
                avatarURL: info.avatar,
                date: Date()
            )
            feed.removeAll { $0.id == note.id }
            feed.insert(note, at: 0)

            let context = item.conv.isIM ? info.name : "#\(item.conv.name ?? "channel")"
            newestTitle = "\(ws.teamName) · \(context)"
            newestText = item.text
            newestTs = item.ts
            newestChannelId = item.conv.id
        }
        if feed.count > 50 { feed = Array(feed.prefix(50)) }

        incoming = SlackMessage(id: "\(ws.teamId)-\(newestTs)",
                                title: newestTitle,
                                text: newestText,
                                count: collected.count,
                                teamId: ws.teamId,
                                channelId: newestChannelId)
    }

    // MARK: - Web API helpers

    private func conversations(_ ws: SlackWorkspace) async -> [Conversation] {
        if let cached = convCache[ws.teamId],
           let at = convRefreshedAt[ws.teamId], Date().timeIntervalSince(at) < convTTL {
            return cached
        }
        var comps = URLComponents(string: "https://slack.com/api/users.conversations")!
        comps.queryItems = [
            .init(name: "types", value: "public_channel,private_channel,im,mpim"),
            .init(name: "exclude_archived", value: "true"),
            .init(name: "limit", value: "200"),
        ]
        guard let obj = await get(ws, comps: comps),
              let list = obj["channels"] as? [[String: Any]] else {
            return convCache[ws.teamId] ?? []
        }
        let convs: [Conversation] = list.compactMap { c in
            guard let id = c["id"] as? String else { return nil }
            let isIM = (c["is_im"] as? Bool) ?? false
            return Conversation(id: id,
                                name: c["name"] as? String,
                                isIM: isIM,
                                user: c["user"] as? String)
        }
        convCache[ws.teamId] = convs
        convRefreshedAt[ws.teamId] = Date()
        rebuildChannels()
        return convs
    }

    func open(_ channel: SlackChannel) {
        if let url = channel.openURL { NSWorkspace.shared.open(url) }
    }

    /// Make sure the channel list is populated (e.g. when universal search opens).
    func ensureChannelsLoaded() {
        guard channels.isEmpty, !workspaces.isEmpty else { return }
        Task { @MainActor in
            for ws in workspaces { _ = await conversations(ws) }
        }
    }

    private func rebuildChannels() {
        var result: [SlackChannel] = []
        for ws in workspaces {
            for conv in convCache[ws.teamId] ?? [] where !conv.isIM {
                guard let name = conv.name else { continue }
                result.append(SlackChannel(id: conv.id, teamId: ws.teamId,
                                           teamName: ws.teamName, name: name))
            }
        }
        channels = result
    }

    private func latestTs(_ ws: SlackWorkspace, conversation: String) async -> String? {
        let messages = await history(ws, conversation: conversation, oldest: nil, limit: 1)
        return messages.first?["ts"] as? String
    }

    private func history(_ ws: SlackWorkspace, conversation: String,
                         oldest: String?, limit: Int = 5) async -> [[String: Any]] {
        var comps = URLComponents(string: "https://slack.com/api/conversations.history")!
        var items: [URLQueryItem] = [
            .init(name: "channel", value: conversation),
            .init(name: "limit", value: String(limit)),
        ]
        if let oldest { items.append(.init(name: "oldest", value: oldest)) }
        comps.queryItems = items
        guard let obj = await get(ws, comps: comps),
              let messages = obj["messages"] as? [[String: Any]] else { return [] }
        return messages
    }

    private func userInfo(_ ws: SlackWorkspace, id: String) async -> (name: String, avatar: URL?) {
        if let cached = userInfos[ws.teamId]?[id] { return cached }
        var comps = URLComponents(string: "https://slack.com/api/users.info")!
        comps.queryItems = [.init(name: "user", value: id)]
        guard let obj = await get(ws, comps: comps),
              let user = obj["user"] as? [String: Any] else { return ("Someone", nil) }
        let profile = user["profile"] as? [String: Any]
        let name = (profile?["display_name"] as? String).flatMap { $0.isEmpty ? nil : $0 }
            ?? (user["real_name"] as? String)
            ?? (user["name"] as? String)
            ?? "Someone"
        let avatar = (profile?["image_72"] as? String).flatMap(URL.init(string:))
            ?? (profile?["image_48"] as? String).flatMap(URL.init(string:))
        let info = (name: name, avatar: avatar)
        userInfos[ws.teamId, default: [:]][id] = info
        return info
    }

    private func get(_ ws: SlackWorkspace, comps: URLComponents) async -> [String: Any]? {
        guard let url = comps.url else { return nil }
        var req = URLRequest(url: url)
        req.setValue("Bearer \(ws.userToken)", forHTTPHeaderField: "Authorization")
        guard let (data, _) = try? await session.data(for: req),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        if obj["ok"] as? Bool == false {
            // Token revoked / app uninstalled → drop this workspace.
            if let err = obj["error"] as? String,
               err == "token_revoked" || err == "account_inactive" || err == "invalid_auth" {
                disconnect(ws.teamId)
            }
            return nil
        }
        return obj
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.storeURL),
              let decoded = try? JSONDecoder().decode([SlackWorkspace].self, from: data) else { return }
        workspaces = decoded
    }

    private func save() {
        guard let data = try? JSONEncoder().encode(workspaces) else { return }
        try? data.write(to: Self.storeURL)
    }

    // MARK: - Utilities

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    private static func formEncode(_ params: [String: String]) -> String {
        let allowed = CharacterSet(charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return params.map { key, value in
            "\(key)=\(value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value)"
        }.joined(separator: "&")
    }
}

private enum SlackError: Error {
    case message(String)
    var text: String { if case .message(let m) = self { return m }; return "Slack error" }
}

/// The bundled Slack logo (slacklogo.png in Resources), if present.
enum SlackAssets {
    static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "slacklogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
