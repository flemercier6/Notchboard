import AppKit
import UniformTypeIdentifiers

/// Whether a URL points to a genuine image file — not, say, a PDF that NSImage
/// would happily rasterize. Decides whether a dropped file becomes an image
/// item (with thumbnail) or a generic file item.
func isImageFile(_ url: URL) -> Bool {
    (try? url.resourceValues(forKeys: [.contentTypeKey]))?
        .contentType?.conforms(to: .image) ?? false
}

enum ShelfPayload {
    case text(String)
    // `url` is the original image file kept on disk (original format), so it can
    // be dragged/copied back out unchanged. `name` is the original file name,
    // `image` is just for display.
    case image(url: URL, name: String, image: NSImage)
    case file(url: URL, name: String)
    case color(String)   // normalized "#RRGGBB"
    case snippet(trigger: String, replacement: String)
    case note(String)    // markdown content

    enum Kind: String { case text, image, file, color, snippet, note }

    var kind: Kind {
        switch self {
        case .text: return .text
        case .image: return .image
        case .file: return .file
        case .color: return .color
        case .snippet: return .snippet
        case .note: return .note
        }
    }
}

/// A user-created folder for organizing items.
struct ShelfFolder: Identifiable, Hashable {
    let id: UUID
    var name: String
    /// The content type this folder holds (chosen at creation), so Assets stays ordered.
    var kind: ShelfPayload.Kind

    init(id: UUID = UUID(), name: String, kind: ShelfPayload.Kind = .text) {
        self.id = id
        self.name = name
        self.kind = kind
    }
}

struct ShelfItem: Identifiable {
    let id: UUID
    let payload: ShelfPayload
    let createdAt: Date
    /// nil = not in any folder.
    var folderId: UUID?

    init(id: UUID = UUID(), payload: ShelfPayload, createdAt: Date = Date(), folderId: UUID? = nil) {
        self.id = id
        self.payload = payload
        self.createdAt = createdAt
        self.folderId = folderId
    }
}

extension ShelfItem: Equatable {
    /// Identity equality (ids are unique) — enough for SwiftUI onChange/animation.
    static func == (lhs: ShelfItem, rhs: ShelfItem) -> Bool { lhs.id == rhs.id }
}

/// Holds the items dropped onto the shelf and bridges to the system clipboard.
@MainActor
final class ShelfStore: ObservableObject {
    @Published private(set) var items: [ShelfItem] = []
    @Published private(set) var folders: [ShelfFolder] = []

    /// Set when a screenshot is auto-saved, so the UI can flash a confirmation.
    @Published var lastScreenshotAdded: ShelfItem?

    /// Ids the user has explicitly deleted, awaiting propagation to the cloud.
    /// Persisted so a delete survives a restart, and so sync only ever removes
    /// cloud rows the USER deleted (never via inference — that caused data loss).
    @Published private(set) var deletedIds: Set<UUID> = ShelfStore.loadDeletedIds()

    /// Fired after any LOCAL mutation (not when remote sync applies changes), so
    /// the sync engine can push. Suppressed during `applyRemote`.
    var onLocalChange: (() -> Void)?
    private var suppressChange = false

    init() {
        let loaded = ShelfPersistence.load()
        folders = loaded.folders
        items = loaded.items
    }

    /// Replace the store from a sync reconcile WITHOUT triggering `onLocalChange`
    /// (so applying remote state doesn't bounce back as a push).
    func applyRemote(folders newFolders: [ShelfFolder], items newItems: [ShelfItem]) {
        suppressChange = true
        defer { suppressChange = false }
        folders = newFolders
        items = newItems
        ShelfPersistence.save(folders: folders, items: items)
    }

    @discardableResult
    func createFolder(name: String, kind: ShelfPayload.Kind = .text) -> UUID? {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let folder = ShelfFolder(name: trimmed, kind: kind)
        folders.append(folder)
        persist()
        return folder.id
    }

    func renameFolder(_ id: UUID, to name: String) {
        let trimmed = name.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let index = folders.firstIndex(where: { $0.id == id }) else { return }
        folders[index].name = trimmed
        persist()
    }

    /// Delete a folder; its items stay on the shelf but lose their folder.
    func deleteFolder(_ id: UUID) {
        folders.removeAll { $0.id == id }
        for index in items.indices where items[index].folderId == id {
            items[index].folderId = nil
        }
        recordDeleted(id)
        persist()
    }

    /// Live reorder while dragging: move `id` to just before `targetId`.
    /// Doesn't persist (call `commitReorder()` when the drop finishes).
    func reorder(_ id: UUID, before targetId: UUID) {
        guard id != targetId,
              let from = items.firstIndex(where: { $0.id == id }) else { return }
        let moved = items.remove(at: from)
        let to = items.firstIndex(where: { $0.id == targetId }) ?? items.count
        items.insert(moved, at: to)
    }

    func moveToEnd(_ id: UUID) {
        guard let from = items.firstIndex(where: { $0.id == id }) else { return }
        let moved = items.remove(at: from)
        items.append(moved)
    }

    func commitReorder() {
        persist()
    }

    /// Move an item into a folder, or out of all folders when `folderId` is nil.
    func moveItem(_ id: UUID, toFolder folderId: UUID?) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        items[index].folderId = folderId
        persist()
    }

    @discardableResult
    func addText(_ string: String, folderId: UUID? = nil) -> UUID? {
        let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let item: ShelfItem
        // A hex color string becomes a color swatch instead of plain text.
        if let hex = parseHexColor(trimmed) {
            item = ShelfItem(payload: .color(hex), folderId: folderId)
        } else {
            item = ShelfItem(payload: .text(string), folderId: folderId)
        }
        items.append(item)
        persist()
        return item.id
    }

    /// Add an image file (from Finder, etc.), preserving its original format.
    @discardableResult
    func addImageFile(_ source: URL, displayName: String? = nil, folderId: UUID? = nil) -> UUID? {
        let id = UUID()
        guard let stored = ShelfPersistence.importImageFile(source, id: id),
              let image = NSImage(contentsOf: stored) else { return nil }
        items.append(ShelfItem(
            id: id,
            payload: .image(url: stored, name: displayName ?? source.lastPathComponent, image: image),
            folderId: folderId
        ))
        persist()
        return id
    }

    /// Auto-save a screenshot (copies it into the shelf) and flag it for the UI.
    @discardableResult
    func addScreenshot(_ url: URL) -> UUID? {
        guard let id = addImageFile(url, displayName: url.lastPathComponent) else { return nil }
        lastScreenshotAdded = items.first { $0.id == id }
        return id
    }

    /// Add an image that has no backing file (dragged from an app, clipboard).
    /// No original format exists, so it is stored losslessly as PNG.
    @discardableResult
    func addImage(_ image: NSImage, name: String = "image.png", folderId: UUID? = nil) -> UUID? {
        let id = UUID()
        guard let stored = ShelfPersistence.storeImageAsPNG(image, id: id) else { return nil }
        items.append(ShelfItem(id: id, payload: .image(url: stored, name: name, image: image), folderId: folderId))
        persist()
        return id
    }

    /// Add a color swatch from a hex string.
    func addColor(_ hex: String, folderId: UUID? = nil) {
        guard let normalized = parseHexColor(hex) else { return }
        items.append(ShelfItem(payload: .color(normalized), folderId: folderId))
        persist()
    }

    /// Add an empty "#" color the user edits in place; returns its id.
    @discardableResult
    func addColorPlaceholder(folderId: UUID? = nil) -> UUID {
        let item = ShelfItem(payload: .color("#"), folderId: folderId)
        items.append(item)
        persist()
        return item.id
    }

    /// Create or update a snippet. Pass `id` to edit an existing one.
    func upsertSnippet(id: UUID?, trigger: String, replacement: String, folderId: UUID? = nil) {
        let trimmed = trigger.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        if let id, let index = items.firstIndex(where: { $0.id == id }) {
            let current = items[index]
            items[index] = ShelfItem(id: id, payload: .snippet(trigger: trimmed, replacement: replacement), createdAt: current.createdAt, folderId: current.folderId)
        } else {
            items.append(ShelfItem(payload: .snippet(trigger: trimmed, replacement: replacement), folderId: folderId))
        }
        persist()
    }

    /// Create an empty note and return its id (opened in the editor right away).
    @discardableResult
    func addNote(folderId: UUID? = nil) -> UUID {
        let item = ShelfItem(payload: .note(""), folderId: folderId)
        items.append(item)
        persist()
        return item.id
    }

    /// Auto-save a note's content while editing.
    func setNoteContent(_ id: UUID, _ content: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .note = items[index].payload else { return }
        let current = items[index]
        items[index] = ShelfItem(id: id, payload: .note(content), createdAt: current.createdAt, folderId: current.folderId)
        persist()
    }

    func noteContent(_ id: UUID) -> String? {
        guard let item = items.first(where: { $0.id == id }),
              case .note(let content) = item.payload else { return nil }
        return content
    }

    /// Trigger/replacement pairs for the text-expansion engine.
    var snippets: [(trigger: String, replacement: String)] {
        items.compactMap {
            if case .snippet(let trigger, let replacement) = $0.payload {
                return (trigger, replacement)
            }
            return nil
        }
    }

    /// Update a color item's hex while the user edits it.
    func setColorHex(_ id: UUID, _ hex: String) {
        guard let index = items.firstIndex(where: { $0.id == id }),
              case .color = items[index].payload else { return }
        let current = items[index]
        items[index] = ShelfItem(id: current.id, payload: .color(hex), createdAt: current.createdAt, folderId: current.folderId)
        persist()
    }

    /// Import an arbitrary file: copy it into local storage and add it.
    @discardableResult
    func addFile(_ source: URL, folderId: UUID? = nil) -> UUID? {
        let id = UUID()
        guard let stored = ShelfPersistence.importFile(source, id: id) else { return nil }
        items.append(ShelfItem(id: id, payload: .file(url: stored, name: source.lastPathComponent), folderId: folderId))
        persist()
        return id
    }

    func remove(_ item: ShelfItem) {
        items.removeAll { $0.id == item.id }
        recordDeleted(item.id)
        persist()
    }

    func clear() {
        for item in items { deletedIds.insert(item.id) }
        items.removeAll()
        saveDeletedIds()
        persist()
    }

    private func recordDeleted(_ id: UUID) {
        deletedIds.insert(id)
        saveDeletedIds()
    }

    /// Called by the sync engine once a deletion has been propagated to the cloud.
    func clearDeleted(_ ids: [UUID]) {
        guard !ids.isEmpty else { return }
        for id in ids { deletedIds.remove(id) }
        saveDeletedIds()
    }

    private static var deletedIdsURL: URL {
        ShelfPersistence.directory.appendingPathComponent("pending-deletions.json")
    }
    private static func loadDeletedIds() -> Set<UUID> {
        guard let data = try? Data(contentsOf: deletedIdsURL),
              let ids = try? JSONDecoder().decode([UUID].self, from: data) else { return [] }
        return Set(ids)
    }
    private func saveDeletedIds() {
        try? JSONEncoder().encode(Array(deletedIds)).write(to: Self.deletedIdsURL)
    }

    private func persist() {
        ShelfPersistence.save(folders: folders, items: items)
        if !suppressChange { onLocalChange?() }
    }

    /// Pull whatever is currently on the system clipboard into the shelf,
    /// optionally filing it into a folder.
    @discardableResult
    func pasteFromClipboard(folderId: UUID? = nil) -> Bool {
        let pasteboard = NSPasteboard.general
        // A file copied in Finder shows up as a file URL — keep it as a file.
        if let url = (pasteboard.readObjects(
            forClasses: [NSURL.self],
            options: [.urlReadingFileURLsOnly: true]
        ) as? [URL])?.first {
            if isImageFile(url) {
                addImageFile(url, displayName: url.lastPathComponent, folderId: folderId)
            } else {
                addFile(url, folderId: folderId)
            }
            return true
        }
        if let image = NSImage(pasteboard: pasteboard) {
            addImage(image, folderId: folderId)
            return true
        }
        if let string = pasteboard.string(forType: .string) {
            addText(string, folderId: folderId)
            return true
        }
        return false
    }

    /// Put an item back onto the system clipboard so it can be pasted elsewhere.
    func copyToClipboard(_ item: ShelfItem) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        switch item.payload {
        case .text(let string):
            pasteboard.setString(string, forType: .string)
        case .image(let url, _, let image):
            // Put the original-format bytes on the clipboard under their real
            // UTI (so paste keeps PNG/JPEG/etc.), falling back to the NSImage.
            if let data = try? Data(contentsOf: url),
               let type = UTType(filenameExtension: url.pathExtension) {
                let pbItem = NSPasteboardItem()
                pbItem.setData(data, forType: NSPasteboard.PasteboardType(type.identifier))
                pasteboard.writeObjects([pbItem])
            } else {
                pasteboard.writeObjects([image])
            }
        case .file(let url, _):
            pasteboard.writeObjects([url as NSURL])
        case .color(let hex):
            pasteboard.setString(hex, forType: .string)
        case .snippet(_, let replacement):
            pasteboard.setString(replacement, forType: .string)
        case .note(let content):
            pasteboard.setString(content, forType: .string)
        }
    }
}
