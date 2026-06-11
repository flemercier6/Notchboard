import Foundation

/// Notchboard's Notion OAuth integration — created ONCE by the developer at
/// https://www.notion.so/my-integrations (a *public* OAuth integration), so every
/// user can connect their own Notion workspace.
///
/// Notion requires an **https** OAuth redirect URL, so we reuse the same hosted
/// callback page as Slack (see `oauth-callback/index.html`) which bounces the
/// result to the app's local loopback at `http://127.0.0.1:<redirectPort>/callback`.
///
/// To enable Notion: paste the two values below, set `redirectURI` to your hosted
/// page (and add the SAME URL to the integration's Redirect URIs), then rebuild.
enum NotionOAuthConfig {
    static let clientId = "37bd872b-594c-81c7-b9b7-0037a2dd2625"        // Notion integration → OAuth Client ID
    static let clientSecret = "***REDACTED***"    // Notion integration → OAuth Client Secret

    /// The local loopback port the hosted callback page redirects to (shared with
    /// the other OAuth flows — only one runs at a time).
    static let redirectPort: UInt16 = 3129

    /// The hosted https page registered in the integration's "Redirect URIs".
    static let redirectURI = "https://flemercier6.github.io/notchboard-oauth/"

    static var isConfigured: Bool {
        !clientId.isEmpty && !clientSecret.isEmpty && !redirectURI.contains("YOUR-DOMAIN")
    }
}
