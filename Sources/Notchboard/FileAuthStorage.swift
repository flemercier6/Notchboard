import Foundation
import Supabase

/// File-based session storage for the Supabase SDK, instead of its default
/// Keychain storage.
///
/// The app is ad-hoc codesigned (re-signed on every build), so macOS never
/// recognizes it as the owner of a Keychain item — it would prompt for the
/// keychain password on every session read/refresh, in a loop. Storing the
/// session in a user-only file under Application Support (where the app already
/// keeps its other tokens) avoids that entirely.
struct FileAuthStorage: AuthLocalStorage {
    private static let lock = NSLock()
    private static var url: URL {
        ShelfPersistence.directory.appendingPathComponent("supabase-session.json")
    }

    func store(key: String, value: Data) throws { try Self.mutate { $0[key] = value } }
    func retrieve(key: String) throws -> Data? { Self.read()[key] }
    func remove(key: String) throws { try Self.mutate { $0[key] = nil } }

    private static func read() -> [String: Data] {
        guard let data = try? Data(contentsOf: url) else { return [:] }
        return (try? JSONDecoder().decode([String: Data].self, from: data)) ?? [:]
    }

    private static func mutate(_ change: (inout [String: Data]) -> Void) throws {
        lock.lock()
        defer { lock.unlock() }
        var dict = read()
        change(&dict)
        let data = try JSONEncoder().encode(dict)
        try data.write(to: url, options: [.atomic])
        // Owner read/write only — it holds the auth session.
        try? FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
}
