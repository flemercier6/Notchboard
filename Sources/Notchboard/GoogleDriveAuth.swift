import AppKit
import CryptoKit
import Foundation
import Network

/// Errors surfaced to the UI as a short message.
enum DriveError: Error {
    case message(String)
    var text: String {
        if case .message(let m) = self { return m }
        return "Something went wrong"
    }
}

/// OAuth client credentials for the Notchboard *app* (one client shared by all
/// users). Resolved from the embedded `GoogleOAuthConfig`; as a developer
/// convenience it also falls back to a `google-credentials.json` placed in the
/// support folder (the JSON downloaded from Google Cloud Console).
struct GoogleCredentials {
    let clientId: String
    let clientSecret: String

    static var fileURL: URL {
        ShelfPersistence.directory.appendingPathComponent("google-credentials.json")
    }

    static func load() -> GoogleCredentials? {
        // Preferred: the app's own embedded OAuth client → every user connects
        // their own account with no setup.
        if GoogleOAuthConfig.isConfigured {
            return GoogleCredentials(
                clientId: GoogleOAuthConfig.clientId,
                clientSecret: GoogleOAuthConfig.clientSecret
            )
        }
        // Dev fallback: read the downloaded client JSON from the support folder.
        guard let data = try? Data(contentsOf: fileURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any]
        else { return nil }
        // The downloaded file wraps everything under "installed" (or "web").
        let obj = (json["installed"] as? [String: Any]) ?? (json["web"] as? [String: Any]) ?? json
        guard let id = obj["client_id"] as? String,
              let secret = obj["client_secret"] as? String
        else { return nil }
        return GoogleCredentials(clientId: id, clientSecret: secret)
    }
}

/// OAuth scope URLs the app requests.
enum GoogleScopes {
    static let drive = "https://www.googleapis.com/auth/drive.metadata.readonly"
    static let gmail = "https://www.googleapis.com/auth/gmail.readonly"
    static let calendar = "https://www.googleapis.com/auth/calendar.readonly"
    static let all = ["openid", "email", drive, gmail, calendar].joined(separator: " ")
}

/// Persisted OAuth tokens.
struct GoogleTokens: Codable {
    var accessToken: String
    var refreshToken: String
    var expiry: Date
    var email: String?
    var scope: String?
}

private struct TokenResponse: Decodable {
    let access_token: String
    let refresh_token: String?
    let expires_in: Int?
    let scope: String?
}

/// Manages the Google OAuth 2.0 (PKCE, loopback redirect) flow for a desktop app
/// and hands out valid access tokens, refreshing as needed.
@MainActor
final class GoogleDriveAuth: ObservableObject {
    @Published private(set) var isConnected = false
    @Published private(set) var accountEmail: String?
    @Published var lastError: String?
    @Published private(set) var isConnecting = false
    @Published private(set) var grantedScopes: Set<String> = []

    private var tokens: GoogleTokens? {
        didSet {
            isConnected = tokens != nil
            accountEmail = tokens?.email
            grantedScopes = Set((tokens?.scope ?? "").split(separator: " ").map(String.init))
        }
    }

    /// Whether the current connection granted a given scope. Unknown (nil scope,
    /// e.g. a token from an older build) counts as not granted.
    func hasScope(_ scope: String) -> Bool { grantedScopes.contains(scope) }

    /// `openid`/`email` to show which account is connected, plus read-only access
    /// to Drive (metadata), Gmail and Calendar.
    private let scopes = GoogleScopes.all

    private static var tokensURL: URL {
        ShelfPersistence.directory.appendingPathComponent("google-tokens.json")
    }

    init() { loadTokens() }

    var hasCredentials: Bool { GoogleCredentials.load() != nil }

    // MARK: - Connect / disconnect

    func connect() async {
        guard !isConnecting else { return }
        isConnecting = true
        lastError = nil
        defer { isConnecting = false }

        do {
            guard let creds = GoogleCredentials.load() else {
                throw DriveError.message("Google Drive isn't configured in this build. Set GoogleOAuthConfig in the source, then rebuild.")
            }

            let verifier = Self.randomString(64)
            let challenge = Self.codeChallenge(for: verifier)
            let state = Self.randomString(24)

            let server = LoopbackServer()
            let port = try await server.start()
            let redirectURI = "http://127.0.0.1:\(port)"

            var comps = URLComponents(string: "https://accounts.google.com/o/oauth2/v2/auth")!
            comps.queryItems = [
                .init(name: "client_id", value: creds.clientId),
                .init(name: "redirect_uri", value: redirectURI),
                .init(name: "response_type", value: "code"),
                .init(name: "scope", value: scopes),
                .init(name: "code_challenge", value: challenge),
                .init(name: "code_challenge_method", value: "S256"),
                .init(name: "access_type", value: "offline"),
                .init(name: "prompt", value: "consent"),
                .init(name: "state", value: state),
            ]
            guard let authURL = comps.url else { throw DriveError.message("Could not build the sign-in URL") }
            NSWorkspace.shared.open(authURL)

            let params = try await server.waitForCallback()
            if let err = params["error"] { throw DriveError.message("Authorization denied (\(err))") }
            guard params["state"] == state else { throw DriveError.message("State mismatch — please retry") }
            guard let code = params["code"] else { throw DriveError.message("No authorization code received") }

            try await exchangeCode(code, verifier: verifier, redirectURI: redirectURI, creds: creds)
            await fetchEmail()
        } catch {
            lastError = (error as? DriveError)?.text ?? error.localizedDescription
        }
    }

    func disconnect() {
        tokens = nil
        try? FileManager.default.removeItem(at: Self.tokensURL)
    }

    /// A valid access token, refreshing via the refresh token if expired.
    func accessToken() async throws -> String {
        guard var current = tokens else { throw DriveError.message("Not connected to Google Drive") }
        if current.expiry > Date().addingTimeInterval(60) { return current.accessToken }
        guard let creds = GoogleCredentials.load() else { throw DriveError.message("Missing credentials") }

        let form = [
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "refresh_token": current.refreshToken,
            "grant_type": "refresh_token",
        ]
        let response = try await postToken(form)
        current.accessToken = response.access_token
        current.expiry = Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600))
        if let refreshed = response.refresh_token { current.refreshToken = refreshed }
        if let scope = response.scope { current.scope = scope }
        tokens = current
        saveTokens()
        return current.accessToken
    }

    // MARK: - Token exchange

    private func exchangeCode(_ code: String, verifier: String, redirectURI: String, creds: GoogleCredentials) async throws {
        let form = [
            "code": code,
            "client_id": creds.clientId,
            "client_secret": creds.clientSecret,
            "redirect_uri": redirectURI,
            "grant_type": "authorization_code",
            "code_verifier": verifier,
        ]
        let response = try await postToken(form)
        guard let refresh = response.refresh_token else {
            throw DriveError.message("No refresh token returned — remove the app from your Google account and retry.")
        }
        tokens = GoogleTokens(
            accessToken: response.access_token,
            refreshToken: refresh,
            expiry: Date().addingTimeInterval(TimeInterval(response.expires_in ?? 3600)),
            email: nil,
            scope: response.scope
        )
        saveTokens()
    }

    private func postToken(_ form: [String: String]) async throws -> TokenResponse {
        var req = URLRequest(url: URL(string: "https://oauth2.googleapis.com/token")!)
        req.httpMethod = "POST"
        req.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        req.httpBody = Self.formEncode(form).data(using: .utf8)
        let (data, resp) = try await URLSession.shared.data(for: req)
        guard let http = resp as? HTTPURLResponse, http.statusCode == 200 else {
            let body = String(data: data, encoding: .utf8) ?? ""
            throw DriveError.message("Google token request failed. \(body)")
        }
        return try JSONDecoder().decode(TokenResponse.self, from: data)
    }

    private func fetchEmail() async {
        do {
            let token = try await accessToken()
            var req = URLRequest(url: URL(string: "https://www.googleapis.com/oauth2/v2/userinfo")!)
            req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
            let (data, _) = try await URLSession.shared.data(for: req)
            if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
               let email = json["email"] as? String {
                tokens?.email = email
                saveTokens()
            }
        } catch {
            // Non-fatal — we just won't show the email.
        }
    }

    // MARK: - Persistence

    private func loadTokens() {
        guard let data = try? Data(contentsOf: Self.tokensURL) else { return }
        tokens = try? JSONDecoder().decode(GoogleTokens.self, from: data)
    }

    private func saveTokens() {
        guard let tokens, let data = try? JSONEncoder().encode(tokens) else { return }
        try? data.write(to: Self.tokensURL)
    }

    // MARK: - PKCE / encoding helpers

    private static func randomString(_ length: Int) -> String {
        let chars = Array("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~")
        return String((0..<length).compactMap { _ in chars.randomElement() })
    }

    private static func codeChallenge(for verifier: String) -> String {
        let hash = SHA256.hash(data: Data(verifier.utf8))
        return Data(hash).base64URLEncodedString()
    }

    private static func formEncode(_ params: [String: String]) -> String {
        params.map { key, value in
            let encoded = value.addingPercentEncoding(withAllowedCharacters: .urlFormValueAllowed) ?? value
            return "\(key)=\(encoded)"
        }.joined(separator: "&")
    }
}

private extension Data {
    func base64URLEncodedString() -> String {
        base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
    }
}

private extension CharacterSet {
    /// Unreserved characters per RFC 3986 — everything else gets percent-encoded.
    static let urlFormValueAllowed = CharacterSet(
        charactersIn: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~"
    )
}

/// Runs a closure at most once, thread-safely.
private final class OneShot {
    private var done = false
    private let lock = NSLock()
    func run(_ body: () -> Void) {
        lock.lock(); defer { lock.unlock() }
        guard !done else { return }
        done = true
        body()
    }
}

/// A one-shot local HTTP server that captures the OAuth redirect (the browser is
/// sent to http://127.0.0.1:<port>/?code=...). No external dependencies.
final class LoopbackServer {
    private var listener: NWListener?
    private var continuation: CheckedContinuation<[String: String], Error>?
    private let queue = DispatchQueue(label: "com.notchboard.oauth.loopback")

    /// Starts listening and returns the bound port. Pass a fixed `port` when the
    /// provider requires an exact redirect URI; omit for a random one.
    func start(port: UInt16? = nil) async throws -> UInt16 {
        let params = NWParameters.tcp
        params.allowLocalEndpointReuse = true
        let listener: NWListener
        if let port, let nwPort = NWEndpoint.Port(rawValue: port) {
            listener = try NWListener(using: params, on: nwPort)
        } else {
            listener = try NWListener(using: params)
        }
        self.listener = listener
        listener.newConnectionHandler = { [weak self] conn in self?.handle(conn) }

        return try await withCheckedThrowingContinuation { cont in
            let once = OneShot()
            listener.stateUpdateHandler = { state in
                switch state {
                case .ready:
                    once.run { cont.resume(returning: listener.port?.rawValue ?? 0) }
                case .failed(let error):
                    once.run { cont.resume(throwing: error) }
                case .cancelled:
                    once.run { cont.resume(throwing: DriveError.message("Local server cancelled")) }
                default:
                    break
                }
            }
            listener.start(queue: queue)
        }
    }

    /// Suspends until the redirect arrives, returning its query parameters.
    func waitForCallback() async throws -> [String: String] {
        try await withCheckedThrowingContinuation { cont in self.continuation = cont }
    }

    private func handle(_ conn: NWConnection) {
        conn.start(queue: queue)
        conn.receive(minimumIncompleteLength: 1, maximumLength: 16384) { [weak self] data, _, _, _ in
            guard let self else { return }
            guard let data,
                  let request = String(data: data, encoding: .utf8),
                  let requestLine = request.split(separator: "\r\n").first,
                  let path = requestLine.split(separator: " ").dropFirst().first
            else {
                conn.cancel()
                return
            }

            let params = Self.parseQuery(String(path))
            guard params["code"] != nil || params["error"] != nil else {
                // Probably a /favicon.ico request — ignore, keep waiting.
                conn.cancel()
                return
            }

            let body = """
            <html><head><meta charset="utf-8"></head>
            <body style="font-family:-apple-system,Helvetica,sans-serif;text-align:center;margin-top:80px;color:#222">
            <h2>Notchboard connected \u{2713}</h2>
            <p>You can close this tab and return to Notchboard.</p>
            </body></html>
            """
            let http = "HTTP/1.1 200 OK\r\nContent-Type: text/html; charset=utf-8\r\nContent-Length: \(body.utf8.count)\r\nConnection: close\r\n\r\n\(body)"
            conn.send(content: http.data(using: .utf8), completion: .contentProcessed { _ in conn.cancel() })

            self.continuation?.resume(returning: params)
            self.continuation = nil
            self.listener?.cancel()
            self.listener = nil
        }
    }

    private static func parseQuery(_ path: String) -> [String: String] {
        guard let query = path.split(separator: "?").dropFirst().first else { return [:] }
        var result: [String: String] = [:]
        for pair in query.split(separator: "&") {
            let kv = pair.split(separator: "=", maxSplits: 1)
            let key = String(kv[0]).removingPercentEncoding ?? String(kv[0])
            let value = kv.count > 1 ? (String(kv[1]).removingPercentEncoding ?? String(kv[1])) : ""
            result[key] = value
        }
        return result
    }
}
