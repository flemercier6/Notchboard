import AppKit
import Foundation

/// A Notion page or database shown as a shortcut tile.
struct NotionPage: Identifiable, Equatable {
    let id: String
    let title: String
    let url: String
    let isDatabase: Bool
}

/// Fetches the signed-in user's recent Notion pages and databases (those shared
/// with the integration) and opens them in the browser / Notion app.
@MainActor
final class NotionService: ObservableObject {
    @Published private(set) var pages: [NotionPage] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    private let auth: NotionAuth
    init(auth: NotionAuth) { self.auth = auth }

    func loadPages() {
        guard let token = auth.accessToken, !isLoading else { return }
        isLoading = true
        errorMessage = nil
        Task { @MainActor in
            defer { isLoading = false }
            do { pages = try await fetch(token: token) }
            catch { errorMessage = error.localizedDescription }
        }
    }

    func open(_ page: NotionPage) {
        if let url = URL(string: page.url) { NSWorkspace.shared.open(url) }
    }

    func clear() { pages = [] }

    // MARK: - Notion API

    private func fetch(token: String) async throws -> [NotionPage] {
        var req = URLRequest(url: URL(string: "https://api.notion.com/v1/search")!)
        req.httpMethod = "POST"
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("2022-06-28", forHTTPHeaderField: "Notion-Version")
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "page_size": 50,
            "sort": ["direction": "descending", "timestamp": "last_edited_time"],
        ]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)

        let (data, _) = try await URLSession.shared.data(for: req)
        guard let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let results = obj["results"] as? [[String: Any]] else { return [] }
        return results.compactMap(Self.parse)
    }

    private static func parse(_ obj: [String: Any]) -> NotionPage? {
        guard let id = obj["id"] as? String else { return nil }
        let url = obj["url"] as? String ?? ""
        let isDatabase = (obj["object"] as? String) == "database"
        let title: String
        if isDatabase {
            title = plainText(obj["title"] as? [[String: Any]]) ?? "Untitled"
        } else {
            title = pageTitle(obj) ?? "Untitled"
        }
        return NotionPage(id: id, title: title, url: url, isDatabase: isDatabase)
    }

    /// A page's title lives in whichever property has type "title".
    private static func pageTitle(_ obj: [String: Any]) -> String? {
        guard let props = obj["properties"] as? [String: Any] else { return nil }
        for (_, value) in props {
            if let v = value as? [String: Any], v["type"] as? String == "title" {
                return plainText(v["title"] as? [[String: Any]])
            }
        }
        return nil
    }

    private static func plainText(_ rich: [[String: Any]]?) -> String? {
        guard let rich else { return nil }
        let text = rich.compactMap { $0["plain_text"] as? String }.joined()
        return text.isEmpty ? nil : text
    }
}

/// The bundled Notion logo (notionlogo.png in Resources), if present.
enum NotionAssets {
    static let logo: NSImage? = {
        guard let url = Bundle.main.url(forResource: "notionlogo", withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }()
}
