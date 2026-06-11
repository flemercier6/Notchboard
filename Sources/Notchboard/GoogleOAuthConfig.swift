import Foundation

/// Notchboard's *own* Google OAuth client — created ONCE by the developer in
/// Google Cloud Console (credential type: "Desktop app"). It ships inside the
/// app so that every user just clicks "Connect" and authorizes their *own*
/// Google account; nobody else needs to create credentials.
///
/// For desktop/installed OAuth clients, Google does not treat the client secret
/// as confidential — PKCE secures the code exchange — so embedding it here is the
/// expected, documented practice.
///
/// To enable Drive for everyone: paste the two values below, then rebuild.
enum GoogleOAuthConfig {
    /// e.g. "123456789-abcdef.apps.googleusercontent.com". Public — safe to ship.
    /// The client SECRET is NOT here: token exchange/refresh runs server-side in
    /// the `oauth-proxy` Edge Function, which holds the secret.
    static let clientId = "535692663846-9ujptgrj5oe2d0864mmtf62di8q891oo.apps.googleusercontent.com"

    static var isConfigured: Bool { !clientId.isEmpty }
}
