import Foundation

/// Notchboard's Slack OAuth app — created ONCE by the developer at
/// https://api.slack.com/apps , with **public distribution enabled** so any user
/// can connect their own workspace(s). Each user then just clicks
/// "Add Slack workspace" and signs into their account.
///
/// Slack requires an **https** OAuth redirect URL (it rejects http/localhost), so
/// we register a tiny static page (see `oauth-callback/index.html`, host it on
/// GitHub Pages / Cloudflare Pages) that immediately bounces the result to the
/// app's local loopback at `http://127.0.0.1:<redirectPort>/callback`.
///
/// To enable Slack: paste the two values below, set `redirectURI` to your hosted
/// page (and put the SAME URL in the Slack app's Redirect URLs), then rebuild.
enum SlackOAuthConfig {
    static let clientId = "10744348290480.11302757894647"        // Slack app → Basic Information → Client ID
    static let clientSecret = "***REDACTED***"    // Slack app → Basic Information → Client Secret

    /// The local loopback port the hosted callback page must redirect to.
    /// Must match the LOOPBACK port in oauth-callback/index.html.
    static let redirectPort: UInt16 = 3129

    /// The hosted https page registered in the Slack app's "Redirect URLs".
    static let redirectURI = "https://flemercier6.github.io/notchboard-oauth/"

    /// User-token scopes — let us read the signed-in user's own messages across
    /// their channels and DMs (no bot invitation needed).
    static let userScopes = [
        "channels:history", "groups:history", "im:history", "mpim:history",
        "channels:read", "groups:read", "im:read", "mpim:read",
        "users:read",
    ]

    static var isConfigured: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty && !redirectURI.contains("YOUR-DOMAIN")
    }
}
