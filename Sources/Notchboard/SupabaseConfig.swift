import Foundation

/// Notchboard's Supabase backend (online mode / multi-device sync).
///
/// The URL and publishable key are SAFE to ship in the client: every table has
/// Row Level Security, so a signed-in user can only ever read/write their own
/// rows. Sensitive data (API keys, OAuth tokens) is NEVER stored here — it stays
/// in the device Keychain.
enum SupabaseConfig {
    static let url = URL(string: "https://thyuhimymodoiisgtlqo.supabase.co")!
    static let publishableKey = "sb_publishable_PO-zX_ZpjINgGnSBU8skew_kejtxzwn"
}
