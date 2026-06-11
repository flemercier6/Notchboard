import Foundation

/// Calls the `oauth-proxy` Supabase Edge Function, which performs the OAuth token
/// exchange/refresh server-side using the client secrets (kept only in the
/// backend, never in this app or the repo). The function returns the provider's
/// token response verbatim, so callers decode it exactly as before.
enum OAuthProxy {
    private static var url: URL {
        SupabaseConfig.url.appendingPathComponent("functions/v1/oauth-proxy")
    }

    /// POSTs the payload and returns the raw provider response (body + status).
    static func send(_ payload: [String: String]) async throws -> (Data, HTTPURLResponse) {
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.setValue(SupabaseConfig.publishableKey, forHTTPHeaderField: "apikey")
        req.setValue("Bearer \(SupabaseConfig.publishableKey)", forHTTPHeaderField: "Authorization")
        req.httpBody = try JSONSerialization.data(withJSONObject: payload)
        let (data, resp) = try await URLSession.shared.data(for: req)
        return (data, (resp as? HTTPURLResponse) ?? HTTPURLResponse())
    }
}
