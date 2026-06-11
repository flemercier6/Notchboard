import AppKit
import Foundation

/// Persisted Notion OAuth token (Notion access tokens don't expire — no refresh).
struct NotionTokens: Codable {
    var accessToken: String
    var workspaceName: String?
}

/// Manages the Notion OAuth 2.0 (authorization-code) flow and hands out the
/// access token. Each user connects their own Notion workspace.
@MainActor
final class NotionAuth: ObservableObject {
    @Published private(set) var isConnected = false
    @Published var lastError: String?
    @Published private(set) var isConnecting = false

    private var tokens: NotionTokens? {
        didSet { isConnected = tokens != nil }
    }

    private static var tokensURL: URL {
        ShelfPersistence.directory.appendingPathComponent("notion-tokens.json")
    }

    init() { load() }

    var isConfigured: Bool { NotionOAuthConfig.isConfigured }
    var accessToken: String? { tokens?.accessToken }
    var workspaceName: String? { tokens?.workspaceName }

    // MARK: - Connect / disconnect

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }

        do {
            guard NotionOAuthConfig.isConfigured else {
                throw NotionError.message("Notion isn't configured in this build. Set NotionOAuthConfig (client id/secret + hosted redirect URL), then rebuild.")
            }
            let state = Self.randomString(24)
            let server = LoopbackServer()
            _ = try await server.start(port: NotionOAuthConfig.redirectPort)

            var comps = URLComponents(string: "https://api.notion.com/v1/oauth/authorize")!
            comps.queryItems = [
                .init(name: "client_id", value: NotionOAuthConfig.clientId),
                .init(name: "response_type", value: "code"),
                .init(name: "owner", value: "user"),
                .init(name: "redirect_uri", value: NotionOAuthConfig.redirectURI),
                .init(name: "state", value: state),
            ]
            guard let url = comps.url else { throw NotionError.message("Couldn't build the Notion sign-in URL") }
            NSWorkspace.shared.open(url)

            let params = try await server.waitForCallback()
            if let err = params["error"] { throw NotionError.message("Notion authorization denied (\(err))") }
            guard params["state"] == state else { throw NotionError.message("State mismatch — please retry") }
            guard let code = params["code"] else { throw NotionError.message("No authorization code received") }

            try await exchangeCode(code)
        } catch {
            lastError = (error as? NotionError)?.text ?? error.localizedDescription
        }
    }

    func disconnect() {
        tokens = nil
        try? FileManager.default.removeItem(at: Self.tokensURL)
    }

    private func exchangeCode(_ code: String) async throws {
        // Token exchange runs server-side (oauth-proxy) so the client secret
        // never ships in the app.
        let (data, http) = try await OAuthProxy.send([
            "provider": "notion",
            "action": "exchange",
            "code": code,
            "redirect_uri": NotionOAuthConfig.redirectURI,
        ])
        guard http.statusCode == 200,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let token = obj["access_token"] as? String else {
            let bodyText = String(data: data, encoding: .utf8) ?? ""
            throw NotionError.message("Notion token request failed. \(bodyText)")
        }
        tokens = NotionTokens(accessToken: token, workspaceName: obj["workspace_name"] as? String)
        save()
    }

    // MARK: - Persistence

    private func load() {
        guard let data = try? Data(contentsOf: Self.tokensURL) else { return }
        tokens = try? JSONDecoder().decode(NotionTokens.self, from: data)
    }

    private func save() {
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: Self.tokensURL)
    }

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789")
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }
}

private enum NotionError: Error {
    case message(String)
    var text: String { if case .message(let m) = self { return m }; return "Notion error" }
}
