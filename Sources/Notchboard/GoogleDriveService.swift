import AppKit
import Foundation

/// A file (or folder) returned by the Drive API.
struct DriveFile: Identifiable, Decodable {
    let id: String
    let name: String
    let mimeType: String
    let webViewLink: String?
    let iconLink: String?
    let modifiedTime: String?

    var isFolder: Bool { mimeType == "application/vnd.google-apps.folder" }
}

private struct DriveFileList: Decodable {
    let files: [DriveFile]
}

/// Lists and searches the connected account's Drive files. Results are published
/// for the shelf to render; clicking a file opens its `webViewLink` in the
/// browser (handled by the view).
@MainActor
final class GoogleDriveService: ObservableObject {
    @Published private(set) var files: [DriveFile] = []
    @Published private(set) var isLoading = false
    @Published var errorMessage: String?

    let auth: GoogleDriveAuth
    private var queryTask: Task<Void, Never>?

    init(auth: GoogleDriveAuth) { self.auth = auth }

    /// Most recently modified files.
    func loadRecent() {
        runQuery(q: "trashed = false", orderBy: "modifiedTime desc")
    }

    /// Files whose name contains `text`. Empty falls back to recent.
    func search(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { loadRecent(); return }
        let escaped = trimmed.replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "'", with: "\\'")
        runQuery(q: "name contains '\(escaped)' and trashed = false", orderBy: nil)
    }

    private func runQuery(q: String, orderBy: String?) {
        queryTask?.cancel()
        queryTask = Task { @MainActor in
            // Debounce so each keystroke doesn't fire a request.
            try? await Task.sleep(nanoseconds: 250_000_000)
            guard !Task.isCancelled else { return }

            isLoading = true
            defer { isLoading = false }
            do {
                let token = try await auth.accessToken()
                guard !Task.isCancelled else { return }

                var comps = URLComponents(string: "https://www.googleapis.com/drive/v3/files")!
                comps.queryItems = [
                    URLQueryItem(name: "q", value: q),
                    URLQueryItem(name: "pageSize", value: "50"),
                    URLQueryItem(name: "fields", value: "files(id,name,mimeType,webViewLink,iconLink,modifiedTime)"),
                    URLQueryItem(name: "orderBy", value: orderBy),
                    URLQueryItem(name: "spaces", value: "drive"),
                    URLQueryItem(name: "corpora", value: "user"),
                ].filter { $0.value != nil }

                var req = URLRequest(url: comps.url!)
                req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
                let (data, resp) = try await URLSession.shared.data(for: req)
                guard !Task.isCancelled else { return }

                if let http = resp as? HTTPURLResponse, http.statusCode != 200 {
                    throw DriveError.message("Drive request failed (\(http.statusCode))")
                }
                let list = try JSONDecoder().decode(DriveFileList.self, from: data)
                files = list.files
                errorMessage = nil
            } catch is CancellationError {
                // Superseded by a newer query.
            } catch {
                errorMessage = (error as? DriveError)?.text ?? error.localizedDescription
            }
        }
    }
}

/// Bundled Google logos loaded at runtime from the app's Resources (copied in by
/// scripts/make-app.sh). Fall back gracefully (to SF Symbols) when missing.
enum GoogleAssets {
    static let drive = image(named: "googledrive")
    static let gmail = image(named: "gmaillogo")
    static let calendar = image(named: "googlecalendarlogo")
    static let doc = image(named: "googledoc")
    static let slide = image(named: "googleslide")
    static let sheet = image(named: "googlesheet")

    /// The product logo to show on a Drive tile for documents / slides /
    /// spreadsheets (Google-native or the matching Office formats). nil → use the
    /// file's own iconLink / an SF Symbol.
    static func fileLogo(for mimeType: String) -> NSImage? {
        let m = mimeType.lowercased()
        if m.contains("presentation") || m.contains("powerpoint") { return slide }
        if m.contains("spreadsheet") || m.contains("excel") { return sheet }
        if m.contains("document") || m.contains("word") { return doc }
        return nil
    }

    private static func image(named name: String) -> NSImage? {
        guard let url = Bundle.main.url(forResource: name, withExtension: "png") else { return nil }
        return NSImage(contentsOf: url)
    }
}

/// An SF Symbol approximating a Drive file's type, used until/if its iconLink loads.
func driveSymbolName(for mimeType: String) -> String {
    if mimeType.contains("folder") { return "folder.fill" }
    if mimeType.contains("spreadsheet") || mimeType.contains("excel") { return "tablecells.fill" }
    if mimeType.contains("presentation") || mimeType.contains("powerpoint") { return "rectangle.on.rectangle.fill" }
    if mimeType.contains("pdf") { return "doc.richtext.fill" }
    if mimeType.contains("document") || mimeType.contains("word") { return "doc.text.fill" }
    if mimeType.hasPrefix("image/") { return "photo.fill" }
    if mimeType.hasPrefix("video/") { return "film.fill" }
    if mimeType.hasPrefix("audio/") { return "music.note" }
    return "doc.fill"
}
