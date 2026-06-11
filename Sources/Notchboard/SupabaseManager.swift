import Foundation
import Supabase

/// Owns the Supabase client and the auth session. Sign-in is OPTIONAL — the app
/// works fully offline; signing in just turns on multi-device sync. The SDK
/// persists the session in the macOS Keychain automatically.
@MainActor
final class SupabaseManager: ObservableObject {
    let client: SupabaseClient

    @Published private(set) var session: Session?
    @Published var authError: String?
    @Published private(set) var isWorking = false
    /// Set after a successful sign-up when email confirmation is required.
    @Published var pendingConfirmation = false

    var isSignedIn: Bool { session != nil }
    var userId: UUID? { session?.user.id }
    var userEmail: String? { session?.user.email }

    init() {
        client = SupabaseClient(
            supabaseURL: SupabaseConfig.url,
            supabaseKey: SupabaseConfig.publishableKey,
            options: SupabaseClientOptions(
                // File-based session storage — avoids the Keychain password loop
                // caused by ad-hoc codesigning. See FileAuthStorage.
                auth: SupabaseClientOptions.AuthOptions(storage: FileAuthStorage())
            )
        )
        Task { await observeAuth() }
    }

    /// Restore any saved session, then keep `session` in sync with auth changes.
    private func observeAuth() async {
        session = try? await client.auth.session
        for await change in client.auth.authStateChanges {
            session = change.session
        }
    }

    // MARK: - Email / password

    func signUp(email: String, password: String) async {
        await run {
            let response = try await self.client.auth.signUp(email: email, password: password)
            // With email confirmation on, no session is returned until confirmed.
            if response.session == nil { self.pendingConfirmation = true }
        }
    }

    func signIn(email: String, password: String) async {
        await run { _ = try await self.client.auth.signIn(email: email, password: password) }
    }

    func signOut() async {
        try? await client.auth.signOut()
        session = nil
    }

    private func run(_ op: @escaping () async throws -> Void) async {
        isWorking = true
        authError = nil
        pendingConfirmation = false
        defer { isWorking = false }
        do { try await op() }
        catch { authError = (error as? AuthError)?.message ?? error.localizedDescription }
    }
}
